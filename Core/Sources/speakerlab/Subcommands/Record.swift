import ArgumentParser

/// `speakerlab record` — thin CLI wrapper around the recording engine, used
/// to produce test audio for the pipeline above. Implemented in Phase 2.
struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record audio to a .m4a file using the recording engine."
    )

    func run() throws {
        print("speakerlab record: not implemented yet (Phase 2)")
        throw ExitCode.failure
    }
}
