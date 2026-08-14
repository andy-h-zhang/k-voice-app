import ArgumentParser

/// `speakerlab identify <file> <raw.json>` — prints each diarized
/// speaker's best profile match and score. Implemented in Phase 1.
struct Identify: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Match diarized speakers in a transcript against enrolled profiles."
    )

    @Argument(help: "Path to the audio file the transcript was generated from.")
    var file: String

    @Argument(help: "Path to the raw AssemblyAI transcript JSON for that file.")
    var rawJSON: String

    func run() throws {
        print("speakerlab identify: not implemented yet (Phase 1)")
        throw ExitCode.failure
    }
}
