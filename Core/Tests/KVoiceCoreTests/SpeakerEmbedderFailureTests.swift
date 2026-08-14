import Foundation
import Testing

@testable import KVoiceCore

/// The model-preparation failure path — Phase 8's "FluidAudio model download
/// fails on first run" edge.
///
/// The download itself can't be exercised offline, but every way it can fail
/// funnels through one `catch` in ``FluidAudioEmbedder/prepare(source:progress:)``,
/// and the `.local` staging branch reaches that same `catch` without a network:
/// point it at files that do not exist and the library throws exactly where a
/// failed download would. What matters for the app is what comes *out* of that
/// catch — a typed, explainable error rather than a crash, a hang, or a raw
/// CoreML dump — and that is what these tests pin.
///
/// Nothing here downloads or loads a model: `.local` never touches the network,
/// and `embedding(for:)` refuses before it would use one.
@Suite("Speaker embedder — model preparation failures")
struct SpeakerEmbedderFailureTests {

    /// The app calls `embedding` through `SpeakerIdentifier`; if models failed
    /// to prepare, this is the error the enrollment UI has to explain.
    @Test("embedding before prepare() is refused rather than crashing")
    func embeddingWithoutPreparation() async throws {
        let embedder = FluidAudioEmbedder()
        #expect(await embedder.isPrepared == false)

        // Two seconds of 16 kHz audio: comfortably past the short-span guard,
        // so the failure we see is the un-prepared one and not a length check.
        let samples = [Float](repeating: 0.1, count: 32_000)
        await #expect(throws: SpeakerEmbedderError.modelsNotPrepared) {
            _ = try await embedder.embedding(for: samples)
        }
    }

    @Test("a failed preparation explains itself instead of dumping an enum")
    func failedPreparationIsExplainable() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-no-such-models-\(UUID().uuidString)", isDirectory: true)

        let embedder = FluidAudioEmbedder()
        do {
            try await embedder.prepare(
                source: .local(
                    segmentation: missing.appendingPathComponent("pyannote_segmentation.mlmodelc"),
                    embedding: missing.appendingPathComponent("wespeaker_v2.mlmodelc")
                )
            )
            Issue.record("expected preparation to fail with no models on disk")
        } catch let error as SpeakerEmbedderError {
            guard case .modelPreparationFailed(let detail) = error else {
                Issue.record("expected .modelPreparationFailed, got \(error)")
                return
            }
            // The detail is the library's own message. We don't pin its wording
            // — only that something was said, and that the app-facing sentence
            // wraps it in a form a person can act on.
            #expect(detail.isEmpty == false)
            #expect(
                error.errorDescription?.hasPrefix("Could not load the speaker-embedding models:") == true
            )
        }

        // A failed prepare must leave the actor reusable, not half-initialized:
        // the enrollment sheet's "Try Again" button calls prepare() again on
        // this same instance.
        #expect(await embedder.isPrepared == false)
    }

    /// When the download fails for good (no network, Hugging Face unreachable),
    /// the documented recovery is staging the two model bundles by hand. The
    /// app's "Show Model Folder" button and the README's offline-staging note
    /// both read these two values, so they are load-bearing, not trivia.
    @Test("the offline staging contract names both models and a real folder")
    func offlineStagingContract() {
        let names = FluidAudioEmbedder.requiredModelFileNames
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.hasSuffix(".mlmodelc") })
        #expect(Set(names).count == 2, "the two model files must be distinct")

        let directory = FluidAudioEmbedder.defaultModelDirectory
        #expect(directory.isFileURL)
        #expect(directory.path.contains("FluidAudio"))
    }
}
