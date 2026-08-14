import AVFoundation
import Foundation

@testable import KVoiceCore

// MARK: - Transcript fixtures

enum Fixture {

    /// Builds a word with millisecond timings.
    static func word(
        _ text: String = "word",
        _ start: Int,
        _ end: Int,
        speaker: String? = nil,
        confidence: Double = 0.95
    ) -> TranscriptResponse.Word {
        TranscriptResponse.Word(text: text, start: start, end: end, confidence: confidence, speaker: speaker)
    }

    /// Builds an utterance whose words evenly tile `start..<end` with a gap
    /// between them, so voiced time is a predictable fraction of the span.
    ///
    /// - Parameters:
    ///   - wordCount: How many words to lay down.
    ///   - gapMs: Silence between consecutive words.
    static func utterance(
        speaker: String,
        start: Int,
        end: Int,
        wordCount: Int = 10,
        gapMs: Int = 20
    ) -> TranscriptResponse.Utterance {
        precondition(end > start && wordCount > 0)
        let total = end - start
        let stride = total / wordCount
        var words: [TranscriptResponse.Word] = []

        for index in 0..<wordCount {
            let wordStart = start + index * stride
            let wordEnd = index == wordCount - 1 ? end : wordStart + max(1, stride - gapMs)
            words.append(word("w\(index)", wordStart, wordEnd, speaker: speaker))
        }

        return TranscriptResponse.Utterance(
            speaker: speaker,
            text: words.map(\.text).joined(separator: " "),
            start: start,
            end: end,
            words: words
        )
    }

    /// A transcript whose flat `words[]` is derived from its utterances —
    /// matching what AssemblyAI returns with diarization on.
    static func transcript(
        id: String = "t-1",
        status: TranscriptResponse.Status = .completed,
        audioDuration: Double? = nil,
        utterances: [TranscriptResponse.Utterance]
    ) -> TranscriptResponse {
        TranscriptResponse(
            id: id,
            status: status,
            audioDuration: audioDuration,
            utterances: utterances,
            words: utterances.flatMap(\.words).sorted { $0.start < $1.start }
        )
    }
}

// MARK: - Vectors

enum TestVectors {
    /// A deterministic unit vector: `dimension`-d, seeded, L2-normalized.
    static func unit(seed: Int, dimension: Int = 256) -> [Float] {
        var state = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        var values = [Float](repeating: 0, count: dimension)
        for index in 0..<dimension {
            // xorshift64 — reproducible across platforms and runs.
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            values[index] = Float(Int64(bitPattern: state % 2_000)) / 1_000 - 1
        }
        return VectorMath.l2Normalized(values)
    }

    /// A unit vector at a controlled cosine similarity to `base`.
    static func neighbor(of base: [Float], similarity: Float, seed: Int = 99) -> [Float] {
        let other = unit(seed: seed, dimension: base.count)
        // Gram-Schmidt: strip the component along `base`, then recombine at the
        // requested angle.
        let projection = VectorMath.dot(other, base)
        var orthogonal = [Float](repeating: 0, count: base.count)
        for index in base.indices {
            orthogonal[index] = other[index] - projection * base[index]
        }
        orthogonal = VectorMath.l2Normalized(orthogonal)

        let complement = (1 - similarity * similarity).squareRoot()
        var result = [Float](repeating: 0, count: base.count)
        for index in base.indices {
            result[index] = similarity * base[index] + complement * orthogonal[index]
        }
        return VectorMath.l2Normalized(result)
    }
}

/// Whether two vectors point the same way.
///
/// `foldIn` re-normalizes on the way in, so a stored copy of an already-unit
/// vector differs from the original in the last float bits. Direction is what
/// the pipeline actually depends on, so that is what tests assert.
func isSameDirection(_ a: [Float], _ b: [Float], tolerance: Float = 1e-5) -> Bool {
    a.count == b.count && VectorMath.cosineSimilarity(a, b) > 1 - tolerance
}

// MARK: - Mock transcription provider

/// Scripted `TranscriptionProvider` for poller/backoff tests.
///
/// Never touches the network. Each `poll` consumes the next scripted step, so
/// a test can express "queued, queued, rate-limited, completed" exactly.
final class MockTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {

    enum Step {
        case response(TranscriptResponse)
        case failure(TranscriptionError)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private(set) var pollCount = 0
    private(set) var uploadCount = 0
    private(set) var createCount = 0
    private(set) var lastRequest: TranscriptRequest?

    let uploadURL: URL
    let transcriptID: String

    init(
        steps: [Step],
        uploadURL: URL = URL(string: "https://cdn.assemblyai.com/upload/mock")!,
        transcriptID: String = "t-mock"
    ) {
        self.steps = steps
        self.uploadURL = uploadURL
        self.transcriptID = transcriptID
    }

    func upload(fileURL: URL) async throws -> URL {
        lock.withLock { uploadCount += 1 }
        return uploadURL
    }

    func createTranscript(_ request: TranscriptRequest) async throws -> String {
        lock.withLock {
            createCount += 1
            lastRequest = request
        }
        return transcriptID
    }

    func poll(id: String) async throws -> TranscriptResponse {
        let step: Step = try lock.withLock {
            pollCount += 1
            guard !steps.isEmpty else {
                throw TranscriptionError.malformedResponse(description: "mock ran out of scripted steps")
            }
            return steps.removeFirst()
        }

        switch step {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }

    var polls: Int { lock.withLock { pollCount } }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

// MARK: - Virtual clock

/// Records the delays a poller asks for and advances a fake clock instead of
/// sleeping, so backoff behavior is asserted exactly and instantly.
final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    private var recorded: [TimeInterval] = []
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    var delays: [TimeInterval] { lock.withLock { recorded } }
    var totalElapsed: TimeInterval { lock.withLock { elapsed } }

    /// Drop-in for the poller's `sleep`.
    func sleep(_ interval: TimeInterval) async throws {
        lock.withLock {
            recorded.append(interval)
            elapsed += interval
        }
    }

    /// Drop-in for the poller's `now`.
    func now() -> Date {
        lock.withLock { start.addingTimeInterval(elapsed) }
    }
}

// MARK: - Mock speaker embedder

/// Deterministic `SpeakerEmbedder` that needs no model and no network.
///
/// Maps audio to a vector by a caller-supplied rule, so pipeline tests can
/// stage "these samples belong to Alice" without any ML.
final class StubEmbedder: SpeakerEmbedder, @unchecked Sendable {
    private let lock = NSLock()
    private let rule: @Sendable ([Float]) -> [Float]
    private var _calls = 0
    private var _failures: [Int: SpeakerEmbedderError]

    var calls: Int { lock.withLock { _calls } }

    /// - Parameters:
    ///   - failures: Call indices (0-based) that should throw instead.
    ///   - rule: Maps samples to an embedding.
    init(
        failures: [Int: SpeakerEmbedderError] = [:],
        rule: @escaping @Sendable ([Float]) -> [Float]
    ) {
        self.rule = rule
        self._failures = failures
    }

    /// Emits a fixed vector regardless of input.
    convenience init(constant: [Float]) {
        self.init(rule: { _ in constant })
    }

    /// Picks a vector by inspecting the first sample — lets a test encode
    /// "which speaker" into synthetic audio it generates.
    convenience init(byFirstSample table: [Float: [Float]], fallback: [Float]) {
        self.init(rule: { samples in
            guard let first = samples.first else { return fallback }
            return table[first] ?? fallback
        })
    }

    func embedding(for samples: [Float]) async throws -> [Float] {
        let index: Int = lock.withLock {
            defer { _calls += 1 }
            return _calls
        }
        if let failure = lock.withLock({ _failures[index] }) { throw failure }
        return VectorMath.l2Normalized(rule(samples))
    }
}

// MARK: - Temporary files

/// A directory under the system temp dir, removed on `cleanUp()`.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Synthetic audio

enum TestAudio {

    /// Writes a mono/stereo Float32 WAV built from a per-channel generator.
    ///
    /// Used instead of a checked-in fixture so span extraction is tested on
    /// audio whose exact content is known.
    @discardableResult
    static func writeWAV(
        to url: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        seconds: Double,
        sample: (_ channel: Int, _ frame: Int) -> Float
    ) throws -> URL {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            throw TestAudioError.badFormat
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw TestAudioError.badFormat
        }
        buffer.frameLength = frameCount

        guard let data = buffer.floatChannelData else { throw TestAudioError.badFormat }
        for channel in 0..<Int(file.processingFormat.channelCount) {
            for frame in 0..<Int(frameCount) {
                data[channel][frame] = sample(channel, frame)
            }
        }

        try file.write(from: buffer)
        return url
    }

    /// A constant-amplitude sine.
    static func sine(frequency: Double, sampleRate: Double, amplitude: Float = 0.5) -> (Int, Int) -> Float {
        { _, frame in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
        }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for value in samples { sum += value * value }
        return (sum / Float(samples.count)).squareRoot()
    }

    enum TestAudioError: Error { case badFormat }
}
