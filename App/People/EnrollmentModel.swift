import AVFoundation
import Foundation
import KVoiceCore
import Observation

/// One enrollment: capture (or import) audio of one person, window it, embed
/// each window, and store the vectors on their profile.
///
/// Both of spec §Voice profiles' *deliberate* creation paths run through here —
/// the guided 30-second read and uploaded clips — because they differ only in
/// where the audio comes from. Everything after that (window → embed → fold in,
/// tagged `enrollment` or `upload`) is one pipeline, and having one is what
/// keeps the two paths from drifting apart in quality.
///
/// The third path, auto-learn, is not here: it is `TranscriptionJob` folding a
/// confirmed speaker's cluster embedding in, with no UI of its own.
///
/// ## Deliberately not `RecordingSessionModel`
///
/// Enrollment capture looks like recording a meeting and is not: it writes to a
/// temporary file rather than the library, it stops itself at 30 seconds, it
/// never creates a `Recording` row, and it never enqueues transcription. Reusing
/// the recorder would mean teaching it four exceptions to its own purpose.
/// `MicSource` — where all the hard capture work actually lives — *is* shared.
@MainActor
@Observable
final class EnrollmentModel {

    // MARK: - Shape of the job

    /// Who the embeddings will belong to.
    enum Target: Equatable {
        /// A person who does not exist yet; the name is typed in the sheet.
        case newPerson
        /// An existing profile.
        case existing(id: UUID, name: String)

        var existingID: UUID? {
            if case .existing(let id, _) = self { return id }
            return nil
        }
    }

    /// Where the audio comes from.
    enum Mode: Equatable {
        /// Record the scripted read with the microphone.
        case guided
        /// Embed clips the user already has.
        case clips([URL])

        var embeddingSource: EmbeddingSource {
            switch self {
            case .guided: return .enrollment
            case .clips: return .upload
            }
        }
    }

    /// What the sheet is doing right now. The full set of states the flow can
    /// be in — there is no "and also" state hiding in a separate flag.
    enum Stage: Equatable {
        /// Waiting for the user to press Start (guided) or for clips to be
        /// picked. The name field is editable only here.
        case ready
        /// Asking macOS for microphone access; the system prompt is up.
        case requestingPermission
        /// Capturing. `elapsed` drives the progress ring and the script
        /// highlight.
        case recording
        /// Capture stopped; the file is being finalized.
        case finishing
        /// Decoding the audio and counting the windows worth embedding.
        case reading
        /// Running the CoreML model over each window.
        case embedding(windowCount: Int)
        /// Writing the vectors onto the profile.
        case saving
        /// Done. Carries what was stored.
        case finished(Result)
        /// Stopped by an error that the user may be able to fix.
        case failed(Failure)

        var isBusy: Bool {
            switch self {
            case .ready, .finished, .failed: return false
            case .requestingPermission, .recording, .finishing, .reading, .embedding, .saving:
                return true
            }
        }
    }

    struct Result: Equatable {
        let personID: UUID
        let personName: String
        /// Embeddings added by this enrollment.
        let added: Int
        /// Embeddings the profile now holds in total.
        let total: Int
        /// Dropped to stay inside the 20-embedding FIFO cap.
        let evicted: Int
    }

    /// A failure worth telling the user apart from any other, because the
    /// thing they should do about it differs.
    enum Failure: Equatable {
        /// macOS has not granted microphone access.
        case microphoneDenied
        /// The one-time model download did not work.
        case modelsUnavailable(String)
        /// Not enough audio to make an embedding out of.
        case audioTooShort(seconds: TimeInterval)
        /// A clip could not be decoded.
        case unreadableAudio(String)
        /// Everything else.
        case other(String)

        var title: String {
            switch self {
            case .microphoneDenied: return "Microphone access is off"
            case .modelsUnavailable: return "The voice models aren't available"
            case .audioTooShort: return "That was too short to learn from"
            case .unreadableAudio: return "That audio couldn't be read"
            case .other: return "Enrollment didn't finish"
            }
        }

        var message: String {
            switch self {
            case .microphoneDenied:
                return """
                    KVoice can't record until macOS grants it microphone access. Turn it on in \
                    System Settings ▸ Privacy & Security ▸ Microphone, then try again.
                    """
            case .modelsUnavailable(let detail):
                return """
                    Recognizing voices needs about 100 MB of on-device models, downloaded once. \
                    \(detail)

                    If this machine is offline, copy \
                    \(FluidAudioEmbedder.requiredModelFileNames.joined(separator: " and ")) into
                    \(FluidAudioEmbedder.defaultModelDirectory.path)
                    and try again — nothing else needs the network.
                    """
            case .audioTooShort(let seconds):
                return String(
                    format: """
                        Only %.0f seconds of audio came through, and a voice profile needs at \
                        least %.0f. Read the whole script, or add a longer clip.
                        """,
                    seconds,
                    EnrollmentScript.minimumDuration
                )
            case .unreadableAudio(let detail):
                return detail
            case .other(let detail):
                return detail
            }
        }

        /// Whether re-running is worth offering.
        var isRetryable: Bool {
            switch self {
            case .microphoneDenied, .audioTooShort: return false
            case .modelsUnavailable, .unreadableAudio, .other: return true
            }
        }
    }

    // MARK: - Observable state

    let target: Target
    let mode: Mode

    private(set) var stage: Stage = .ready

    /// Name for a new person; pre-filled and read-only for an existing one.
    var draftName: String

    /// Seconds of audio actually written, polled from `MicSource` — so a
    /// dropout that pauses capture visibly stops the clock too.
    private(set) var elapsed: TimeInterval = 0

    /// Input level, 0…1, for the meter.
    private(set) var level: Float = 0

    /// A non-fatal warning: capture was auto-paused, or the model warm-up
    /// failed while the user still has time to fix it.
    private(set) var notice: String?

    /// Clips chosen for an upload enrollment.
    private(set) var clipURLs: [URL] = []

    // MARK: - Dependencies

    private let profiles: SwiftDataProfileSource
    private let speakerModels: SpeakerModels
    private let settings: SettingsStore

    // MARK: - Session state

    private var source: MicSource?
    private var captureURL: URL?
    private var levelTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var warmUpTask: Task<Void, Never>?

    init(
        target: Target,
        mode: Mode,
        profiles: SwiftDataProfileSource,
        speakerModels: SpeakerModels,
        settings: SettingsStore
    ) {
        self.target = target
        self.mode = mode
        self.profiles = profiles
        self.speakerModels = speakerModels
        self.settings = settings

        switch target {
        case .newPerson: self.draftName = ""
        case .existing(_, let name): self.draftName = name
        }
        if case .clips(let urls) = mode { self.clipURLs = urls }
    }

    // MARK: - Derived

    var isGuided: Bool { mode == .guided }

    var progress: Double {
        min(1, max(0, elapsed / EnrollmentScript.targetDuration))
    }

    var currentLineIndex: Int {
        EnrollmentScript.lineIndex(atElapsed: elapsed)
    }

    /// Whether the reader has produced enough audio for "Stop" to be useful.
    var canStopEarly: Bool { elapsed >= EnrollmentScript.minimumDuration }

    var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the sheet can be dismissed without losing work in progress.
    var canCancel: Bool {
        switch stage {
        case .ready, .finished, .failed: return true
        case .recording, .requestingPermission: return true       // discards the take
        case .finishing, .reading, .embedding, .saving: return false
        }
    }

    // MARK: - Model warm-up

    /// Starts loading the CoreML models while the reader is still getting
    /// comfortable, so a first-run download overlaps the read instead of
    /// following it.
    ///
    /// Failure here is only a *notice*: the models are needed after capture,
    /// not before, and a user who fixes their connection mid-read should still
    /// end up with a profile.
    func warmUpModels() {
        guard warmUpTask == nil else { return }
        warmUpTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await speakerModels.identifier(threshold: settings.similarityThreshold)
            } catch {
                guard !Task.isCancelled else { return }
                self.notice = """
                    The on-device voice models aren't loaded yet (\(Self.describe(error))). \
                    You can still record — KVoice will try again when it processes the audio.
                    """
            }
        }
    }

    // MARK: - Guided capture

    func startRecording() async {
        guard case .ready = stage, isGuided else { return }

        notice = nil
        elapsed = 0
        level = 0
        stage = .requestingPermission

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-enrollment-\(UUID().uuidString).m4a")

        let source = MicSource(inputDeviceUID: settings.inputDeviceUID)
        do {
            try await source.start(writingTo: url)
        } catch {
            stage = .failed(
                (error as? RecordingError) == .microphonePermissionDenied
                    ? .microphoneDenied
                    : .other(Self.describe(error))
            )
            return
        }

        self.source = source
        self.captureURL = url
        stage = .recording
        observe(source)
    }

    /// Stops capture and starts processing. Called by the Stop button and by
    /// the tick task when the script's 30 seconds are up.
    func finishRecording() async {
        guard case .recording = stage, let source else { return }
        stage = .finishing

        let summary = await source.stop()
        cancelObservers()
        self.source = nil
        level = 0

        let duration = summary?.duration ?? elapsed
        elapsed = duration

        guard let summary, summary.frameCount > 0, duration >= EnrollmentScript.minimumDuration else {
            discardCapture()
            stage = .failed(.audioTooShort(seconds: duration))
            return
        }

        await process(clips: [summary.url], source: .enrollment)
    }

    /// Abandons the take without processing it.
    func cancelRecording() async {
        guard case .recording = stage else { return }
        if let source { _ = await source.stop() }
        cancelObservers()
        self.source = nil
        discardCapture()
        level = 0
        elapsed = 0
        stage = .ready
    }

    // MARK: - Clips

    func setClips(_ urls: [URL]) {
        clipURLs = urls
    }

    func startClipEnrollment() async {
        guard case .ready = stage, !clipURLs.isEmpty else { return }
        await process(clips: clipURLs, source: .upload)
    }

    // MARK: - Retry

    func retry() async {
        switch stage {
        case .failed(let failure) where failure.isRetryable:
            switch mode {
            case .guided:
                // The captured file is still on disk when the failure came
                // after capture — re-embed it rather than making them read
                // again. Otherwise start over.
                if let captureURL, FileManager.default.fileExists(atPath: captureURL.path) {
                    await process(clips: [captureURL], source: .enrollment)
                } else {
                    stage = .ready
                }
            case .clips:
                await process(clips: clipURLs, source: .upload)
            }
        default:
            break
        }
    }

    // MARK: - The pipeline

    /// Window → embed → fold in. The shared tail of both creation paths.
    private func process(clips: [URL], source embeddingSource: EmbeddingSource) async {
        // Read the audio first. It is cheap next to model inference, it tells
        // us how many windows there will be, and it fails *before* a ~100 MB
        // download when a clip is unreadable.
        stage = .reading

        let extractor = AudioSpanExtractor()
        var windowCount = 0
        do {
            for clip in clips {
                windowCount += try extractor.windows(from: clip, windowSeconds: 5).count
            }
        } catch {
            stage = .failed(.unreadableAudio(Self.describe(error)))
            return
        }

        guard windowCount > 0 else {
            let seconds = clips.compactMap { try? extractor.duration(of: $0) }.reduce(0, +)
            stage = .failed(.audioTooShort(seconds: seconds))
            return
        }

        stage = .embedding(windowCount: windowCount)

        let vectors: [[Float]]
        do {
            let identifier = try await speakerModels.identifier(
                threshold: settings.similarityThreshold
            )
            vectors = try await identifier.enrollmentEmbeddings(clips: clips, windowSeconds: 5)
        } catch let error as SpeakerEmbedderError {
            stage = .failed(Self.classify(error))
            return
        } catch {
            stage = .failed(.other(Self.describe(error)))
            return
        }

        guard !vectors.isEmpty else {
            stage = .failed(
                .other(
                    """
                    None of the \(windowCount) audio window(s) produced a usable voice sample. \
                    That usually means the recording is mostly silence — check the input device \
                    and try again.
                    """
                )
            )
            return
        }

        stage = .saving
        do {
            let personID = try await resolvePersonID()
            let outcome = try await profiles.foldIn(
                contentsOf: vectors,
                intoPersonWithID: personID,
                source: embeddingSource
            )
            // v1 does not keep source clips. The spec makes them optional
            // ("optionally the source clips") and keeping a copy of every
            // enrollment read would grow a folder no screen ever shows. The
            // vectors are what identification needs; the audio is not.
            discardCapture()

            stage = .finished(
                Result(
                    personID: personID,
                    personName: outcome.name,
                    added: vectors.count,
                    total: outcome.embeddingCount,
                    evicted: outcome.evictedCount
                )
            )
        } catch {
            stage = .failed(.other(Self.describe(error)))
        }
    }

    /// The person to write to, creating them if this enrollment is what brings
    /// them into existence.
    private func resolvePersonID() async throws -> UUID {
        if let id = target.existingID { return id }
        return try await profiles.createPerson(named: trimmedName).id
    }

    private static func classify(_ error: SpeakerEmbedderError) -> Failure {
        switch error {
        case .modelsNotPrepared, .modelPreparationFailed:
            return .modelsUnavailable(
                (error as LocalizedError).errorDescription ?? String(describing: error)
            )
        case .audioTooShort:
            return .audioTooShort(seconds: 0)
        case .embeddingUnavailable(let detail):
            return .other(detail)
        }
    }

    // MARK: - Observing the source

    private func observe(_ source: MicSource) {
        levelTask = Task { [weak self] in
            for await value in source.levelStream {
                self?.level = value
            }
            self?.level = 0
        }

        eventTask = Task { [weak self] in
            for await event in source.events {
                self?.handle(event)
            }
        }

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.elapsed = source.recordedDuration
                // The script's own length is the stop condition: nobody should
                // have to watch a clock while reading aloud.
                if self.elapsed >= EnrollmentScript.targetDuration {
                    await self.finishRecording()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func handle(_ event: RecordingEvent) {
        switch event {
        case .started, .resumed:
            notice = nil
        case .paused(let reason):
            switch reason {
            case .user:
                break
            case .deviceLost:
                notice = "The input device changed, so capture stopped. Start again when ready."
            case .interrupted:
                notice = "The system interrupted capture. Start again when ready."
            case .writeFailure:
                notice = "Writing to disk failed. Free some space and start again."
            }
        case .stopped:
            break
        case .failed(let error):
            if notice == nil { notice = Self.describe(error) }
        }
    }

    private func cancelObservers() {
        levelTask?.cancel()
        eventTask?.cancel()
        tickTask?.cancel()
        levelTask = nil
        eventTask = nil
        tickTask = nil
    }

    // MARK: - Temporary audio

    /// Removes the temporary capture file.
    ///
    /// Called on success, on abandonment, and when the sheet closes — the file
    /// lives in `NSTemporaryDirectory` and is never the user's own audio, so
    /// there is no path on which it should survive the sheet.
    private func discardCapture() {
        guard let captureURL else { return }
        try? FileManager.default.removeItem(at: captureURL)
        self.captureURL = nil
    }

    /// Tears everything down when the sheet goes away.
    func tearDown() async {
        warmUpTask?.cancel()
        warmUpTask = nil
        if let source { _ = await source.stop() }
        source = nil
        cancelObservers()
        discardCapture()
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
