import ArgumentParser
import Foundation
import KVoiceCore

/// `speakerlab enroll <name> <clips...>` — embeds clips of one person's
/// voice and adds them to their local profile.
///
/// Clips are chunked into fixed windows and each window becomes its own
/// stored embedding (plan §3 risk 9): a profile that holds several vectors
/// from one session models that person's variation far better than a single
/// averaged vector does.
struct Enroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add voice clips to a person's local profile.",
        discussion: """
            Each clip is decoded to 16 kHz mono, split into ~5 s windows, and embedded \
            with the on-device WeSpeaker model. Embeddings are appended to the named \
            profile, oldest evicted past a cap of \(SpeakerProfile.defaultEmbeddingCap).

            The profile library is a plain JSON file (default ~/.speakerlab/profiles.json).

            MODELS
              On first use, ~100 MB of CoreML models download from Hugging Face into
                \(FluidAudioEmbedder.defaultModelDirectory.path)
              For an offline machine, stage pyannote_segmentation.mlmodelc and
              wespeaker_v2.mlmodelc there yourself, or point --segmentation-model and
              --embedding-model at them. Nothing is downloaded during builds or tests.
            """
    )

    @Argument(help: "Name of the person to enroll.")
    var name: String

    @Argument(help: "Paths to audio clips of this person speaking.")
    var clips: [String] = []

    @OptionGroup var profileOptions: ProfileOptions
    @OptionGroup var modelOptions: ModelOptions

    @Option(
        name: .customLong("source"),
        help: "How to tag these embeddings: enrollment or upload."
    )
    var source: EmbeddingSource = .enrollment

    @Option(name: .customLong("window-seconds"), help: "Window length per embedding.")
    var windowSeconds: Double = 5

    @Flag(
        name: .customLong("replace"),
        help: "Drop the profile's existing embeddings first (re-enroll)."
    )
    var replace: Bool = false

    func run() async throws {
        try await CLI.run {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw SpeakerlabError("Name must not be empty.", code: 64)
            }
            guard !clips.isEmpty else {
                throw SpeakerlabError("At least one clip is required.", code: 64)
            }
            guard windowSeconds > 0 else {
                throw SpeakerlabError("--window-seconds must be positive.", code: 64)
            }

            let clipURLs = try clips.map { try CLI.requireFile($0, label: "Clip") }

            Stdio.note("Loading speaker models…")
            let embedder = try await modelOptions.makeEmbedder()

            let identifier = SpeakerIdentifier(embedder: embedder)
            Stdio.note("Embedding \(clipURLs.count) clip(s) in \(Format.seconds(windowSeconds)) windows…")

            let vectors = try await identifier.enrollmentEmbeddings(
                clips: clipURLs,
                windowSeconds: windowSeconds,
                onProgress: { Stdio.note("  \($0)") }
            )

            guard !vectors.isEmpty else {
                throw SpeakerlabError(
                    "No usable audio in the supplied clip(s) — nothing was enrolled. "
                        + "Clips need at least ~1 s of speech per window."
                )
            }

            let summary = try profileOptions.store.update { library -> String in
                let index = library.upsert(name: trimmedName)
                if replace {
                    library.profiles[index].removeAllEmbeddings()
                }
                library.profiles[index].foldIn(contentsOf: vectors, source: source)

                let profile = library.profiles[index]
                let bySource = EmbeddingSource.allCases
                    .map { "\($0.rawValue): \(profile.embeddingCount(source: $0))" }
                    .joined(separator: ", ")
                return "\(profile.name): +\(vectors.count) embedding(s) → \(profile.embeddingCount) stored (\(bySource))"
            }

            Stdio.note("Saved to \(profileOptions.store.url.path)")
            Stdio.out(summary)
        }
    }
}

/// Lets `--source enrollment` / `--source upload` parse straight into the
/// domain enum. `autolearn` is deliberately absent: it is what `identify
/// --learn` writes, not something to claim by hand.
extension EmbeddingSource: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument.lowercased() {
        case "enrollment": self = .enrollment
        case "upload": self = .upload
        default: return nil
        }
    }

    public static var allValueStrings: [String] { ["enrollment", "upload"] }
}
