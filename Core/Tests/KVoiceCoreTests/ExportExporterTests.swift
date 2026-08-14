import Foundation
import Testing

@testable import KVoiceCore

/// The export facade: render a transcript, name the file after the recording,
/// put it on disk (`docs/spec.md` §Export — "filenames follow the recording
/// title").
@Suite("Export exporter")
struct ExportExporterTests {

    private let utc = ExportFixture.utc

    private func export(
        _ document: TranscriptDocument,
        as format: ExportFormat,
        to folder: URL,
        collision: Exporter.CollisionPolicy = .overwrite
    ) throws -> URL {
        try Exporter.export(document, as: format, to: folder, collision: collision, timeZone: utc)
    }

    private func contents(of url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    // MARK: - Naming

    @Test("the file is named after the recording, with the format's extension")
    func fileNames() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        #expect(try export(ExportFixture.meeting, as: .markdown, to: directory.url).lastPathComponent
            == "Weekly sync.md")
        #expect(try export(ExportFixture.meeting, as: .plainText, to: directory.url).lastPathComponent
            == "Weekly sync.txt")
        #expect(try export(ExportFixture.meeting, as: .word, to: directory.url).lastPathComponent
            == "Weekly sync.docx")
    }

    /// The same sanitizer that names the recording's folder and `.m4a`, so an
    /// export sits beside its audio under a matching name.
    @Test("a title with illegal filename characters is sanitized")
    func sanitizesTitle() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let document = TranscriptDocument(title: "Q1/Q2: Review?", date: .distantPast, turns: [])

        let url = try export(document, as: .markdown, to: directory.url)

        #expect(url.lastPathComponent == "Q1 Q2 Review.md")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("an untitled recording exports under the fallback name")
    func untitledFallsBack() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let document = TranscriptDocument(title: "   ", date: .distantPast, turns: [])

        #expect(try export(document, as: .markdown, to: directory.url).lastPathComponent
            == "\(FilenameSanitizer.fallbackName).md")
    }

    @Test("the filename helper agrees with what export writes")
    func fileNameHelper() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        #expect(Exporter.fileName(for: "Weekly sync", format: .word) == "Weekly sync.docx")
        #expect(Exporter.fileName(for: "Q1/Q2", format: .plainText) == "Q1 Q2.txt")
        #expect(
            try export(ExportFixture.meeting, as: .word, to: directory.url).lastPathComponent
                == Exporter.fileName(for: ExportFixture.meeting.title, format: .word)
        )
    }

    @Test("the file lands inside the requested folder")
    func writesIntoFolder() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = try export(ExportFixture.meeting, as: .markdown, to: directory.url)

        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.url.standardizedFileURL)
    }

    // MARK: - Contents

    @Test("each format writes exactly what its renderer produced")
    func contentsMatchRenderers() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let document = ExportFixture.meeting

        let markdown = try export(document, as: .markdown, to: directory.url)
        let plain = try export(document, as: .plainText, to: directory.url)
        let word = try export(document, as: .word, to: directory.url)

        #expect(try contents(of: markdown) == MarkdownRenderer.render(document, timeZone: utc))
        #expect(try contents(of: plain) == PlainTextRenderer.render(document, timeZone: utc))
        #expect(try Data(contentsOf: word) == (try DocxRenderer.render(document, timeZone: utc)))
    }

    @Test("rendering to bytes matches what would be written")
    func dataMatchesWrittenFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        for format in ExportFormat.allCases {
            let url = try export(ExportFixture.meeting, as: format, to: directory.url)
            let rendered = try Exporter.data(for: ExportFixture.meeting, format: format, timeZone: utc)

            #expect(try Data(contentsOf: url) == rendered, "mismatch for \(format)")
        }
    }

    @Test("the exported .docx on disk is a readable package")
    func exportedDocxIsAValidPackage() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = try export(ExportFixture.meeting, as: .word, to: directory.url)
        let archive = try ZipReader.read(try Data(contentsOf: url))

        #expect(archive.entries.count == 5)
        #expect(archive.entry("word/document.xml") != nil)
    }

    // MARK: - Collisions

    /// An export is a regenerated artifact: re-exporting should refresh the
    /// file rather than pile up copies next to the recording.
    @Test("re-exporting overwrites by default")
    func overwritesByDefault() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
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

        let firstURL = try export(first, as: .markdown, to: directory.url)
        let secondURL = try export(second, as: .markdown, to: directory.url)

        #expect(firstURL == secondURL)
        #expect(try contents(of: secondURL).contains("Edited."))
        #expect(!(try contents(of: secondURL).contains("Original.")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).count == 1)
    }

    @Test("the unique-suffix policy keeps both files")
    func uniqueSuffixKeepsBoth() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let first = try export(ExportFixture.meeting, as: .markdown, to: directory.url, collision: .uniqueSuffix)
        let second = try export(ExportFixture.meeting, as: .markdown, to: directory.url, collision: .uniqueSuffix)
        let third = try export(ExportFixture.meeting, as: .markdown, to: directory.url, collision: .uniqueSuffix)

        #expect(first.lastPathComponent == "Weekly sync.md")
        #expect(second.lastPathComponent == "Weekly sync 2.md")
        #expect(third.lastPathComponent == "Weekly sync 3.md")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).count == 3)
    }

    @Test("collisions are counted per format, not across formats")
    func collisionsArePerExtension() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        _ = try export(ExportFixture.meeting, as: .markdown, to: directory.url, collision: .uniqueSuffix)
        let text = try export(ExportFixture.meeting, as: .plainText, to: directory.url, collision: .uniqueSuffix)

        #expect(text.lastPathComponent == "Weekly sync.txt")
    }

    // MARK: - Destinations

    @Test("a missing destination folder is created, including intermediates")
    func createsMissingFolder() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let nested = directory.url
            .appendingPathComponent("2026-08-13 Standup", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)

        let url = try export(ExportFixture.meeting, as: .markdown, to: nested)

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("exporting into a path that is a file fails with a clear error")
    func destinationIsAFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let file = directory.file("not-a-folder")
        try Data("x".utf8).write(to: file)

        #expect(throws: ExportError.destinationNotADirectory(path: file.path)) {
            try export(ExportFixture.meeting, as: .markdown, to: file)
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
        #expect(ExportFormat.word.fileExtension == "docx")
        #expect(ExportFormat.word.uniformTypeIdentifier == "org.openxmlformats.wordprocessingml.document")
        #expect(ExportFormat.allCases.count == 3)
    }

    /// The default export format is persisted in settings, so the raw values
    /// are a stored format that must not drift.
    @Test("raw values are stable, because settings persist them")
    func rawValuesAreStable() {
        #expect(ExportFormat.markdown.rawValue == "markdown")
        #expect(ExportFormat.plainText.rawValue == "plainText")
        #expect(ExportFormat.word.rawValue == "word")
        #expect(ExportFormat(rawValue: "word") == .word)
    }
}
