import ArgumentParser
import Foundation
import KVoiceCore

/// `speakerlab eval <dir>` — batch accuracy over a labeled corpus.
///
/// This is how the shipped similarity threshold gets chosen (plan §2 Phase 1
/// item 9, §3 decision 7): run every labeled case, then sweep the threshold
/// over the scores that were collected and print accuracy at each one. No
/// re-embedding is needed for the sweep, so tuning costs one pass.
struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run batch speaker-ID accuracy evaluation over a labeled corpus.",
        discussion: """
            EXPECTED LAYOUT

              <dir>/
                case-one/
                  meeting.m4a            one audio file (.m4a/.wav/.mp3/.m4b/.aac/.caf/.flac)
                  meeting.raw.json       raw AssemblyAI response for that audio
                  labels.json            ground truth, keyed by diarized letter
                case-two/
                  ...

            labels.json maps each diarized speaker letter to the person's name, or to
            "unknown" for a voice that has no profile and *should* be rejected:

              { "A": "Alice", "B": "Bob", "C": "unknown" }

            Any subdirectory missing one of the three files is skipped with a warning.
            Speakers absent from labels.json are ignored, so partial labeling is fine.

            OUTPUT
              A per-speaker table, an accuracy summary split into named vs. unknown
              cases, and a threshold sweep. Profiles are never modified.
            """
    )

    @Argument(help: "Directory containing a labeled evaluation corpus.")
    var directory: String

    @OptionGroup var profileOptions: ProfileOptions
    @OptionGroup var modelOptions: ModelOptions

    @Option(name: .customLong("threshold"), help: "Threshold used for the headline accuracy figure.")
    var threshold: Float = ClusterMatcher.defaultThreshold

    @Option(name: .customLong("sweep-from"), help: "Lowest threshold in the sweep.")
    var sweepFrom: Float = 0.40

    @Option(name: .customLong("sweep-to"), help: "Highest threshold in the sweep.")
    var sweepTo: Float = 0.80

    @Option(name: .customLong("sweep-step"), help: "Sweep increment.")
    var sweepStep: Float = 0.02

    /// The label that means "this voice should NOT match any profile".
    static let unknownLabel = "unknown"

    func run() async throws {
        try await CLI.run {
            let root = try CLI.requireDirectory(directory, label: "Corpus directory")
            let cases = try Self.discoverCases(in: root)

            guard !cases.isEmpty else {
                throw SpeakerlabError(
                    "No usable cases in \(root.path). Each case is a subdirectory with an audio "
                        + "file, its .raw.json, and labels.json — see `speakerlab eval --help`."
                )
            }

            let library = try profileOptions.loadLibrary()
            guard !library.profiles.isEmpty else {
                throw SpeakerlabError(
                    "No profiles in \(profileOptions.store.url.path) — every speaker would be unknown. "
                        + "Enroll people first.",
                    code: ExitStatus.preconditionFailure
                )
            }

            Stdio.note("Loading speaker models…")
            let embedder = try await modelOptions.makeEmbedder()
            let identifier = SpeakerIdentifier(
                embedder: embedder,
                matcher: ClusterMatcher(threshold: threshold)
            )

            Stdio.note("Evaluating \(cases.count) case(s) against \(library.profiles.count) profile(s)…")

            var observations: [Observation] = []
            for testCase in cases {
                Stdio.note("  \(testCase.name)…")
                let transcript = try Identify.loadTranscript(at: testCase.transcriptURL)
                let results = try await identifier.identify(
                    audioURL: testCase.audioURL,
                    transcript: transcript,
                    library: library
                )

                for result in results {
                    guard let label = testCase.labels[result.speaker] else { continue }
                    observations.append(
                        Observation(
                            caseName: testCase.name,
                            speaker: result.speaker,
                            label: label,
                            predicted: result.match?.best?.name,
                            score: result.match?.best?.score,
                            spans: result.spans.count,
                            meetsTarget: result.meetsTarget
                        )
                    )
                }
            }

            guard !observations.isEmpty else {
                throw SpeakerlabError("No labeled speakers matched any transcript's diarized letters.")
            }

            Stdio.out(Self.detailTable(observations, threshold: threshold))
            Stdio.out("")
            Stdio.out(Self.summary(observations, threshold: threshold))
            Stdio.out("")
            Stdio.out(
                Self.sweepTable(observations, from: sweepFrom, to: sweepTo, step: sweepStep)
            )
        }
    }

    // MARK: - Corpus discovery

    struct TestCase {
        var name: String
        var audioURL: URL
        var transcriptURL: URL
        var labels: [String: String]
    }

    static let audioExtensions: Set<String> = ["m4a", "wav", "mp3", "m4b", "aac", "caf", "flac", "aiff", "aif"]

    static func discoverCases(in root: URL) throws -> [TestCase] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw SpeakerlabError("Could not list \(root.path): \(CLI.describe(error))")
        }

        var cases: [TestCase] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }

            let name = entry.lastPathComponent
            let files = (try? FileManager.default.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            guard let audio = files.first(where: { audioExtensions.contains($0.pathExtension.lowercased()) }) else {
                Stdio.note("warning: \(name): no audio file — skipped")
                continue
            }
            guard let transcript = files.first(where: { $0.lastPathComponent.hasSuffix(".raw.json") }) else {
                Stdio.note("warning: \(name): no *.raw.json transcript — skipped")
                continue
            }
            let labelsURL = entry.appendingPathComponent("labels.json")
            guard FileManager.default.fileExists(atPath: labelsURL.path) else {
                Stdio.note("warning: \(name): no labels.json — skipped")
                continue
            }

            let labels: [String: String]
            do {
                labels = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: labelsURL))
            } catch {
                Stdio.note("warning: \(name): labels.json is not a {\"A\": \"Name\"} map — skipped")
                continue
            }

            cases.append(TestCase(name: name, audioURL: audio, transcriptURL: transcript, labels: labels))
        }
        return cases
    }

    // MARK: - Scoring

    struct Observation {
        var caseName: String
        var speaker: String
        /// Ground truth: a person's name, or `unknown`.
        var label: String
        /// Best-scoring profile name, independent of threshold.
        var predicted: String?
        var score: Float?
        var spans: Int
        var meetsTarget: Bool

        var expectsUnknown: Bool {
            label.caseInsensitiveCompare(Eval.unknownLabel) == .orderedSame
        }

        /// Whether the pipeline gets this speaker right at a given threshold.
        func isCorrect(at threshold: Float) -> Bool {
            let cleared = (score ?? -1) >= threshold
            if expectsUnknown { return !cleared }
            guard cleared, let predicted else { return false }
            return predicted.caseInsensitiveCompare(label) == .orderedSame
        }
    }

    static func detailTable(_ observations: [Observation], threshold: Float) -> String {
        let header = ["CASE", "SPEAKER", "EXPECTED", "BEST MATCH", "SCORE", "SPANS", "RESULT"]
        let rows = observations.map { observation -> [String] in
            let cleared = (observation.score ?? -1) >= threshold
            let assigned = cleared ? (observation.predicted ?? "—") : Eval.unknownLabel
            return [
                observation.caseName,
                observation.speaker,
                observation.label,
                assigned,
                observation.score.map(Format.score) ?? "—",
                "\(observation.spans)" + (observation.meetsTarget ? "" : "*"),
                observation.isCorrect(at: threshold) ? "ok" : "WRONG"
            ]
        }
        return Format.table(header: header, rows: rows)
    }

    static func summary(_ observations: [Observation], threshold: Float) -> String {
        let named = observations.filter { !$0.expectsUnknown }
        let unknown = observations.filter(\.expectsUnknown)

        func rate(_ group: [Observation]) -> String {
            guard !group.isEmpty else { return "n/a" }
            let correct = group.filter { $0.isCorrect(at: threshold) }.count
            return String(
                format: "%d/%d (%.1f%%)",
                correct, group.count, Double(correct) / Double(group.count) * 100
            )
        }

        let thin = observations.filter { !$0.meetsTarget }.count
        var lines = [
            "Threshold \(Format.score(threshold))",
            "  overall:        \(rate(observations))",
            "  named speakers: \(rate(named))",
            "  unknown voices: \(rate(unknown))"
        ]
        if thin > 0 {
            lines.append("  * \(thin) speaker(s) had fewer clean spans than the target — thin evidence")
        }
        return lines.joined(separator: "\n")
    }

    /// Accuracy at every candidate threshold, computed from the scores already
    /// gathered. The best row is the empirical answer to "what should the
    /// default threshold be?".
    static func sweepTable(_ observations: [Observation], from: Float, to: Float, step: Float) -> String {
        guard step > 0, to >= from else {
            return "Threshold sweep skipped (invalid range)."
        }

        let named = observations.filter { !$0.expectsUnknown }
        let unknown = observations.filter(\.expectsUnknown)

        var rows: [[String]] = []
        var best: (threshold: Float, correct: Int) = (from, -1)

        var value = from
        while value <= to + 1e-6 {
            let correct = observations.filter { $0.isCorrect(at: value) }.count
            if correct > best.correct { best = (value, correct) }

            rows.append([
                Format.score(value),
                String(format: "%.1f%%", Double(correct) / Double(observations.count) * 100),
                "\(named.filter { $0.isCorrect(at: value) }.count)/\(named.count)",
                "\(unknown.filter { $0.isCorrect(at: value) }.count)/\(unknown.count)"
            ])
            value += step
        }

        let table = Format.table(
            header: ["THRESHOLD", "ACCURACY", "NAMED", "UNKNOWN"],
            rows: rows
        )
        return """
            Threshold sweep
            \(table)

            Best: \(Format.score(best.threshold)) \
            (\(best.correct)/\(observations.count) correct)
            """
    }
}
