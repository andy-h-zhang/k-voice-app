/// Produces a fixed-dimension speaker embedding from mono audio samples.
///
/// `FluidAudioEmbedder` (Phase 1) is the default implementation. Keeping
/// this behind a protocol is what makes an ONNX ECAPA-TDNN backend a
/// drop-in fallback if FluidAudio's per-clip embedding access or accuracy
/// doesn't hold up (see plan §0 risk table).
public protocol SpeakerEmbedder: Sendable {
    /// - Parameter samples: 16 kHz mono Float32 PCM samples.
    /// - Returns: An L2-normalized embedding vector.
    func embedding(for samples: [Float]) async throws -> [Float]
}
