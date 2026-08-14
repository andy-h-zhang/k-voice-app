import ArgumentParser
import Foundation
import KVoiceCore

@main
struct Speakerlab: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speakerlab",
        abstract: "CLI harness for KVoice's speaker-ID pipeline.",
        discussion: """
            Builds and validates the speaker-identification pipeline before any UI \
            exists (spec §3, plan Phase 1).

            Typical flow:
              1. speakerlab transcribe meeting.m4a          # → meeting.raw.json
              2. speakerlab enroll Alice alice-*.m4a        # build a voice profile
              3. speakerlab identify meeting.m4a meeting.raw.json
              4. speakerlab identify … --learn B=Bob        # confirm/correct + auto-learn

            OUTPUT DISCIPLINE
              stdout carries results (tables, JSON, file paths) and nothing else, so \
            it can be piped. Progress, warnings, and errors go to stderr.

            EXIT CODES
              0  success
              1  runtime failure (network, I/O, audio decode, model load)
              2  precondition not met (no API key, unreadable profile library)
              64 usage error (bad arguments)

            ENVIRONMENT
              ASSEMBLYAI_API_KEY  required by `transcribe` only.

            The ~100 MB speaker models download once, at runtime, on first use of \
            `enroll` / `identify` / `eval`. See `speakerlab enroll --help` for \
            offline staging.
            """,
        version: KVoiceCore.version,
        subcommands: [
            Transcribe.self,
            Enroll.self,
            Identify.self,
            Eval.self,
            Record.self
        ]
    )
}

// MARK: - Output

/// stdout is for results, stderr is for everything else. Keeping the two
/// strictly separated is what makes the tool scriptable.
enum Stdio {
    static func out(_ line: String = "") {
        print(line)
    }

    static func err(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    /// Progress/diagnostic line (stderr).
    static func note(_ line: String) {
        err(line)
    }
}

// MARK: - Errors and exit codes

enum ExitStatus {
    static let runtimeFailure: Int32 = 1
    static let preconditionFailure: Int32 = 2
}

/// A failure with a message already written for a human.
struct SpeakerlabError: Error, CustomStringConvertible {
    var description: String
    var code: Int32

    init(_ description: String, code: Int32 = ExitStatus.runtimeFailure) {
        self.description = description
        self.code = code
    }
}

enum CLI {
    /// Runs a command body, mapping any error onto a message on stderr plus a
    /// documented exit code. Commands call this instead of letting errors
    /// escape, so exit codes stay stable for scripts.
    static func run(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let exit as ExitCode {
            throw exit
        } catch let failure as SpeakerlabError {
            Stdio.err("error: \(failure.description)")
            throw ExitCode(failure.code)
        } catch {
            Stdio.err("error: \(describe(error))")
            throw ExitCode(code(for: error))
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func code(for error: Error) -> Int32 {
        switch error {
        case TranscriptionError.missingAPIKey,
            TranscriptionError.unauthorized,
            TranscriptionError.forbidden:
            return ExitStatus.preconditionFailure
        case is ProfileStoreError:
            return ExitStatus.preconditionFailure
        default:
            return ExitStatus.runtimeFailure
        }
    }

    /// Resolves a user-supplied path (expanding `~`) to an absolute URL.
    static func url(for path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func requireFile(_ path: String, label: String) throws -> URL {
        let url = url(for: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw SpeakerlabError("\(label) not found: \(url.path)")
        }
        return url
    }

    static func requireDirectory(_ path: String, label: String) throws -> URL {
        let url = url(for: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw SpeakerlabError("\(label) not found: \(url.path)")
        }
        return url
    }
}

// MARK: - Shared options

/// `--profiles` — where the voice-profile library lives.
struct ProfileOptions: ParsableArguments {
    @Option(
        name: .long,
        help: ArgumentHelp(
            "Path to the profile library JSON.",
            discussion: "Defaults to ~/.speakerlab/profiles.json. Created on first write."
        )
    )
    var profiles: String?

    var store: ProfileStore {
        ProfileStore(url: profiles.map(CLI.url(for:)) ?? ProfileStore.defaultURL)
    }

    func loadLibrary() throws -> ProfileLibrary {
        try store.load()
    }
}

/// Options controlling where the on-device speaker models come from.
struct ModelOptions: ParsableArguments {
    @Option(
        name: .customLong("model-cache"),
        help: ArgumentHelp(
            "Directory for the downloaded CoreML models.",
            discussion: "Defaults to FluidAudio's Application Support cache."
        )
    )
    var modelCache: String?

    @Option(
        name: .customLong("segmentation-model"),
        help: "Path to a staged pyannote_segmentation.mlmodelc (offline use)."
    )
    var segmentationModel: String?

    @Option(
        name: .customLong("embedding-model"),
        help: "Path to a staged wespeaker_v2.mlmodelc (offline use)."
    )
    var embeddingModel: String?

    func validateModelPaths() throws {
        if (segmentationModel == nil) != (embeddingModel == nil) {
            throw SpeakerlabError(
                "--segmentation-model and --embedding-model must be given together.",
                code: ExitStatus.preconditionFailure
            )
        }
    }

    /// Builds and prepares the embedder, reporting download progress on stderr.
    ///
    /// This is the only place a model download can be triggered, and it only
    /// ever happens here at runtime — never in a build or a test.
    func makeEmbedder() async throws -> FluidAudioEmbedder {
        try validateModelPaths()

        let source: FluidAudioEmbedder.ModelSource
        if let segmentationModel, let embeddingModel {
            source = .local(
                segmentation: try CLI.requireDirectory(segmentationModel, label: "Segmentation model"),
                embedding: try CLI.requireDirectory(embeddingModel, label: "Embedding model")
            )
        } else {
            source = .managed(cacheDirectory: modelCache.map(CLI.url(for:)))
        }

        let embedder = FluidAudioEmbedder()
        let reporter = ProgressReporter()

        do {
            try await embedder.prepare(source: source) { progress in
                reporter.report(progress)
            }
        } catch {
            throw SpeakerlabError(
                """
                \(CLI.describe(error))

                The speaker models (~100 MB) are fetched once from Hugging Face and cached in
                  \(FluidAudioEmbedder.defaultModelDirectory.path)
                For an offline machine, copy \(FluidAudioEmbedder.requiredModelFileNames.joined(separator: " and "))
                into that directory, or pass --segmentation-model / --embedding-model.
                """
            )
        }

        return embedder
    }
}

/// Throttles model-download progress so a long download reports movement
/// without flooding stderr.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastMessage: String?
    private var lastFraction: Double = -1

    func report(_ progress: ModelPreparationProgress) {
        lock.lock()
        defer { lock.unlock() }

        let advanced = progress.fractionCompleted - lastFraction >= 0.1
        let changed = progress.message != lastMessage
        guard advanced || changed else { return }

        lastMessage = progress.message
        lastFraction = progress.fractionCompleted

        if progress.fractionCompleted > 0, progress.fractionCompleted < 1 {
            Stdio.note(String(format: "  %3.0f%%  %@", progress.fractionCompleted * 100, progress.message))
        } else {
            Stdio.note("  \(progress.message)")
        }
    }
}

// MARK: - Formatting

enum Format {
    static func seconds(_ value: Double) -> String {
        String(format: "%.1fs", value)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func score(_ value: Float) -> String {
        String(format: "%.3f", value)
    }

    static func bytes(_ count: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }

    /// Renders an aligned text table (header + rows) to stdout.
    static func table(header: [String], rows: [[String]]) -> String {
        let all = [header] + rows
        let columns = header.count
        var widths = [Int](repeating: 0, count: columns)
        for row in all {
            for index in 0..<min(columns, row.count) {
                widths[index] = max(widths[index], row[index].count)
            }
        }

        func render(_ row: [String]) -> String {
            var parts: [String] = []
            for index in 0..<columns {
                let value = index < row.count ? row[index] : ""
                // Last column isn't padded — avoids trailing whitespace.
                parts.append(index == columns - 1 ? value : value.padding(toLength: widths[index], withPad: " ", startingAt: 0))
            }
            return parts.joined(separator: "  ")
        }

        return ([render(header)] + rows.map(render)).joined(separator: "\n")
    }
}
