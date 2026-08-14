import ArgumentParser
import KVoiceCore

@main
struct Speakerlab: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speakerlab",
        abstract: "CLI harness for KVoice's speaker-ID pipeline.",
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
