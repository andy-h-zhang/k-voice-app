import Foundation
import SwiftData

/// Drives one recording from `recorded` to `done`, persisting every step.
///
/// ```
/// recorded ──upload──▶ uploading ──submit──▶ queued ──poll──▶ transcribing
///                                                                  │
///                                            done ◀──match── matching
/// ```
///
/// Every arrow above is a write to the `Recording` row *before* the work
/// starts, which is what makes the two hard requirements fall out:
///
/// - **A relaunch resumes instead of restarting.** `assemblyTranscriptId` is
///   persisted the instant the provider hands it over, so a crash mid-poll
///   costs one `GET`, not a re-upload of a 2-hour file. See
///   ``TranscriptionResumePlan``.
/// - **A retry never re-records.** The `.m4a` is the input and is never
///   touched; once a finished response is on disk, retrying does not even
///   touch the network — it re-runs utterance building and speaker matching
///   from the saved JSON.
///
/// ## Concurrency
///
/// `ModelContainer` is `Sendable`, `ModelContext` is not. So this actor opens
/// a **context per operation** inside ``withContext(_:)``, whose body is
/// synchronous — there is no suspension point at which the actor could be
/// reentered while a context is live — and only `Sendable` values ever cross
/// that boundary. `PersistentModel` instances never escape. This is the boring
/// solution, and it is the one that stays correct.
///
/// ## What this type does not do
///
/// It does not record, it does not know what a view is, and it does not decide
/// *when* to run — the app enqueues it. It also does not own the embedder:
/// speaker matching arrives as ``SpeakerMatching`` so the state machine can be
/// tested without a model download.
public actor TranscriptionJob {

    /// Knobs that are not settings and not identifiers.
    public struct Configuration: Sendable {
        /// Priority-ordered model list sent as `speech_models`.
        public var speechModels: [String]
        /// File name for the verbatim response inside the recording folder.
        public var rawTranscriptFileName: String
        /// Polling schedule. Tests inject one that never actually sleeps.
        public var poller: TranscriptPoller

        public init(
            speechModels: [String] = AssemblyAIConstants.defaultSpeechModels,
            rawTranscriptFileName: String = RawTranscriptStore.defaultFileName,
            poller: TranscriptPoller = TranscriptPoller()
        ) {
            self.speechModels = speechModels
            self.rawTranscriptFileName = rawTranscriptFileName
            self.poller = poller
        }
    }

    // MARK: - Dependencies

    public let recordingID: UUID

    private let container: ModelContainer
    private let provider: any TranscriptionProvider
    private let matching: any SpeakerMatching
    private let profiles: any ProfileSource
    private let settings: SettingsSnapshot
    private let configuration: Configuration
    private let now: @Sendable () -> Date

    // MARK: - State

    private var subscribers: [UUID: AsyncStream<TranscriptionJobEvent>.Continuation] = [:]
    private var lastEvent: TranscriptionJobEvent?
    private var isRunning = false

    /// - Parameters:
    ///   - settings: A **snapshot**, not a live store. Keyterms are read from
    ///     it at submit time (plan §2 Phase 3), and taking a copy is what
    ///     stops an edit made while a 40-minute job polls from rewriting the
    ///     request that is already on the wire.
    ///   - matching: The speaker-ID pipeline. In the app this is a
    ///     `SpeakerIdentifier` built with `ClusterMatcher(threshold:)` from the
    ///     same settings snapshot.
    ///   - now: Injectable clock, so transition timestamps are assertable.
    public init(
        recordingID: UUID,
        container: ModelContainer,
        provider: any TranscriptionProvider,
        matching: any SpeakerMatching,
        profiles: any ProfileSource,
        settings: SettingsSnapshot,
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.recordingID = recordingID
        self.container = container
        self.provider = provider
        self.matching = matching
        self.profiles = profiles
        self.settings = settings
        self.configuration = configuration
        self.now = now
    }

    // MARK: - Observation

    /// A stream of this job's state transitions.
    ///
    /// The current state is replayed immediately on subscribe, so a view that
    /// attaches late is never blank. The stream **finishes** when the job
    /// reaches a terminal state (`done` or `failed`); a subsequent `retry()`
    /// is a new run, and the caller asks for a new stream. Multiple
    /// subscribers are supported and each gets every event.
    public func events() -> AsyncStream<TranscriptionJobEvent> {
        let (stream, continuation) = AsyncStream<TranscriptionJobEvent>.makeStream()
        let current = lastEvent ?? snapshotEvent()

        continuation.yield(current)
        if current.status.isTerminal {
            continuation.finish()
            return stream
        }

        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func emit(_ event: TranscriptionJobEvent) {
        lastEvent = event
        let current = subscribers
        for (id, continuation) in current {
            continuation.yield(event)
            if event.status.isTerminal {
                continuation.finish()
                subscribers[id] = nil
            }
        }
    }

    // MARK: - Public API

    /// The persisted state of this job's recording.
    public func snapshot() throws -> RecordingSnapshot {
        try withContext { context in
            guard let recording = try context.recording(id: recordingID) else {
                throw TranscriptionJobError.recordingNotFound(id: recordingID)
            }
            return RecordingSnapshot(recording)
        }
    }

    /// Where a `run()` would pick up — cheapest usable entry point.
    public func resumePlan() throws -> TranscriptionResumePlan {
        Self.plan(for: try snapshot(), libraryRoot: settings.storageFolderURL, fileName: configuration.rawTranscriptFileName)
    }

    /// Runs the pipeline to a terminal state.
    ///
    /// Never throws: a pipeline failure *is* a state, and it is persisted as
    /// `.failed(message)` and returned. Cancellation is the one exception to
    /// the "always terminal" rule — it leaves the row mid-flight on purpose,
    /// so the next launch resumes from there.
    @discardableResult
    public func run() async -> RecordingStatus {
        guard !isRunning else { return currentStatus() }
        isRunning = true
        defer { isRunning = false }

        do {
            return try await pipeline(from: try resumePlan())
        } catch is CancellationError {
            return currentStatus()
        } catch {
            return persistFailure(error)
        }
    }

    /// User-initiated retry after a failure.
    ///
    /// Clears the failure, then runs from the cheapest resume point — which
    /// **never re-records**, and does not even touch the network when a
    /// finished transcript is already on disk.
    @discardableResult
    public func retry() async -> RecordingStatus {
        try? update { recording in
            if recording.status.kind == .failed {
                recording.setStatus(.recorded, at: self.now())
            }
        }
        return await run()
    }

    /// Rebuilds utterances and speaker matches from the saved response, with
    /// **no network**.
    ///
    /// Also the "re-run speaker ID after enrolling a new person" path: the
    /// spec keeps the raw response precisely so this is possible. Speaker
    /// slots a human confirmed keep their person; everything else is rebuilt.
    @discardableResult
    public func reprocess() async -> RecordingStatus {
        guard !isRunning else { return currentStatus() }
        isRunning = true
        defer { isRunning = false }

        do {
            let response = try rawStore(for: try snapshot()).readCompleted()
            return try await applyTranscript(response, markRawPersisted: true)
        } catch is CancellationError {
            return currentStatus()
        } catch {
            return persistFailure(error)
        }
    }

    // MARK: - Pipeline

    private func pipeline(from plan: TranscriptionResumePlan) async throws -> RecordingStatus {
        var transcriptID: String?
        var uploadURL: String?

        switch plan {
        case .alreadyDone:
            return .done
        case .reprocess:
            let response = try rawStore(for: try snapshot()).readCompleted()
            return try await applyTranscript(response, markRawPersisted: true)
        case .poll(let id):
            transcriptID = id
        case .submit(let url):
            uploadURL = url
        case .upload:
            break
        }

        if transcriptID == nil {
            if uploadURL == nil {
                uploadURL = try await performUpload()
            }
            transcriptID = try await performSubmit(uploadURL: uploadURL ?? "")
        } else {
            // Resuming: the server's state is unknown until the first poll
            // answers, so present the job as queued rather than inventing one.
            try transition(to: .queued, detail: "Resuming transcript \(transcriptID ?? "")")
        }

        let response = try await pollToCompletion(transcriptID: transcriptID ?? "")
        return try await applyTranscript(response, markRawPersisted: true)
    }

    /// `uploading` → the provider's `upload_url`.
    private func performUpload() async throws -> String {
        let snapshot = try snapshot()
        let audioURL = snapshot.audioURL(inRoot: settings.storageFolderURL)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionJobError.audioFileMissing(path: audioURL.path)
        }

        try transition(to: .uploading, detail: audioURL.lastPathComponent)
        let uploaded = try await provider.upload(fileURL: audioURL)
        try update { $0.uploadedAudioURLString = uploaded.absoluteString }
        return uploaded.absoluteString
    }

    /// Creates the transcript and persists its id — the resume anchor.
    private func performSubmit(uploadURL: String) async throws -> String {
        // Keyterms are read from the settings snapshot **here**, at submit
        // time, and sanitized against the API's limits for the models we are
        // actually asking for (api-notes §2).
        let budget = TranscriptRequest.keytermWordBudget(for: configuration.speechModels)
        let keyterms = TranscriptRequest.sanitizedKeyterms(settings.keyterms, wordBudget: budget)

        let request = TranscriptRequest(
            audioURL: uploadURL,
            speechModels: configuration.speechModels,
            speakerLabels: true,
            keytermsPrompt: keyterms.isEmpty ? nil : keyterms
        )

        let id = try await provider.createTranscript(request)
        // Persisted with the status change, not after it: a crash between the
        // two would be the one case that costs a re-upload.
        let date = now()
        try update { recording in
            recording.assemblyTranscriptId = id
            recording.setStatus(.queued, at: date)
        }
        emit(TranscriptionJobEvent(
            recordingID: recordingID,
            status: .queued,
            detail: "Transcript \(id)",
            at: date
        ))
        return id
    }

    /// Polls to `completed`, persisting every body before decoding it.
    private func pollToCompletion(transcriptID: String) async throws -> TranscriptResponse {
        let snapshot = try snapshot()
        let duration = snapshot.durationSec > 0 ? snapshot.durationSec : nil

        let response = try await configuration.poller.waitForCompletion(
            id: transcriptID,
            audioDurationSeconds: duration,
            poll: { [self] id in try await pollOnce(id: id) }
        )

        // A `completed` body is now on disk, so from here a retry can rebuild
        // everything without a network. Recording that fact is what turns the
        // file into a recovery point.
        try update { $0.rawResponseFile = self.configuration.rawTranscriptFileName }
        return response
    }

    /// One poll: persist the verbatim body, then decode, then record progress.
    ///
    /// Every body is written, not only the terminal one. That is the strict
    /// reading of api-notes decision 1 ("raw response body persisted verbatim
    /// **before** decoding"): if the API renames a field and our DTO chokes,
    /// the bytes are already in the recording's folder. The cost is ~20 small
    /// atomic writes over a 60-minute job, and `RawTranscriptStore.readCompleted`
    /// refuses anything that is not a finished transcript, so a half-written
    /// job never masquerades as a re-processable one.
    private func pollOnce(id: String) async throws -> TranscriptResponse {
        let store = rawStore(for: try snapshot())
        let response = try await provider.pollPersistingRaw(id: id) { data in
            try store.write(data)
        }

        pollAttempt += 1
        let status: RecordingStatus = response.status == .queued ? .queued : .transcribing
        if status != currentStatus() || lastEvent?.pollAttempt != pollAttempt {
            let date = now()
            try update { recording in
                if recording.status != status { recording.setStatus(status, at: date) }
                if let duration = response.audioDuration, duration > 0, recording.durationSec <= 0 {
                    recording.durationSec = duration
                }
            }
            emit(TranscriptionJobEvent(
                recordingID: recordingID,
                status: status,
                detail: nil,
                pollAttempt: pollAttempt - 1,
                at: date
            ))
        }
        return response
    }

    private var pollAttempt = 0

    // MARK: - Matching

    /// `matching` → rebuild rows → `done`.
    ///
    /// - Parameter markRawPersisted: Records `rawResponseFile` on the row.
    ///   True on both the network path (the file was just written) and the
    ///   re-process path (it was already there).
    private func applyTranscript(
        _ response: TranscriptResponse,
        markRawPersisted: Bool
    ) async throws -> RecordingStatus {
        try transition(
            to: .matching,
            detail: "\(response.speakerLabels.count) diarized speaker(s)"
        )

        let snapshot = try snapshot()
        let audioURL = snapshot.audioURL(inRoot: settings.storageFolderURL)

        // Both of these suspend, so neither may hold a ModelContext.
        let library = try await profiles.library()
        let identifications = try await matching.identify(
            audioURL: audioURL,
            transcript: response,
            library: library
        )

        let date = now()
        let matched = try withContext { context in
            guard let recording = try context.recording(id: recordingID) else {
                throw TranscriptionJobError.recordingNotFound(id: recordingID)
            }
            let count = try Self.rebuild(
                recording: recording,
                from: response,
                identifications: identifications,
                in: context
            )
            if markRawPersisted {
                recording.rawResponseFile = configuration.rawTranscriptFileName
            }
            recording.speechModelUsed = response.speechModelUsed
            recording.languageCode = response.languageCode
            if let duration = response.audioDuration, duration > 0, recording.durationSec <= 0 {
                recording.durationSec = duration
            }
            recording.completedAt = date
            recording.setStatus(.done, at: date)
            return count
        }

        emit(TranscriptionJobEvent(
            recordingID: recordingID,
            status: .done,
            detail: "\(matched) speaker(s) matched",
            at: date
        ))
        return .done
    }

    /// Replaces a recording's utterances and speaker slots from a response.
    ///
    /// - Returns: How many slots resolved to a named person.
    ///
    /// Human decisions survive: a `SpeakerSlot` a person confirmed keeps its
    /// `Person` even though the row itself is rebuilt. Edited utterance text
    /// does **not** survive — that is what "re-process" means, and the raw
    /// response is the only thing it can rebuild from.
    private static func rebuild(
        recording: Recording,
        from response: TranscriptResponse,
        identifications: [SpeakerIdentification],
        in context: ModelContext
    ) throws -> Int {
        // 1. Remember confirmed assignments, then clear the old rows.
        var confirmed: [String: Person] = [:]
        for slot in recording.speakerSlots where slot.isConfirmed {
            if let person = slot.person { confirmed[slot.diarizedSpeaker] = person }
        }
        for utterance in recording.utterances { context.delete(utterance) }
        for slot in recording.speakerSlots { context.delete(slot) }
        recording.utterances = []
        recording.speakerSlots = []

        // 2. One slot per diarized speaker. Speakers the selector could not
        //    embed still get a slot — they exist in the transcript and the
        //    editor must be able to name them.
        var byLetter: [String: SpeakerIdentification] = [:]
        for identification in identifications { byLetter[identification.speaker] = identification }
        let letters = Set(response.speakerLabels).union(byLetter.keys).sorted()

        var slots: [String: SpeakerSlot] = [:]
        var unknownIndex = 0
        var matchedCount = 0

        for letter in letters {
            let identification = byLetter[letter]
            let match = identification?.match

            let slot = SpeakerSlot(
                diarizedSpeaker: letter,
                clusterEmbedding: identification?.clusterEmbedding ?? [],
                matchedName: match?.best?.name,
                matchScore: match?.best?.score,
                matchThreshold: match?.threshold,
                meetsTarget: identification?.meetsTarget ?? false,
                spanCount: identification?.spans.count ?? 0
            )
            context.insert(slot)
            recording.speakerSlots.append(slot)

            if let person = confirmed[letter] {
                // A human already said who this is; a fresh score does not
                // get to overrule them.
                slot.assign(person, confirmed: true)
                matchedCount += 1
            } else if match?.verdict == .matched,
                let best = match?.best,
                let person = try Self.person(for: best, in: context) {
                // Auto-assigned, not confirmed: auto-learn waits for a human.
                slot.assign(person, confirmed: false)
                matchedCount += 1
            } else {
                unknownIndex += 1
                slot.unknownIndex = unknownIndex
            }
            slots[letter] = slot
        }

        // 3. Utterances, in transcript order. Words stop here by design.
        for (index, dto) in (response.utterances ?? []).enumerated() {
            let utterance = Utterance(index: index, dto: dto)
            context.insert(utterance)
            recording.utterances.append(utterance)
            slots[dto.speaker]?.utterances.append(utterance)
        }

        return matchedCount
    }

    /// Resolves a matcher verdict to a `Person` row.
    ///
    /// By id first — `SwiftDataProfileSource` mints `SpeakerProfile.id` from
    /// `Person.id`, so that is exact. By name second, which is what happens
    /// when the profiles came from the CLI's JSON library and no row exists
    /// yet under that identity.
    private static func person(for score: ProfileScore, in context: ModelContext) throws -> Person? {
        if let byID = try context.person(id: score.profileID) { return byID }
        return try context.person(named: score.name)
    }

    // MARK: - Failure

    /// Persists a failure and decides whether the transcript id survives it.
    private func persistFailure(_ error: Error) -> RecordingStatus {
        let message = Self.describe(error)
        let status = RecordingStatus.failed(message: message)
        let date = now()
        let discardID = Self.discardsTranscriptID(error)

        try? update { recording in
            if discardID {
                // The provider has pinned this id to a failure forever
                // (api-notes: re-polling it returns the same error), so a
                // retry must resubmit. The upload URL is kept, so resubmitting
                // costs one request and not the file again.
                recording.assemblyTranscriptId = nil
            }
            recording.setStatus(status, at: date)
        }

        emit(TranscriptionJobEvent(
            recordingID: recordingID,
            status: status,
            detail: message,
            at: date
        ))
        return status
    }

    /// Whether a failure invalidates the persisted transcript id.
    ///
    /// Only two do: a job that ended in server-side `error` (re-polling it is
    /// pointless), and a 404 (the id is not a thing). A timeout, a network
    /// blip, or a rate limit all leave a perfectly good id to resume from —
    /// which is the difference between "retry costs a request" and "retry
    /// costs a 2-hour upload".
    static func discardsTranscriptID(_ error: Error) -> Bool {
        switch error {
        case TranscriptionError.transcriptFailed, TranscriptionError.notFound:
            return true
        default:
            return false
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: - Planning

    /// The cheapest usable entry point for a recording.
    ///
    /// Pure and `static` so the app can ask "what would happen?" for a whole
    /// library without constructing a job per row.
    public static func plan(
        for snapshot: RecordingSnapshot,
        libraryRoot: URL,
        fileName: String = RawTranscriptStore.defaultFileName
    ) -> TranscriptionResumePlan {
        if snapshot.status == .done { return .alreadyDone }

        let store = RawTranscriptStore(
            folderURL: libraryRoot.appendingPathComponent(snapshot.folderName, isDirectory: true),
            fileName: snapshot.rawResponseFile ?? fileName
        )
        if store.holdsCompletedTranscript { return .reprocess }
        if let id = snapshot.assemblyTranscriptId, !id.isEmpty { return .poll(transcriptID: id) }
        if let url = snapshot.uploadedAudioURLString, !url.isEmpty { return .submit(uploadURL: url) }
        return .upload
    }

    // MARK: - Persistence plumbing

    private func rawStore(for snapshot: RecordingSnapshot) -> RawTranscriptStore {
        RawTranscriptStore(
            folderURL: settings.storageFolderURL
                .appendingPathComponent(snapshot.folderName, isDirectory: true),
            fileName: snapshot.rawResponseFile ?? configuration.rawTranscriptFileName
        )
    }

    private func currentStatus() -> RecordingStatus {
        (try? snapshot())?.status ?? .recorded
    }

    private func snapshotEvent() -> TranscriptionJobEvent {
        TranscriptionJobEvent(
            recordingID: recordingID,
            status: currentStatus(),
            at: now()
        )
    }

    /// Persists a status change and publishes it.
    private func transition(to status: RecordingStatus, detail: String? = nil) throws {
        let date = now()
        try update { $0.setStatus(status, at: date) }
        emit(TranscriptionJobEvent(
            recordingID: recordingID,
            status: status,
            detail: detail,
            at: date
        ))
    }

    /// Mutates this job's recording row in a fresh context.
    @discardableResult
    private func update<T>(_ body: (Recording) throws -> T) throws -> T {
        try withContext { context in
            guard let recording = try context.recording(id: recordingID) else {
                throw TranscriptionJobError.recordingNotFound(id: recordingID)
            }
            return try body(recording)
        }
    }

    /// Runs `body` against a fresh context and saves once.
    ///
    /// Synchronous by construction — see the type comment. `body` must return
    /// a `Sendable` value, never a `PersistentModel`.
    private func withContext<T>(_ body: (ModelContext) throws -> T) throws -> T {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let result = try body(context)
        if context.hasChanges { try context.save() }
        return result
    }
}

// MARK: - Snapshot

/// A `Sendable` copy of a `Recording` row.
///
/// The only shape in which recording state leaves an actor: `PersistentModel`
/// is not `Sendable`, and a model handed out from a closed context is a
/// use-after-free waiting to happen.
public struct RecordingSnapshot: Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var folderName: String
    public var audioFileName: String
    public var createdAt: Date
    public var durationSec: Double
    public var status: RecordingStatus
    public var statusChangedAt: Date
    public var assemblyTranscriptId: String?
    public var uploadedAudioURLString: String?
    public var rawResponseFile: String?
    public var completedAt: Date?
    public var utteranceCount: Int
    public var speakerSlotCount: Int
    public var participantNames: [String]

    public init(_ recording: Recording) {
        self.id = recording.id
        self.title = recording.title
        self.folderName = recording.folderName
        self.audioFileName = recording.audioFileName
        self.createdAt = recording.createdAt
        self.durationSec = recording.durationSec
        self.status = recording.status
        self.statusChangedAt = recording.statusChangedAt
        self.assemblyTranscriptId = recording.assemblyTranscriptId
        self.uploadedAudioURLString = recording.uploadedAudioURLString
        self.rawResponseFile = recording.rawResponseFile
        self.completedAt = recording.completedAt
        self.utteranceCount = recording.utterances.count
        self.speakerSlotCount = recording.speakerSlots.count
        self.participantNames = recording.participantNames
    }

    public func audioURL(inRoot root: URL) -> URL {
        root
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(audioFileName)
    }
}
