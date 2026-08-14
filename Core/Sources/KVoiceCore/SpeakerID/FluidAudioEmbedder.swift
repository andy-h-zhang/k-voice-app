import FluidAudio
import Foundation

/// Progress while the embedding models are being fetched/loaded.
///
/// A deliberate translation layer: the app and CLI report progress without
/// importing FluidAudio, which keeps the ONNX ECAPA-TDNN fallback (plan §0) a
/// drop-in swap rather than a call-site rewrite.
public struct ModelPreparationProgress: Sendable, Equatable {
    /// `0...1` where known.
    public var fractionCompleted: Double
    /// Human-readable status, ready to print.
    public var message: String

    public init(fractionCompleted: Double, message: String) {
        self.fractionCompleted = fractionCompleted
        self.message = message
    }
}

public enum SpeakerEmbedderError: Error, Sendable, Equatable {
    case modelsNotPrepared
    case modelPreparationFailed(String)
    case audioTooShort(sampleCount: Int, minimum: Int)
    case embeddingUnavailable(String)
}

extension SpeakerEmbedderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelsNotPrepared:
            return "Speaker-embedding models are not loaded. Call prepare() first."
        case .modelPreparationFailed(let detail):
            return "Could not load the speaker-embedding models: \(detail)"
        case .audioTooShort(let count, let minimum):
            return "Audio span is too short to embed (\(count) samples; need at least \(minimum))."
        case .embeddingUnavailable(let detail):
            return "Could not compute a speaker embedding: \(detail)"
        }
    }
}

/// On-device speaker embeddings via FluidAudio's WeSpeaker v2 CoreML model.
///
/// ## What the API actually looks like (FluidAudio 0.15.5, read from source)
///
/// The plan (§0) expected to reach embeddings through
/// `performCompleteDiarization` → `speakerDatabase`. The shipping library has
/// a better door: `DiarizerManager.extractSpeakerEmbedding(from:)` takes
/// 16 kHz mono Float32 for a *single* speaker and returns the 256-d vector
/// directly. That is exactly this type's job, so it is what we call.
/// (`speakerDatabase` is in fact only populated when `DiarizerConfig.debugMode`
/// is on, and `DiarizationResult.chunkEmbeddings` only by the *offline*
/// pipeline — neither is a supported path for per-clip embedding.)
///
/// Nothing here is `async` on FluidAudio's side: `DiarizerManager`'s init,
/// `initialize(models:)`, and `extractSpeakerEmbedding` are all synchronous.
/// Only model *download* is async.
///
/// ## The 10-second window (important)
///
/// `EmbeddingExtractor` binds the model's waveform input to a fixed
/// `[3, 160_000]` shape — **10 seconds at 16 kHz**. Shorter audio is
/// repeat-padded by the library; longer audio is *silently truncated* to the
/// first 10 s. Since `UtteranceSelector` targets spans of 5–15 s, this type
/// windows anything longer than 10 s itself and averages the per-window
/// embeddings, so the whole span contributes instead of just its head.
///
/// ## Models and offline staging
///
/// Two CoreML bundles (~100 MB together) are fetched once from Hugging Face
/// (`FluidInference/speaker-diarization-coreml`) and cached in Application
/// Support:
///
/// ```text
/// ~/Library/Application Support/FluidAudio/Models/speaker-diarization/
///     pyannote_segmentation.mlmodelc     ← shape source for the embedding mask
///     wespeaker_v2.mlmodelc              ← the 256-d embedding model
/// ```
///
/// `prepare(source: .managed(...))` downloads them if absent and is a no-op
/// afterwards. **The download happens at runtime, in the CLI, never during a
/// build or a test.** For a machine that must stay offline, copy those two
/// `.mlmodelc` bundles into the directory above from a machine that has them
/// (or straight from the Hugging Face repo) and use
/// `prepare(source: .local(segmentation:embedding:))`, which loads the given
/// paths and never touches the network. `FluidAudio.ModelHub.offlineMode =
/// true` additionally turns any accidental network path into a hard error
/// rather than a hang.
///
/// ## Concurrency
///
/// An `actor` because `DiarizerManager` is a non-`Sendable` final class and
/// CoreML prediction is not reentrant-safe here. Inference is synchronous, so
/// an `embedding(for:)` call occupies the actor for its duration; spans are
/// embedded one at a time by design.
public actor FluidAudioEmbedder: SpeakerEmbedder {

    /// WeSpeaker v2 output width.
    public static let embeddingDimension = 256

    /// The model's fixed waveform width: 10 s at 16 kHz. Not a tunable — it
    /// is compiled into the CoreML model (`EmbeddingExtractor`).
    public static let modelWindowSamples = 160_000

    public struct Configuration: Sendable, Equatable {
        /// Samples per inference window. Must not exceed
        /// `modelWindowSamples`; anything more would be truncated by the model.
        public var windowSamples: Int

        /// Shortest audio worth embedding. Below ~1 s the repeat-padding the
        /// library applies dominates the signal and the vector is noise.
        public var minWindowSamples: Int

        public init(
            windowSamples: Int = FluidAudioEmbedder.modelWindowSamples,
            minWindowSamples: Int = 16_000
        ) {
            self.windowSamples = min(windowSamples, FluidAudioEmbedder.modelWindowSamples)
            self.minWindowSamples = minWindowSamples
        }

        public static let `default` = Configuration()
    }

    /// Where the CoreML models come from.
    public enum ModelSource: Sendable {
        /// Download-if-needed into FluidAudio's Application Support cache.
        /// `cacheDirectory` overrides the location; `nil` uses the default.
        case managed(cacheDirectory: URL?)
        /// Load two staged `.mlmodelc` bundles. Never touches the network.
        case local(segmentation: URL, embedding: URL)

        public static var managed: ModelSource { .managed(cacheDirectory: nil) }
    }

    private let configuration: Configuration
    private var manager: DiarizerManager?

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    public var isPrepared: Bool { manager != nil }

    /// FluidAudio's model cache directory, for diagnostics and offline staging.
    public nonisolated static var defaultModelDirectory: URL {
        DiarizerModels.defaultModelsDirectory()
    }

    /// The two files that must be present for offline staging.
    public nonisolated static var requiredModelFileNames: [String] {
        [ModelNames.Diarizer.segmentationFile, ModelNames.Diarizer.embeddingFile]
    }

    /// Loads the models, downloading them on first use when `source` is
    /// `.managed`. Safe to call repeatedly; later calls are no-ops.
    public func prepare(
        source: ModelSource = .managed,
        progress: (@Sendable (ModelPreparationProgress) -> Void)? = nil
    ) async throws {
        guard manager == nil else { return }

        let models: DiarizerModels
        do {
            switch source {
            case .managed(let cacheDirectory):
                progress?(
                    ModelPreparationProgress(
                        fractionCompleted: 0,
                        message: "Checking speaker models in \((cacheDirectory ?? Self.defaultModelDirectory).path)"
                    )
                )
                var handler: ProgressHandler?
                if let progress {
                    handler = { @Sendable snapshot in progress(Self.translate(snapshot)) }
                }
                models = try await DiarizerModels.downloadIfNeeded(
                    to: cacheDirectory,
                    progressHandler: handler
                )

            case .local(let segmentation, let embedding):
                progress?(
                    ModelPreparationProgress(fractionCompleted: 0, message: "Loading staged models from disk")
                )
                models = try DiarizerModels.load(
                    localSegmentationModel: segmentation,
                    localEmbeddingModel: embedding
                )
            }
        } catch {
            throw SpeakerEmbedderError.modelPreparationFailed(
                (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }

        let manager = DiarizerManager()
        manager.initialize(models: models)
        self.manager = manager

        progress?(ModelPreparationProgress(fractionCompleted: 1, message: "Speaker models ready"))
    }

    /// Releases the CoreML models.
    public func unload() {
        manager?.cleanup()
        manager = nil
    }

    // MARK: - SpeakerEmbedder

    /// Embeds one audio span.
    ///
    /// - Parameter samples: 16 kHz mono Float32 (see `AudioSpanExtractor`).
    /// - Returns: A 256-d **L2-normalized** vector. Spans longer than the
    ///   model's 10 s window are split, embedded separately, and averaged.
    public func embedding(for samples: [Float]) async throws -> [Float] {
        guard let manager else { throw SpeakerEmbedderError.modelsNotPrepared }
        guard samples.count >= configuration.minWindowSamples else {
            throw SpeakerEmbedderError.audioTooShort(
                sampleCount: samples.count,
                minimum: configuration.minWindowSamples
            )
        }

        let ranges = Self.windowRanges(
            sampleCount: samples.count,
            windowSamples: configuration.windowSamples,
            minWindowSamples: configuration.minWindowSamples
        )

        var vectors: [[Float]] = []
        vectors.reserveCapacity(ranges.count)

        for range in ranges {
            // A fresh 0-based Array: `extractSpeakerEmbedding` is generic over
            // RandomAccessCollection with Int indices, and a zero-based buffer
            // sidesteps any slice-offset assumptions in the library's
            // vDSP-based copies.
            let window = Array(samples[range])
            let raw = try manager.extractSpeakerEmbedding(from: window)
            guard manager.validateEmbedding(raw) else { continue }
            vectors.append(VectorMath.l2Normalized(raw))
        }

        guard let centroid = VectorMath.centroid(vectors) else {
            throw SpeakerEmbedderError.embeddingUnavailable(
                "no valid embedding from \(ranges.count) window(s) of \(samples.count) samples"
            )
        }
        return centroid
    }

    // MARK: - Windowing

    /// Splits a sample count into inference windows.
    ///
    /// - At most `windowSamples` per window, because the model truncates
    ///   anything longer.
    /// - A trailing remainder of at least `minWindowSamples` becomes its own
    ///   (short, repeat-padded) window.
    /// - A shorter remainder is covered by a final window aligned to the *end*
    ///   of the buffer. That overlaps its predecessor, which is preferable to
    ///   discarding the tail of a span.
    ///
    /// Pure and static so the windowing rule is unit-tested without loading a
    /// model or touching the network.
    public nonisolated static func windowRanges(
        sampleCount: Int,
        windowSamples: Int = FluidAudioEmbedder.modelWindowSamples,
        minWindowSamples: Int = 16_000
    ) -> [Range<Int>] {
        guard sampleCount > 0, windowSamples > 0 else { return [] }
        guard sampleCount > windowSamples else { return [0..<sampleCount] }

        var ranges: [Range<Int>] = []
        var start = 0
        while start + windowSamples <= sampleCount {
            ranges.append(start..<(start + windowSamples))
            start += windowSamples
        }

        let remainder = sampleCount - start
        if remainder >= minWindowSamples {
            ranges.append(start..<sampleCount)
        } else if remainder > 0 {
            ranges.append((sampleCount - windowSamples)..<sampleCount)
        }
        return ranges
    }

    private nonisolated static func translate(_ progress: DownloadProgress) -> ModelPreparationProgress {
        let message: String
        switch progress.phase {
        case .listing:
            message = "Listing model files"
        case .downloading(let completed, let total):
            // A cache hit still reports a downloading phase, with no files.
            message = total > 0
                ? "Downloading speaker models (\(completed)/\(total) files, ~100 MB one time)"
                : "Using cached speaker models"
        case .compiling(let modelName):
            // FluidAudio emits one compile event with an empty name.
            message = modelName.isEmpty ? "Compiling speaker models" : "Compiling \(modelName)"
        }
        return ModelPreparationProgress(
            fractionCompleted: progress.fractionCompleted,
            message: message
        )
    }
}
