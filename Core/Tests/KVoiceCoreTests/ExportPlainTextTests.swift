import Foundation
import Testing

@testable import KVoiceCore

/// The plain-text export, locked to a golden file.
///
/// The spec asks for "the same structure, no formatting" as Markdown
/// (`docs/spec.md` §Export), so alongside the golden file there is a test that
/// derives one format from the other — the cheapest way to keep "same
/// structure" true as either renderer changes.
@Suite("Export plain text")
struct ExportPlainTextTests {

    private func render(_ document: TranscriptDocument) -> String {
        PlainTextRenderer.render(document, timeZone: ExportFixture.utc)
    }

    // MARK: - Golden file

    @Test("a two-speaker meeting renders exactly the documented format")
    func goldenFile() {
        let expected = """
            Weekly sync

            2026-08-13 14:30

            Alice — [00:00:05]

            Morning, everyone.

            Let's start with the roadmap.

            Bob — [00:01:12]

            Morning.

            Alice — [01:02:03]

            Wrapping up.

            """

        #expect(render(ExportFixture.meeting) == expected)
    }

    // MARK: - Structure

    @Test("no Markdown markers survive anywhere in the document")
    func noMarkup() {
        let text = render(ExportFixture.meeting)

        #expect(!text.contains("#"))
        #expect(!text.contains("*"))
        #expect(!text.contains("_"))
    }

    /// Strip the heading markers from the Markdown export and the plain-text
    /// export must fall out — that is what "same structure" means.
    @Test("it is the Markdown export minus the heading markers")
    func sameStructureAsMarkdown() {
        let markdown = MarkdownRenderer.render(ExportFixture.meeting, timeZone: ExportFixture.utc)
        let stripped = markdown
            .components(separatedBy: "\n")
            .map { line -> String in
                if line.hasPrefix("## ") { return String(line.dropFirst(3)) }
                if line.hasPrefix("# ") { return String(line.dropFirst(2)) }
                return line
            }
            .joined(separator: "\n")

        #expect(render(ExportFixture.meeting) == stripped)
    }

    @Test("turn headers carry the speaker and a bracketed timestamp")
    func headerFormat() {
        let document = TranscriptDocument(
            title: "T",
            date: ExportFixture.date(2026, 8, 13),
            utterances: [ExportFixture.utterance("Alice", 3_723_000, "Text.")]
        )

        #expect(render(document).contains("Alice — [01:02:03]"))
    }

    @Test("the file ends with exactly one newline")
    func trailingNewline() {
        let text = render(ExportFixture.meeting)

        #expect(text.hasSuffix("Wrapping up.\n"))
        #expect(!text.hasSuffix("\n\n"))
    }

    // MARK: - Edge cases

    @Test("a transcript with no turns still renders a title and date")
    func emptyTranscript() {
        let document = TranscriptDocument(title: "Silent", date: ExportFixture.date(2026, 8, 13, 9, 5), turns: [])

        #expect(render(document) == "Silent\n\n2026-08-13 09:05\n")
    }

    @Test("an untitled recording falls back to the same name the file gets")
    func untitled() {
        let document = TranscriptDocument(title: "  ", date: ExportFixture.date(2026, 8, 13), turns: [])

        #expect(render(document).hasPrefix("\(FilenameSanitizer.fallbackName)\n"))
    }
}
