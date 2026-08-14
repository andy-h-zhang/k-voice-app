import ArgumentParser

/// `speakerlab transcribe <file>` — uploads a recording to AssemblyAI and
/// saves the raw transcript JSON. Implemented in Phase 1.
struct Transcribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Upload a recording to AssemblyAI and save the raw transcript JSON."
    )

    @Argument(help: "Path to the audio file to transcribe.")
    var file: String

    func run() throws {
        print("speakerlab transcribe: not implemented yet (Phase 1)")
        throw ExitCode.failure
    }
}
