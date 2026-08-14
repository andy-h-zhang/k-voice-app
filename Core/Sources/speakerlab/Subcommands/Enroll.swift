import ArgumentParser

/// `speakerlab enroll <name> <clips...>` — embeds clips of one person's
/// voice and adds them to their local profile. Implemented in Phase 1.
struct Enroll: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add voice clips to a person's local profile."
    )

    @Argument(help: "Name of the person to enroll.")
    var name: String

    @Argument(help: "Paths to audio clips of this person speaking.")
    var clips: [String] = []

    func run() throws {
        print("speakerlab enroll: not implemented yet (Phase 1)")
        throw ExitCode.failure
    }
}
