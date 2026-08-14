import Foundation
import Testing

@testable import KVoiceCore

/// The Markdown export, locked to a golden file.
///
/// `docs/spec.md` §Export names this format exactly — `## Speaker —
/// [hh:mm:ss]` headers with paragraphs — and it is one of the three exports
/// the acceptance criteria check, so the whole rendered document is asserted
/// rather than a few substrings.
@Suite("Export markdown")
struct ExportMarkdownTests {

    private func render(_ document: TranscriptDocument) -> String {
        MarkdownRenderer.render(document, timeZone: ExportFixture.utc)
    }

    // MARK: - Golden file

    @Test("a two-speaker meeting renders exactly the documented format")
    func goldenFile() {
        let expected = """
            # Weekly sync

            2026-08-13 14:30

            ## Alice — [00:00:05]

            Morning, everyone.

            Let's start with the roadmap.

            ## Bob — [00:01:12]

            Morning.

            ## Alice — [01:02:03]

            Wrapping up.

            """

        #expect(render(ExportFixture.meeting) == expected)
    }

    // MARK: - Structure

    @Test("turn headers are second-level headings with a bracketed timestamp")
    func headerFormat() {
        let document = TranscriptDocument(
            title: "T",
            date: ExportFixture.date(2026, 8, 13),
            utterances: [ExportFixture.utterance("Alice", 3_723_000, "Text.")]
        )

        #expect(render(document).contains("## Alice — [01:02:03]"))
    }

    @Test("the title is a first-level heading and the date follows it")
    func titleAndDate() {
        let lines = render(ExportFixture.meeting).components(separatedBy: "\n")

        #expect(lines.first == "# Weekly sync")
        #expect(lines[1].isEmpty)
        #expect(lines[2] == "2026-08-13 14:30")
    }

    @Test("every block is separated by a blank line")
    func blankLineSeparated() {
        let text = render(ExportFixture.meeting)

        #expect(!text.contains("\n\n\n"))
        #expect(text.contains("Morning, everyone.\n\nLet's start with the roadmap."))
    }

    @Test("the file ends with exactly one newline")
    func trailingNewline() {
        let text = render(ExportFixture.meeting)

        #expect(text.hasSuffix("Wrapping up.\n"))
        #expect(!text.hasSuffix("\n\n"))
    }

    @Test("a turn with several utterances renders one paragraph each, under one header")
    func multiParagraphTurn() {
        let document = TranscriptDocument(
            title: "T",
            date: ExportFixture.date(2026, 8, 13),
            utterances: [
                ExportFixture.utterance("Alice", 0, "One."),
                ExportFixture.utterance("Alice", 1_000, "Two.")
            ]
        )
        let text = render(document)

        #expect(text.hasSuffix("## Alice — [00:00:00]\n\nOne.\n\nTwo.\n"))
        #expect(text.components(separatedBy: "## ").count == 2)
    }

    // MARK: - Edge cases

    @Test("a transcript with no turns still renders a title and date")
    func emptyTranscript() {
        let document = TranscriptDocument(title: "Silent", date: ExportFixture.date(2026, 8, 13, 9, 5), turns: [])

        #expect(render(document) == "# Silent\n\n2026-08-13 09:05\n")
    }

    @Test("an untitled recording falls back rather than emitting a bare '#'")
    func untitled() {
        let document = TranscriptDocument(title: "", date: ExportFixture.date(2026, 8, 13), turns: [])

        #expect(render(document).hasPrefix("# \(FilenameSanitizer.fallbackName)\n"))
    }

    /// Escaping `*` or `_` would corrupt a transcript that legitimately
    /// contains them; these documents are read as prose.
    @Test("transcript text is emitted verbatim, not Markdown-escaped")
    func textIsVerbatim() {
        let document = ExportFixture.document(text: "We shipped *v2* — costs went from 100% to 50%_ish.")

        #expect(render(document).contains("We shipped *v2* — costs went from 100% to 50%_ish."))
    }

    @Test("a speaker whose name looks like markup is left alone")
    func speakerNameIsVerbatim() {
        let document = ExportFixture.document(text: "Hi.", speaker: "A*B")

        #expect(render(document).contains("## A*B — "))
    }
}
