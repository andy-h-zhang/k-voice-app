import ArgumentParser
import Foundation
import KVoiceCore

/// `speakerlab identify <audio> <raw.json>` — the full speaker-ID pipeline.
///
/// Selects clean spans per diarized speaker, extracts and embeds them,
/// averages each speaker's spans into a cluster embedding, and cosine-matches
/// that against the enrolled profiles (spec §3). `--learn` closes the loop by
/// folding a confirmed speaker's cluster back into a profile (spec §4).
struct Identify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Match diarized speakers in a transcript against enrolled profiles.",
        discussion: """
            Prints one row per diarized speaker: the letter AssemblyAI assigned, the \
            best-matching profile, the cosine score, the margin over the runner-up, how \
            many spans were embedded, and the verdict.

            A score at or above the threshold (default \(ClusterMatcher.defaultThreshold)) \
            auto-assigns the name; below it the speaker is unknown and wants naming.

            AUTO-LEARN
              --learn A=Alice confirms (or corrects) speaker A and folds that recording's \
            cluster embedding into Alice's profile, creating it if needed. This is what \
            makes recognition improve with use. Repeatable:

                speakerlab identify meeting.m4a meeting.raw.json --learn A=Alice --learn B=Bob

            A '?' verdict row is not an error — exit status stays 0 as long as the run \
            completed.
            """
    )

    @Argument(help: "Path to the audio file the transcript was generated from.")
    var file: String

    @Argument(help: "Path to the raw AssemblyAI transcript JSON for that file.")
    var rawJSON: String

    @OptionGroup var profileOptions: ProfileOptions
    @OptionGroup var modelOptions: ModelOptions

    @Option(
        name: .customLong("threshold"),
        help: "Cosine similarity required to auto-assign a name."
    )
    var threshold: Float = ClusterMatcher.defaultThreshold

    @Option(
        name: .customLong("learn"),
        help: ArgumentHelp(
            "Confirm or correct a speaker, e.g. A=Alice. Repeatable.",
            discussion: "Folds that speaker's cluster embedding into the named profile (auto-learn)."
        )
    )
    var learn: [String] = []

    @Flag(name: .customLong("json"), help: "Emit the result as JSON on stdout instead of a table.")
    var jsonOutput: Bool = false

    func run() async throws {
        try await CLI.run {
            guard threshold >= -1, threshold <= 1 else {
                throw SpeakerlabError("--threshold must be between -1 and 1.", code: 64)
            }

            let audioURL = try CLI.requireFile(file, label: "Audio file")
            let transcriptURL = try CLI.requireFile(rawJSON, label: "Transcript JSON")
            let assignments = try Self.parseLearnAssignments(learn)

            let transcript = try Self.loadTranscript(at: transcriptURL)
            let library = try profileOptions.loadLibrary()

            if library.profiles.isEmpty {
                Stdio.note(
                    "note: no profiles in \(profileOptions.store.url.path) — every speaker will be unknown. "
                        + "Use `speakerlab enroll` first, or --learn to name them here."
                )
            }

            Stdio.note("Loading speaker models…")
            let embedder = try await modelOptions.makeEmbedder()

            let identifier = SpeakerIdentifier(
                embedder: embedder,
                matcher: ClusterMatcher(threshold: threshold)
            )

            Stdio.note("Identifying \(transcript.speakerLabels.count) diarized speaker(s)…")
            let results = try await identifier.identify(
                audioURL: audioURL,
                transcript: transcript,
                library: library,
                onProgress: { Stdio.note("  \($0)") }
            )

            for result in results {
                for warning in result.warnings {
                    Stdio.note("warning: speaker \(result.speaker): \(warning)")
                }
            }

            // Auto-learn before printing, so the printed table reflects the run
            // that produced it and the profile file is already updated.
            let learned = try applyLearning(assignments, to: results)

            if jsonOutput {
                Stdio.out(try Self.jsonReport(results: results, threshold: threshold, learned: learned))
            } else {
                Stdio.out(Self.table(for: results))
                if !learned.isEmpty {
                    Stdio.out("")
                    for line in learned { Stdio.out(line) }
                }
            }
        }
    }

    // MARK: - Learning

    /// Parses `A=Alice` pairs.
    static func parseLearnAssignments(_ raw: [String]) throws -> [(speaker: String, name: String)] {
        try raw.map { entry in
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw SpeakerlabError("--learn expects SPEAKER=Name, got '\(entry)'.", code: 64)
            }
            let speaker = parts[0].trimmingCharacters(in: .whitespaces)
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            guard !speaker.isEmpty, !name.isEmpty else {
                throw SpeakerlabError("--learn expects SPEAKER=Name, got '\(entry)'.", code: 64)
            }
            return (speaker, name)
        }
    }

    private func applyLearning(
        _ assignments: [(speaker: String, name: String)],
        to results: [SpeakerIdentification]
    ) throws -> [String] {
        guard !assignments.isEmpty else { return [] }

        var lines: [String] = []
        try profileOptions.store.update { library in
            for assignment in assignments {
                guard let result = results.first(where: { $0.speaker == assignment.speaker }) else {
                    throw SpeakerlabError(
                        "--learn \(assignment.speaker)=\(assignment.name): no speaker '\(assignment.speaker)' "
                            + "in this transcript (found: \(results.map(\.speaker).joined(separator: ", ")))",
                        code: 64
                    )
                }
                guard let cluster = result.clusterEmbedding else {
                    throw SpeakerlabError(
                        "--learn \(assignment.speaker)=\(assignment.name): speaker '\(assignment.speaker)' "
                            + "produced no embedding, so there is nothing to learn."
                    )
                }

                let index = library.upsert(name: assignment.name)
                let evicted = library.profiles[index].foldIn(cluster, source: .autolearn)
                let profile = library.profiles[index]
                lines.append(
                    "learned: speaker \(assignment.speaker) → \(profile.name) "
                        + "(\(profile.embeddingCount) embedding(s) stored"
                        + (evicted.isEmpty ? "" : ", \(evicted.count) evicted at the cap")
                        + ")"
                )
            }
        }

        Stdio.note("Updated \(profileOptions.store.url.path)")
        return lines
    }

    // MARK: - Input

    static func loadTranscript(at url: URL) throws -> TranscriptResponse {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SpeakerlabError("Could not read \(url.path): \(CLI.describe(error))")
        }

        do {
            return try JSONDecoder().decode(TranscriptResponse.self, from: data)
        } catch {
            throw SpeakerlabError(
                "\(url.lastPathComponent) is not an AssemblyAI transcript response: \(CLI.describe(error))"
            )
        }
    }

    // MARK: - Output

    static func table(for results: [SpeakerIdentification]) -> String {
        let header = ["SPEAKER", "BEST MATCH", "SCORE", "MARGIN", "SPANS", "VOICED", "VERDICT"]
        let rows = results.map { result -> [String] in
            let match = result.match
            let name = match?.best?.name ?? "—"
            let score = match?.best.map { Format.score($0.score) } ?? "—"
            let margin = match?.margin.map { Format.score($0) } ?? "—"
            let voiced = Format.seconds(Double(result.totalVoicedMs) / 1000)

            let verdict: String
            switch match?.verdict {
            case .matched: verdict = result.meetsTarget ? "match" : "match (thin)"
            case .unknown: verdict = "unknown"
            case nil: verdict = "no audio"
            }

            return [
                result.speaker,
                match?.verdict == .matched ? name : (match?.best == nil ? "—" : "(\(name))"),
                score,
                margin,
                "\(result.spans.count)",
                voiced,
                verdict
            ]
        }
        return Format.table(header: header, rows: rows)
    }

    /// Machine-readable form of the same report.
    struct Report: Codable {
        struct Speaker: Codable {
            var speaker: String
            var name: String?
            var bestMatch: String?
            var score: Float?
            var margin: Float?
            var spans: Int
            var voicedSeconds: Double
            var verdict: String
            var meetsTarget: Bool
            var warnings: [String]
        }
        var threshold: Float
        var speakers: [Speaker]
        var learned: [String]
    }

    static func jsonReport(
        results: [SpeakerIdentification],
        threshold: Float,
        learned: [String]
    ) throws -> String {
        let report = Report(
            threshold: threshold,
            speakers: results.map { result in
                Report.Speaker(
                    speaker: result.speaker,
                    name: result.match?.name,
                    bestMatch: result.match?.best?.name,
                    score: result.match?.best?.score,
                    margin: result.match?.margin,
                    spans: result.spans.count,
                    voicedSeconds: Double(result.totalVoicedMs) / 1000,
                    verdict: result.match?.verdict.rawValue ?? "no-audio",
                    meetsTarget: result.meetsTarget,
                    warnings: result.warnings
                )
            },
            learned: learned
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }
}
