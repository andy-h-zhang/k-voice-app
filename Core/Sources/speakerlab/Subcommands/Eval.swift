import ArgumentParser

/// `speakerlab eval <dir>` — batch accuracy over a labeled corpus, used to
/// tune the similarity threshold. Implemented in Phase 1.
struct Eval: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run batch speaker-ID accuracy evaluation over a labeled corpus."
    )

    @Argument(help: "Directory containing a labeled evaluation corpus.")
    var directory: String

    func run() throws {
        print("speakerlab eval: not implemented yet (Phase 1)")
        throw ExitCode.failure
    }
}
