import Foundation
import SwiftData

@testable import KVoiceCore

// MARK: - Containers

enum TestContainer {

    /// Serializes `ModelContainer` construction across the whole suite.
    ///
    /// Twice during Phase 4 a run died with `SIGSEGV` inside CoreData's store
    /// setup, losing the run's buffered output with it:
    ///
    /// ```
    /// -[__NSDictionaryM setObject:forKey:]
    /// -[NSSQLEntity_DerivedAttributesExtension _generateTriggerSQL]
    /// -[NSSQLiteConnection createTriggersForEntities:]
    /// -[NSSQLiteConnection createTablesForEntities:]
    /// -[NSPersistentStoreCoordinator addPersistentStoreWithType:…]
    /// ```
    ///
    /// That is CoreData compiling the model into SQL while mutating shared
    /// state without a lock of its own. Swift Testing runs suites in parallel
    /// and ~35 tests each mint a container, so several threads can be inside
    /// that path at once. Using containers concurrently afterwards is fine —
    /// only *construction* is the problem, which is why serializing it costs
    /// the suite nothing measurable.
    ///
    /// The crash is rare and load-sensitive (it did not recur in 30 subsequent
    /// runs, 14 of them without this lock), so this is a fix argued from the
    /// crash stack rather than from a reproduction. It cannot regress
    /// anything: it removes concurrency from one path and adds none.
    ///
    /// Test-only on purpose. The app builds exactly one container, once, on
    /// the main actor (`AppServices`, memoized by `AppBootstrap`), so
    /// production never enters this race and `KVoiceSchema` is unchanged.
    private static let creationLock = NSLock()

    /// Runs a container-building closure under the suite-wide lock.
    ///
    /// Use this for any construction that does not go through the two helpers
    /// below — every `ModelContainer` in the suite must take the same lock or
    /// the serialization has a hole in it.
    static func serialized<T>(_ build: () throws -> T) rethrows -> T {
        creationLock.lock()
        defer { creationLock.unlock() }
        return try build()
    }

    /// A private in-memory store. Every test gets its own, so suites can run
    /// in parallel and nothing survives a test.
    static func inMemory() throws -> ModelContainer {
        try serialized { try KVoiceSchema.inMemory() }
    }

    /// A store backed by a file, for the tests that assert persistence.
    static func onDisk(inLibraryRoot root: URL) throws -> ModelContainer {
        try serialized { try KVoiceSchema.onDisk(inLibraryRoot: root) }
    }
}

// MARK: - Recording fixtures on disk + in the store

/// A recording that exists both as a row and as a folder on disk.
///
/// `TranscriptionJob` reads the row and writes files next to the audio, so a
/// job test needs both halves. The audio file is a placeholder: matching is
/// stubbed in every test except the one that deliberately drives the real
/// `SpeakerIdentifier`, and nothing else opens it.
struct RecordingFixture {
    let container: ModelContainer
    let root: TemporaryDirectory
    let id: UUID
    let folderName: String
    let audioFileName: String

    var settings: SettingsSnapshot {
        SettingsSnapshot(
            storageFolderURL: root.url,
            similarityThreshold: ClusterMatcher.defaultThreshold,
            keyterms: [],
            defaultExportFormat: .markdown,
            inputDeviceUID: nil
        )
    }

    var folderURL: URL { root.url.appendingPathComponent(folderName, isDirectory: true) }
    var audioURL: URL { folderURL.appendingPathComponent(audioFileName) }
    var rawTranscriptURL: URL {
        folderURL.appendingPathComponent(RawTranscriptStore.defaultFileName)
    }

    init(
        container: ModelContainer,
        title: String = "Standup",
        durationSec: Double = 0,
        status: RecordingStatus = .recorded,
        writeAudioFile: Bool = true,
        audioExtension: String = "m4a",
        writeAudio: ((URL) throws -> Void)? = nil,
        configure: ((Recording) -> Void)? = nil
    ) throws {
        self.container = container
        self.root = try TemporaryDirectory()
        self.folderName = title
        self.audioFileName = "\(title).\(audioExtension)"

        let folder = root.url.appendingPathComponent(title, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let audio = folder.appendingPathComponent("\(title).\(audioExtension)")
        if let writeAudio {
            try writeAudio(audio)
        } else if writeAudioFile {
            // A placeholder: every job test but one stubs speaker matching, so
            // nothing opens this. Only its *existence* is checked, before upload.
            try Data("not really audio".utf8).write(to: audio)
        }

        let context = ModelContext(container)
        let recording = Recording(
            title: title,
            folderName: title,
            audioFileName: "\(title).\(audioExtension)",
            durationSec: durationSec,
            status: status
        )
        configure?(recording)
        context.insert(recording)
        try context.save()
        self.id = recording.id
    }

    func cleanUp() { root.cleanUp() }

    /// Reads the row back through a fresh context — the only honest way to
    /// assert what a job actually persisted.
    func snapshot() throws -> RecordingSnapshot {
        let context = ModelContext(container)
        guard let recording = try context.recording(id: id) else {
            throw TranscriptionJobError.recordingNotFound(id: id)
        }
        return RecordingSnapshot(recording)
    }

    /// Runs a read-only assertion against the live row.
    func withRecording<T>(_ body: (Recording) throws -> T) throws -> T {
        let context = ModelContext(container)
        guard let recording = try context.recording(id: id) else {
            throw TranscriptionJobError.recordingNotFound(id: id)
        }
        return try body(recording)
    }

    /// Mutates the row (used to stage relaunch/confirmation states).
    func mutate(_ body: (Recording, ModelContext) throws -> Void) throws {
        let context = ModelContext(container)
        guard let recording = try context.recording(id: id) else {
            throw TranscriptionJobError.recordingNotFound(id: id)
        }
        try body(recording, context)
        try context.save()
    }

    func writeRawTranscript(_ data: Data) throws {
        try data.write(to: rawTranscriptURL)
    }

    func writeRawTranscript(_ response: TranscriptResponse) throws {
        try writeRawTranscript(try TranscriptFixtures.encode(response))
    }
}

// MARK: - Transcript fixtures

enum TranscriptFixtures {

    static func encode(_ response: TranscriptResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(response)
    }

    /// A finished two-speaker transcript.
    static func completed(
        id: String = "t-1",
        audioDuration: Double? = 120,
        speechModelUsed: String? = "universal-3-5-pro",
        languageCode: String? = "en_us"
    ) -> TranscriptResponse {
        var response = Fixture.transcript(
            id: id,
            status: .completed,
            audioDuration: audioDuration,
            utterances: [
                Fixture.utterance(speaker: "A", start: 0, end: 6_000),
                Fixture.utterance(speaker: "B", start: 6_500, end: 12_000),
                Fixture.utterance(speaker: "A", start: 12_500, end: 18_000)
            ]
        )
        response.speechModelUsed = speechModelUsed
        response.languageCode = languageCode
        response.text = "a b a"
        return response
    }

    static func inProgress(id: String = "t-1", status: TranscriptResponse.Status) -> TranscriptResponse {
        TranscriptResponse(id: id, status: status, audioDuration: 120)
    }

    static func failed(id: String = "t-1", message: String = "upstream exploded") -> TranscriptResponse {
        TranscriptResponse(id: id, status: .error, error: message)
    }
}

// MARK: - Scripted provider

/// A `TranscriptionProvider` whose every stage is scriptable, and which can
/// return **verbatim bytes** rather than a re-encoding.
///
/// The default `pollPersistingRaw` re-encodes our partial DTO, which is fine
/// for most tests but cannot prove "the body is saved before decoding, exactly
/// as it arrived". `.raw` steps carry real bytes so that claim is testable.
final class ScriptedProvider: TranscriptionProvider, @unchecked Sendable {

    enum PollStep {
        /// Verbatim bytes, decoded by the provider exactly as the real client does.
        case raw(Data)
        /// A response, encoded on the way out.
        case response(TranscriptResponse)
        case failure(TranscriptionError)
        /// Stands in for the app quitting mid-poll.
        case cancel
    }

    private let lock = NSLock()
    private var pollSteps: [PollStep]

    var uploadResult: Result<URL, TranscriptionError>
    var createResult: Result<String, TranscriptionError>

    private(set) var uploadCount = 0
    private(set) var createCount = 0
    private(set) var pollCount = 0
    private(set) var lastRequest: TranscriptRequest?

    init(
        uploadResult: Result<URL, TranscriptionError> = .success(
            URL(string: "https://cdn.assemblyai.com/upload/fixture")!
        ),
        createResult: Result<String, TranscriptionError> = .success("t-1"),
        pollSteps: [PollStep] = []
    ) {
        self.uploadResult = uploadResult
        self.createResult = createResult
        self.pollSteps = pollSteps
    }

    /// A provider that fails loudly on any network use. The re-process tests
    /// assert "no network at all", and this is how that is enforced rather
    /// than merely counted.
    static func offline() -> ScriptedProvider {
        ScriptedProvider(
            uploadResult: .failure(.transport(description: "the test forbade network use")),
            createResult: .failure(.transport(description: "the test forbade network use")),
            pollSteps: []
        )
    }

    var counts: (upload: Int, create: Int, poll: Int) {
        lock.withLock { (uploadCount, createCount, pollCount) }
    }

    func setPollSteps(_ steps: [PollStep]) {
        lock.withLock { pollSteps = steps }
    }

    // MARK: TranscriptionProvider

    func upload(fileURL: URL) async throws -> URL {
        try lock.withLock {
            uploadCount += 1
            return try uploadResult.get()
        }
    }

    func createTranscript(_ request: TranscriptRequest) async throws -> String {
        try lock.withLock {
            createCount += 1
            lastRequest = request
            return try createResult.get()
        }
    }

    func poll(id: String) async throws -> TranscriptResponse {
        let (data, _) = try nextStep()
        return try JSONDecoder().decode(TranscriptResponse.self, from: data)
    }

    func pollPersistingRaw(
        id: String,
        persist: @escaping @Sendable (Data) throws -> Void
    ) async throws -> TranscriptResponse {
        let (data, _) = try nextStep()
        // Same ordering contract as AssemblyAIClient: bytes out before decode.
        try persist(data)
        return try JSONDecoder().decode(TranscriptResponse.self, from: data)
    }

    private func nextStep() throws -> (Data, PollStep) {
        try lock.withLock {
            pollCount += 1
            guard !pollSteps.isEmpty else {
                throw TranscriptionError.malformedResponse(
                    description: "scripted provider ran out of poll steps"
                )
            }
            let step = pollSteps.removeFirst()
            switch step {
            case .raw(let data):
                return (data, step)
            case .response(let response):
                return (try TranscriptFixtures.encode(response), step)
            case .failure(let error):
                throw error
            case .cancel:
                throw CancellationError()
            }
        }
    }
}

// MARK: - Scripted speaker matching

/// A `SpeakerMatching` that answers from a script.
///
/// Keeps state-machine tests away from audio decoding and model loading —
/// `SpeakerIdentifierPipelineIsRealTests` covers the genuine implementation
/// through the same seam.
final class StubSpeakerMatching: SpeakerMatching, @unchecked Sendable {

    typealias Handler = @Sendable (URL, TranscriptResponse, ProfileLibrary) throws -> [SpeakerIdentification]

    private let lock = NSLock()
    private var handler: Handler

    private(set) var calls = 0
    private(set) var lastLibrary: ProfileLibrary?
    private(set) var lastAudioURL: URL?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Swaps behavior between runs — how "the matching stage failed, then the
    /// user retried" is expressed against a single job actor.
    func setHandler(_ newValue: @escaping Handler) {
        lock.withLock { handler = newValue }
    }

    /// Every diarized speaker matches the named profile at `score`.
    convenience init(matchesEveryoneAs name: String, score: Float = 0.9, profileID: UUID = UUID()) {
        self.init(handler: { _, transcript, _ in
            transcript.speakerLabels.map { letter in
                SpeakerIdentification(
                    speaker: letter,
                    spans: [],
                    meetsTarget: true,
                    clusterEmbedding: TestVectors.unit(seed: Int(letter.unicodeScalars.first?.value ?? 65)),
                    match: SpeakerMatch(
                        verdict: .matched,
                        best: ProfileScore(profileID: profileID, name: name, score: score, embeddingCount: 1),
                        runnerUp: nil,
                        threshold: ClusterMatcher.defaultThreshold
                    )
                )
            }
        })
    }

    /// Fails outright — the "matching stage blew up" case.
    convenience init(failingWith error: Error) {
        self.init(handler: { _, _, _ in throw error })
    }

    func identify(
        audioURL: URL,
        transcript: TranscriptResponse,
        library: ProfileLibrary
    ) async throws -> [SpeakerIdentification] {
        let current: Handler = lock.withLock {
            calls += 1
            lastLibrary = library
            lastAudioURL = audioURL
            return handler
        }
        return try current(audioURL, transcript, library)
    }
}

/// Builds a matcher that resolves each diarized letter per the supplied table:
/// a nil value means "unknown speaker".
func matching(
    _ table: [String: (name: String, id: UUID, score: Float)?],
    threshold: Float = ClusterMatcher.defaultThreshold
) -> StubSpeakerMatching {
    StubSpeakerMatching(handler: { _, transcript, _ in
        transcript.speakerLabels.map { letter in
            let entry = table[letter] ?? nil
            let seed = Int(letter.unicodeScalars.first?.value ?? 65)
            let best = entry.map {
                ProfileScore(profileID: $0.id, name: $0.name, score: $0.score, embeddingCount: 1)
            }
            return SpeakerIdentification(
                speaker: letter,
                spans: [],
                meetsTarget: true,
                clusterEmbedding: TestVectors.unit(seed: seed),
                match: SpeakerMatch(
                    verdict: entry == nil ? .unknown : .matched,
                    best: best,
                    runnerUp: nil,
                    threshold: threshold
                )
            )
        }
    })
}

// MARK: - Poller that never sleeps

extension TranscriptPoller {
    /// A poller with a virtual clock: no real sleeping, no wall-clock time.
    static func instant(maxConsecutiveFailures: Int = 3) -> TranscriptPoller {
        let clock = VirtualClock()
        return TranscriptPoller(
            maxConsecutiveFailures: maxConsecutiveFailures,
            sleep: { try await clock.sleep($0) },
            now: { clock.now() }
        )
    }
}

// MARK: - Vector comparison

/// Whether two lists of vectors point the same way, pairwise.
///
/// Stored embeddings are re-normalized on the way in (`ProfileFoldPolicy`), so
/// a vector that was already unit-length comes back differing in the last
/// float bits. Direction is what the matcher depends on, so direction is what
/// tests assert — same reasoning as `isSameDirection`.
func haveSameDirections(_ actual: [[Float]], _ expected: [[Float]]) -> Bool {
    actual.count == expected.count
        && zip(actual, expected).allSatisfy { isSameDirection($0, $1) }
}

// MARK: - Event collection

/// Drains a job's event stream into an array.
///
/// The stream finishes on its own at a terminal state, so this returns without
/// a timeout — and if it ever did not, that would be the bug.
func collectEvents(_ job: TranscriptionJob) async -> Task<[TranscriptionJobEvent], Never> {
    let stream = await job.events()
    return Task {
        var events: [TranscriptionJobEvent] = []
        for await event in stream { events.append(event) }
        return events
    }
}
