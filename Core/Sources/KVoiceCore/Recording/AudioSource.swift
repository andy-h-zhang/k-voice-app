import AVFoundation
import Foundation

/// A source of audio frames that can be recorded to disk.
///
/// v1 ships `MicSource` (Phase 2), capturing the default/selected input
/// device. v2 adds a `SystemAudioSource` (Core Audio process taps /
/// ScreenCaptureKit) for capturing Zoom/Meet call audio without any change
/// to call sites — that seam is the reason this is a protocol.
///
/// ## Lifecycle
///
/// A source records exactly one file: `start` → (`pause`/`resume`)* → `stop`.
/// `stop()` is terminal and finishes `levelStream` and `events`; create a new
/// instance for the next recording.
///
/// - Note: **Phase 2 protocol change.** The Phase 0 scaffold declared
///   `start(into file: AVAudioFile)` and `stop() async`. Two implementation
///   realities forced a change:
///   1. An AAC `.m4a` is only finalized (its `moov` atom written) when the
///      last reference to the `AVAudioFile` is released. If the caller owns
///      the file, "clean stop produces a playable file" depends on caller
///      discipline — a correctness trap. The source now owns the file, so
///      `stop()` finalizes deterministically.
///   2. `AVAudioFile` is not `Sendable`, so passing one into an `async`
///      requirement is a concurrency hazard the compiler will eventually
///      reject outright.
///   `events` and `recordedDuration` are additions: device loss must surface
///   a typed error (there was no error channel), and elapsed time must come
///   from frames actually written rather than a wall clock that keeps
///   running through a pause.
public protocol AudioSource: Sendable {
    /// Begins capture, creating a new audio file at `url` and streaming
    /// frames into it as they arrive.
    ///
    /// The file is written continuously, so memory use is independent of
    /// recording length. Returns once capture is running.
    ///
    /// - Parameters:
    ///   - url: Destination file. Its path extension must match
    ///     `format.fileExtension` — the container is inferred from it.
    ///   - format: Encoding target (default: AAC 48 kHz mono).
    /// - Throws: ``RecordingError``.
    func start(writingTo url: URL, format: RecordingFormat) async throws

    /// Suspends capture without closing the underlying file.
    ///
    /// Incoming frames are dropped rather than written; level metering keeps
    /// running so a UI meter stays live. No-op unless currently recording.
    func pause() async

    /// Resumes capture after a `pause()`.
    ///
    /// Re-establishes the input tap if it was torn down by a device change,
    /// which means a recording auto-paused by device loss resumes onto
    /// whichever input device is available now.
    ///
    /// - Throws: ``RecordingError`` if capture cannot be re-established.
    func resume() async throws

    /// Stops capture and finalizes the underlying file.
    ///
    /// Finishes `levelStream` and `events`. Returns `nil` if the source never
    /// started. Safe to call more than once (later calls return `nil`).
    @discardableResult
    func stop() async -> RecordingSummary?

    /// A continuous stream of normalized input levels (`0...1`) for
    /// level-meter UI, emitted at roughly 10–20 Hz while capturing.
    var levelStream: AsyncStream<Float> { get }

    /// Significant recording events: pauses (including automatic ones),
    /// resumes, stop, and typed failures such as input-device loss.
    var events: AsyncStream<RecordingEvent> { get }

    /// Audio actually written so far, in seconds. Excludes paused time.
    var recordedDuration: TimeInterval { get }
}

extension AudioSource {
    /// Starts capture in the default recording format (AAC 48 kHz mono).
    public func start(writingTo url: URL) async throws {
        try await start(writingTo: url, format: .aacMono48k)
    }
}

/// The outcome of a finished recording.
public struct RecordingSummary: Sendable, Equatable {
    /// The finalized audio file.
    public let url: URL
    /// Duration of the audio written, in seconds.
    public let duration: TimeInterval
    /// Number of audio frames written.
    public let frameCount: Int64
    /// Sample rate of the written file.
    public let sampleRate: Double
    /// Channel count of the written file.
    public let channelCount: UInt32

    public init(
        url: URL,
        duration: TimeInterval,
        frameCount: Int64,
        sampleRate: Double,
        channelCount: UInt32
    ) {
        self.url = url
        self.duration = duration
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// Why capture was suspended.
public enum PauseReason: Sendable, Equatable {
    /// `pause()` was called.
    case user
    /// The input device went away or the engine reconfigured itself.
    case deviceLost
    /// The system interrupted capture (iOS audio session interruption).
    case interrupted
    /// Writing to disk failed; the file remains valid up to the last frame.
    case writeFailure
}

/// A significant change in a source's recording state.
public enum RecordingEvent: Sendable, Equatable {
    /// Capture started and frames are being written.
    case started
    /// Capture suspended. The file stays open and valid.
    case paused(PauseReason)
    /// Capture resumed after a pause.
    case resumed
    /// Capture stopped and the file was finalized.
    case stopped(RecordingSummary)
    /// A failure occurred. Anything already written stays valid; recovery is
    /// `resume()` (for recoverable cases) or `stop()`.
    case failed(RecordingError)
}
