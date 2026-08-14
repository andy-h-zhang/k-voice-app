import Foundation
import KVoiceCore

/// The app's single on-device embedder, shared by every transcription job.
///
/// `FluidAudioEmbedder` throws `modelsNotPrepared` until `prepare()` has loaded
/// the CoreML models, and that load is a ~100 MB download on first run. Two
/// consequences shape this type:
///
/// 1. **One embedder for the whole app.** A per-job embedder would re-download
///    (or at least re-load) the models for every recording.
/// 2. **Preparation happens on first use, not at launch.** A user who has not
///    added an API key never transcribes anything and should never pay for the
///    download — which, right now, is every user.
///
/// `prepare()` is idempotent, so the serialization the actor provides is all
/// the coordination needed: the second job to arrive waits for the first job's
/// download and then proceeds.
actor SpeakerModels {

    private let embedder = FluidAudioEmbedder()
    private let state: SpeakerModelState

    init(state: SpeakerModelState) {
        self.state = state
    }

    /// A ready-to-run identifier at the given similarity threshold.
    ///
    /// The threshold comes from the settings snapshot the *job* was built with,
    /// so a threshold edited mid-job cannot change a match already in flight.
    func identifier(threshold: Float) async throws -> SpeakerIdentifier {
        let state = self.state
        try await embedder.prepare { progress in
            Task { @MainActor in state.update(progress) }
        }
        await MainActor.run { state.finish() }

        return SpeakerIdentifier(
            embedder: embedder,
            matcher: ClusterMatcher(threshold: threshold)
        )
    }
}

/// `SpeakerMatching` over the shared embedder — what a `TranscriptionJob` is
/// handed.
///
/// A value type per job holding a reference to the one ``SpeakerModels`` actor:
/// each job carries its own threshold, all of them share one set of loaded
/// models.
struct PreparingSpeakerMatcher: SpeakerMatching {

    let models: SpeakerModels
    let threshold: Float

    func identify(
        audioURL: URL,
        transcript: TranscriptResponse,
        library: ProfileLibrary
    ) async throws -> [SpeakerIdentification] {
        let identifier = try await models.identifier(threshold: threshold)
        return try await identifier.identify(
            audioURL: audioURL,
            transcript: transcript,
            library: library
        )
    }
}
