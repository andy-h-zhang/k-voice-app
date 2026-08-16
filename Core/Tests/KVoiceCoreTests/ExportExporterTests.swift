import Foundation
import Testing

@testable import KVoiceCore

/// The export facade: render a transcript and put it at the URL the caller
/// names (`docs/spec.md` §Export).
///
/// Naming moved out of this type when transcripts moved into project folders —
/// a transcript is `<base> Transcript.md` beside its audio now, which is
/// ``RecordingFolder``'s business. What is left here is rendering and writing,
/// so that is what these cover.
@Suite("Export exporter")
struct ExportExporterTests {

    private let utc = ExportFixture.utc

    private func write(
        _ document: TranscriptDocument,
        as format: ExportFormat,
        to fileURL: URL
    ) throws -> URL {
        try Exporter.write(document, as: format, to: fileURL, timeZone: utc)
    }

    private func contents(of url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    // MARK: - Writing

    @Test("the document is written exactly where it was asked for")
    func writesToTheGivenURL() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let destination = directory.file("2026-08-13 Weekly sync Transcript.md")

        let url = try write(ExportFixture.meeting, as: .markdown, to: destination)

        #expect(url == destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    /// No sanitizing, no suffixing, no title lookup: whatever URL comes in is
    /// the URL written. The caller composed it from an already-sanitized base
    /// name, and a second opinion here could only disagree with the folder.
    @Test("the URL is honoured verbatim, odd characters and all")
    func doesNotRenameWhatItIsGiven() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let destination = directory.file("Q1 Q2 Review Transcript.md")

        let document = TranscriptDocument(title: "Q1/Q2: Review?", date: .distantPast, turns: [])
        let url = try write(document, as: .markdown, to: destination)

        #expect(url.lastPathComponent == "Q1 Q2 Review Transcript.md")
    }

    // MARK: - Contents

    @Test("each format writes exactly what its renderer produced")
    func contentsMatchRenderers() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let document = ExportFixture.meeting

        let markdown = try write(document, as: .markdown, to: directory.file("t.md"))
        let plain = try write(document, as: .plainText, to: directory.file("t.txt"))

        #expect(try contents(of: markdown) == MarkdownRenderer.render(document, timeZone: utc))
        #expect(try contents(of: plain) == PlainTextRenderer.render(document, timeZone: utc))
    }

    @Test("rendering to bytes matches what would be written")
    func dataMatchesWrittenFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        for format in ExportFormat.allCases {
            let url = try write(
                ExportFixture.meeting,
                as: format,
                to: directory.file("t.\(format.fileExtension)")
            )
            let rendered = try Exporter.data(for: ExportFixture.meeting, format: format, timeZone: utc)

            #expect(try Data(contentsOf: url) == rendered, "mismatch for \(format)")
        }
    }

    // MARK: - Overwriting

    /// A transcript file is a rendering of current database state, rewritten
    /// on a debounce as the user types. Anything other than overwrite would
    /// leave a folder full of stale numbered copies.
    @Test("rewriting the same URL overwrites in place")
    func overwritesInPlace() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let destination = directory.file("Sync Transcript.md")

        let first = TranscriptDocument(
            title: "Sync",
            date: ExportFixture.date(2026, 8, 13),
            utterances: [ExportFixture.utterance("Alice", 0, "Original.")]
        )
        let second = TranscriptDocument(
            title: "Sync",
            date: ExportFixture.date(2026, 8, 13),
            utterances: [ExportFixture.utterance("Alice", 0, "Edited.")]
        )

        _ = try write(first, as: .markdown, to: destination)
        _ = try write(second, as: .markdown, to: destination)

        #expect(try contents(of: destination).contains("Edited."))
        #expect(!(try contents(of: destination).contains("Original.")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).count == 1)
    }

    // MARK: - Destinations

    @Test("a missing destination folder is created, including intermediates")
    func createsMissingFolder() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let nested = directory.url
            .appendingPathComponent("2026-08-13 Standup", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("Standup Transcript.md")

        let url = try write(ExportFixture.meeting, as: .markdown, to: nested)

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("writing into a path whose folder is a file fails with a clear error")
    func destinationIsAFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let file = directory.file("not-a-folder")
        try Data("x".utf8).write(to: file)

        #expect(throws: ExportError.destinationNotADirectory(path: file.path)) {
            try write(ExportFixture.meeting, as: .markdown, to: file.appendingPathComponent("t.md"))
        }
    }

    @Test("the error explains itself")
    func errorDescriptions() {
        #expect(
            ExportError.destinationNotADirectory(path: "/tmp/x").errorDescription?
                .contains("not a folder") == true
        )
        #expect(
            ExportError.writeFailed(path: "/tmp/x.md", reason: "disk full").errorDescription?
                .contains("disk full") == true
        )
    }

    // MARK: - Formats

    @Test("formats carry the extensions and identifiers the app needs")
    func formatMetadata() {
        #expect(ExportFormat.markdown.fileExtension == "md")
        #expect(ExportFormat.plainText.fileExtension == "txt")
        #expect(ExportFormat.markdown.uniformTypeIdentifier == "net.daringfireball.markdown")
        #expect(ExportFormat.plainText.uniformTypeIdentifier == "public.plain-text")
        #expect(ExportFormat.allCases.count == 2)
    }

    /// Word is gone: `.docx` is a document you send, and regenerating one on
    /// every keystroke to sit unread in a project folder was not that.
    @Test("Word is no longer a format")
    func wordIsGone() {
        #expect(ExportFormat(rawValue: "word") == nil)
        #expect(!ExportFormat.allCases.contains { $0.fileExtension == "docx" })
    }

    /// Earlier versions persisted the chosen format in UserDefaults, so these
    /// raw values reached users' disks and must keep decoding.
    @Test("raw values are stable, because settings persisted them")
    func rawValuesAreStable() {
        #expect(ExportFormat.markdown.rawValue == "markdown")
        #expect(ExportFormat.plainText.rawValue == "plainText")
        #expect(ExportFormat(rawValue: "markdown") == .markdown)
        #expect(ExportFormat(rawValue: "plainText") == .plainText)
    }
}
