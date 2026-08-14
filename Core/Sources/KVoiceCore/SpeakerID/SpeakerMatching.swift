import Foundation

/// The speaker-ID pipeline, as `TranscriptionJob` needs it.
///
/// `SpeakerIdentifier` (Phase 1) is the real implementation and already takes
/// an injectable `SpeakerEmbedder`, so a job test *could* drive the genuine
/// pipeline with a stub embedder — and one does, to prove this seam is not a
/// fiction. But every other job test cares about the state machine, not about
/// decoding audio, and making them all synthesize WAVs would be slow and would
/// couple orchestration tests to `AVFoundation`.
///
/// So the job depends on this one-method protocol instead.
public protocol SpeakerMatching: Sendable {
    /// Identifies every diarized speaker in `transcript` against `library`.
    ///
    /// Must not throw for a speaker that simply cannot be embedded: that case
    /// comes back as a result with a nil `clusterEmbedding` and a warning, so
    /// one unusable participant does not sink the recording.
    func identify(
        audioURL: URL,
        transcript: TranscriptResponse,
        library: ProfileLibrary
    ) async throws -> [SpeakerIdentification]
}

extension SpeakerIdentifier: SpeakerMatching {
    /// Forwards to the full pipeline. Written out rather than relying on the
    /// defaulted `onProgress:` parameter, which does not satisfy a protocol
    /// requirement on its own.
    public func identify(
        audioURL: URL,
        transcript: TranscriptResponse,
        library: ProfileLibrary
    ) async throws -> [SpeakerIdentification] {
        try await identify(
            audioURL: audioURL,
            transcript: transcript,
            library: library,
            onProgress: nil
        )
    }
}

extension SpeakerIdentifier {
    /// Identifies against a `ProfileSource` rather than a loaded library.
    ///
    /// The app path: profiles come from SwiftData, the CLI's come from JSON,
    /// and neither call site has to fetch first.
    public func identify(
        audioURL: URL,
        transcript: TranscriptResponse,
        profiles: some ProfileSource,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [SpeakerIdentification] {
        try await identify(
            audioURL: audioURL,
            transcript: transcript,
            library: profiles.library(),
            onProgress: onProgress
        )
    }
}
