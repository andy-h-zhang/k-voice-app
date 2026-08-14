import AVFoundation

/// A source of audio frames that can be recorded to disk.
///
/// v1 ships `MicSource` (Phase 2), capturing the default/selected input
/// device. v2 adds a `SystemAudioSource` (Core Audio process taps /
/// ScreenCaptureKit) for capturing Zoom/Meet call audio without any change
/// to call sites — that seam is the reason this is a protocol.
public protocol AudioSource {
    /// Starts capturing audio, streaming frames into `file` as they arrive.
    ///
    /// Returns once capture has started; the file continues to receive
    /// frames until `stop()` is called.
    func start(into file: AVAudioFile) async throws

    /// Suspends capture without closing the underlying file.
    func pause() async

    /// Resumes capture after a `pause()`.
    func resume() async throws

    /// Stops capture and finalizes the underlying file.
    func stop() async

    /// A continuous stream of normalized input levels (`0...1`) for
    /// level-meter UI. Emits for as long as the source is capturing.
    var levelStream: AsyncStream<Float> { get }
}
