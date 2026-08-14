import ArgumentParser
import Foundation
import KVoiceCore

/// `speakerlab transcribe <audio>` — uploads a recording to AssemblyAI,
/// polls it to completion, and saves the raw transcript JSON.
///
/// The saved file is the **verbatim** response body, written before any
/// decoding (api-notes decision 1): it is the input to `identify` and the
/// re-processing baseline the spec requires.
struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Upload a recording to AssemblyAI and save the raw transcript JSON.",
        discussion: """
            Requires ASSEMBLYAI_API_KEY in the environment.

            Uploads the file (raw bytes, streamed from disk), creates a transcript with \
            speaker diarization enabled, then polls with exponential backoff until the \
            job completes. Progress goes to stderr; the path of the saved JSON is the \
            only thing printed to stdout.

            By default the response is written next to the audio as <name>.raw.json.
            """
    )

    @Argument(help: "Path to the audio file to transcribe.")
    var file: String

    @Option(name: .shortAndLong, help: "Where to write the raw JSON (default: <audio>.raw.json).")
    var output: String?

    @Option(
        name: .customLong("keyterm"),
        help: ArgumentHelp(
            "Domain term to boost. Repeatable.",
            discussion: "Phrases of up to 6 words. Over-long or duplicate terms are dropped."
        )
    )
    var keyterms: [String] = []

    @Option(
        name: .customLong("keyterms-file"),
        help: "File with one keyterm per line, merged with any --keyterm values."
    )
    var keytermsFile: String?

    @Option(
        name: .customLong("model"),
        help: ArgumentHelp(
            "Speech model, in priority order. Repeatable.",
            discussion: "Defaults to \(AssemblyAIConstants.defaultSpeechModels.joined(separator: ", "))."
        )
    )
    var models: [String] = []

    func run() async throws {
        try await CLI.run {
            let audioURL = try CLI.requireFile(file, label: "Audio file")
            let outputURL = output.map(CLI.url(for:)) ?? Self.defaultOutputURL(for: audioURL)

            let speechModels = models.isEmpty ? AssemblyAIConstants.defaultSpeechModels : models
            for model in speechModels where !AssemblyAIConstants.allowedSpeechModels.contains(model) {
                throw SpeakerlabError(
                    "Unknown speech model '\(model)'. Known values: "
                        + AssemblyAIConstants.allowedSpeechModels.sorted().joined(separator: ", "),
                    code: ExitStatus.preconditionFailure
                )
            }

            let client = try AssemblyAIClient.fromEnvironment(
                configuration: .init(speechModels: speechModels)
            )

            // 1. Upload.
            let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? nil
            Stdio.note(
                "\(TranscriptionStage.uploading.displayName) \(audioURL.lastPathComponent)"
                    + (size.map { " (\(Format.bytes($0)))" } ?? "")
            )
            let started = Date()
            let uploadURL = try await client.upload(fileURL: audioURL)
            Stdio.note("  uploaded in \(Format.seconds(Date().timeIntervalSince(started)))")

            // 2. Create the transcript job.
            let terms = try resolveKeyterms(for: speechModels)
            if !terms.isEmpty {
                Stdio.note("  boosting \(terms.count) keyterm(s)")
            }
            let request = TranscriptRequest(
                audioURL: uploadURL.absoluteString,
                speechModels: speechModels,
                speakerLabels: true,
                keytermsPrompt: terms.isEmpty ? nil : terms
            )
            let id = try await client.createTranscript(request)
            Stdio.note("Transcript \(id) created (models: \(speechModels.joined(separator: " → ")))")

            // 3. Poll to completion, writing the verbatim body before decoding.
            let destination = outputURL
            let response = try await client.waitForCompletion(
                id: id,
                persistRaw: { data in
                    try Self.write(data, to: destination)
                },
                onUpdate: { response, attempt in
                    let stage = TranscriptionStage(status: response.status)
                    var line = "  [\(attempt + 1)] \(stage.displayName)"
                    if let duration = response.audioDuration {
                        line += " (audio \(Format.duration(duration)))"
                    }
                    Stdio.note(line)
                }
            )

            // 4. Summarize to stderr; the path is the machine-readable result.
            let elapsed = Date().timeIntervalSince(started)
            Stdio.note("\(TranscriptionStage.done.displayName) in \(Format.seconds(elapsed))")
            if let model = response.speechModelUsed {
                Stdio.note("  model used: \(model)")
            }
            if let language = response.languageCode {
                Stdio.note("  language: \(language)")
            }
            Stdio.note("  speakers: \(response.speakerLabels.isEmpty ? "none" : response.speakerLabels.joined(separator: ", "))")
            Stdio.note("  utterances: \(response.utterances?.count ?? 0), words: \(response.allWords.count)")
            Stdio.note("")
            Stdio.note("Next: speakerlab identify \(audioURL.path) \(destination.path)")

            Stdio.out(destination.path)
        }
    }

    // MARK: - Helpers

    static func defaultOutputURL(for audioURL: URL) -> URL {
        audioURL
            .deletingPathExtension()
            .appendingPathExtension("raw")
            .appendingPathExtension("json")
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func resolveKeyterms(for speechModels: [String]) throws -> [String] {
        var raw = keyterms

        if let keytermsFile {
            let url = try CLI.requireFile(keytermsFile, label: "Keyterms file")
            let contents: String
            do {
                contents = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw SpeakerlabError("Could not read \(url.path): \(CLI.describe(error))")
            }
            raw.append(contentsOf: contents.split(whereSeparator: \.isNewline).map(String.init))
        }

        let budget = TranscriptRequest.keytermWordBudget(for: speechModels)
        let sanitized = TranscriptRequest.sanitizedKeyterms(raw, wordBudget: budget)
        if sanitized.count < raw.count {
            Stdio.note("  note: dropped \(raw.count - sanitized.count) keyterm(s) over the API's limits")
        }
        return sanitized
    }
}
