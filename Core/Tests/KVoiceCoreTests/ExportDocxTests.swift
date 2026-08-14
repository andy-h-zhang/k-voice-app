import Foundation
import Testing

@testable import KVoiceCore

/// The `.docx` export: OOXML parts, escaping, and the package they ship in.
///
/// The acceptance criterion is that the file opens in Word and imports into
/// Google Docs (`docs/spec.md` §Export), which a human confirms visually. What
/// is testable here is everything that would stop it before a human ever sees
/// it: well-formed XML, the relationship graph that makes the parts reachable,
/// a valid archive, and text that survives escaping unchanged.
@Suite("Export docx")
struct ExportDocxTests {

    private func parts(_ document: TranscriptDocument) -> [DocxRenderer.Part] {
        DocxRenderer.parts(for: document, timeZone: ExportFixture.utc)
    }

    private func documentXML(_ document: TranscriptDocument) -> String {
        DocxRenderer.documentXML(document, timeZone: ExportFixture.utc)
    }

    private func render(_ document: TranscriptDocument) throws -> Data {
        try DocxRenderer.render(document, timeZone: ExportFixture.utc)
    }

    /// The `w:t` contents of a rendered document, in order, as read back by an
    /// XML parser rather than by string matching.
    private func wordText(_ document: TranscriptDocument) throws -> [String] {
        try #require(WordTextCollector.parse(documentXML(document)))
    }

    // MARK: - Package parts

    @Test("the package carries the parts a word-processing document needs")
    func partPaths() {
        #expect(parts(ExportFixture.meeting).map(\.path) == [
            "[Content_Types].xml",
            "_rels/.rels",
            "word/_rels/document.xml.rels",
            "word/document.xml",
            "word/styles.xml"
        ])
    }

    @Test("every part is well-formed XML")
    func partsAreWellFormed() {
        for part in parts(ExportFixture.meeting) {
            #expect(WordTextCollector.isWellFormed(part.xml), "malformed XML in \(part.path)")
        }
    }

    @Test("content types declare both overrides and the rels default")
    func contentTypes() {
        let xml = DocxRenderer.contentTypesXML

        #expect(xml.contains("<Default Extension=\"rels\""))
        #expect(xml.contains("<Default Extension=\"xml\""))
        #expect(xml.contains("PartName=\"/word/document.xml\""))
        #expect(xml.contains("wordprocessingml.document.main+xml"))
        #expect(xml.contains("PartName=\"/word/styles.xml\""))
        #expect(xml.contains("wordprocessingml.styles+xml"))
    }

    @Test("the package relationship points at the main document")
    func packageRelationships() {
        let xml = DocxRenderer.packageRelationshipsXML

        #expect(xml.contains("Target=\"word/document.xml\""))
        #expect(xml.contains("relationships/officeDocument"))
    }

    /// Without this relationship the styles part is unreachable and readers
    /// ignore it.
    @Test("the document relationship makes the styles part reachable")
    func documentRelationships() {
        let xml = DocxRenderer.documentRelationshipsXML

        #expect(xml.contains("Target=\"styles.xml\""))
        #expect(xml.contains("relationships/styles"))
    }

    @Test("styles define a default paragraph style and the speaker-turn style")
    func styles() {
        let xml = DocxRenderer.stylesXML

        #expect(xml.contains("w:styleId=\"Normal\""))
        #expect(xml.contains("w:default=\"1\""))
        #expect(xml.contains("w:styleId=\"\(DocxRenderer.speakerTurnStyleID)\""))
        #expect(xml.contains("<w:keepNext/>"))
        #expect(xml.contains("<w:docDefaults>"))
    }

    /// The spec asks for Word's own defaults, so no font is imposed.
    @Test("no font family is specified anywhere")
    func noFontImposed() {
        for part in parts(ExportFixture.meeting) {
            #expect(!part.xml.contains("w:rFonts"), "\(part.path) pins a font")
        }
    }

    // MARK: - Document content

    @Test("the document reads title, date, then speaker headers and paragraphs in order")
    func textOrder() throws {
        #expect(try wordText(ExportFixture.meeting) == [
            "Weekly sync",
            "2026-08-13 14:30",
            "Alice",
            " — [00:00:05]",
            "Morning, everyone.",
            "Let's start with the roadmap.",
            "Bob",
            " — [00:01:12]",
            "Morning.",
            "Alice",
            " — [01:02:03]",
            "Wrapping up."
        ])
    }

    @Test("speaker names are bold and timestamps are subdued gray")
    func turnHeaderFormatting() {
        let xml = documentXML(ExportFixture.meeting)

        #expect(xml.contains("<w:r><w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">Alice</w:t></w:r>"))
        #expect(
            xml.contains(
                "<w:rPr><w:color w:val=\"\(DocxRenderer.subduedGray)\"/></w:rPr>"
                    + "<w:t xml:space=\"preserve\"> — [00:00:05]</w:t>"
            )
        )
    }

    @Test("transcript paragraphs carry no run properties of their own")
    func bodyTextIsPlain() {
        let xml = documentXML(ExportFixture.document(text: "Just words."))

        #expect(xml.contains("<w:r><w:t xml:space=\"preserve\">Just words.</w:t></w:r>"))
    }

    @Test("turn headers use the speaker-turn paragraph style")
    func turnHeaderStyle() {
        let xml = documentXML(ExportFixture.meeting)

        #expect(xml.contains("<w:pPr><w:pStyle w:val=\"\(DocxRenderer.speakerTurnStyleID)\"/></w:pPr>"))
    }

    @Test("the body ends with section properties")
    func sectionProperties() {
        let xml = documentXML(ExportFixture.meeting)

        #expect(xml.contains("<w:sectPr>"))
        #expect(xml.contains("<w:pgMar"))
    }

    @Test("a transcript with no turns still produces a valid document")
    func emptyTranscript() throws {
        let document = TranscriptDocument(title: "Silent", date: ExportFixture.date(2026, 8, 13, 9, 5), turns: [])

        #expect(try wordText(document) == ["Silent", "2026-08-13 09:05"])
        #expect(WordTextCollector.isWellFormed(documentXML(document)))
    }

    // MARK: - Escaping

    @Test("XML metacharacters are escaped and read back unchanged")
    func escapingRoundTrip() throws {
        let text = "Tom & Jerry <b>bold</b> \"quoted\" 'single' 5 > 3 & done"
        let document = ExportFixture.document(text: text)

        #expect(try wordText(document).last == text)
    }

    @Test("the raw XML contains entities, not the literal characters")
    func escapedEntitiesAppear() {
        let xml = documentXML(ExportFixture.document(text: "A & B <c> \"d\" 'e'"))

        #expect(xml.contains("A &amp; B &lt;c&gt; &quot;d&quot; &apos;e&apos;"))
    }

    @Test("an ampersand-heavy title is escaped too")
    func titleIsEscaped() throws {
        let document = TranscriptDocument(title: "R&D <2026>", date: ExportFixture.date(2026, 8, 13), turns: [])

        #expect(try wordText(document).first == "R&D <2026>")
        #expect(documentXML(document).contains("R&amp;D &lt;2026&gt;"))
    }

    @Test("a speaker name with markup characters is escaped")
    func speakerNameIsEscaped() throws {
        let document = ExportFixture.document(text: "Hi.", speaker: "A & <B>")

        #expect(try wordText(document).contains("A & <B>"))
    }

    /// XML 1.0 has no representation for these at all, so they are dropped
    /// rather than encoded — the alternative is a package no reader accepts.
    @Test("control characters XML cannot represent are dropped")
    func controlCharactersDropped() throws {
        let document = ExportFixture.document(text: "bell\u{7}here\u{0}now\u{1F}end")

        #expect(try wordText(document).last == "bellherenowend")
        #expect(WordTextCollector.isWellFormed(documentXML(document)))
    }

    @Test("tabs survive, since XML allows them")
    func tabsSurvive() throws {
        let document = ExportFixture.document(text: "column\tvalue")

        #expect(try wordText(document).last == "column\tvalue")
    }

    @Test("non-ASCII text passes through as UTF-8")
    func unicodeSurvives() throws {
        let document = ExportFixture.document(text: "会議は 9 時です — café ☕️")

        #expect(try wordText(document).last == "会議は 9 時です — café ☕️")
    }

    /// A newline inside `w:t` is insignificant whitespace in WordprocessingML,
    /// so an edited utterance containing one would lose its line break.
    @Test("line breaks in edited text become w:br elements")
    func lineBreaks() throws {
        let document = ExportFixture.document(text: "Line one\nLine two")
        let xml = documentXML(document)

        #expect(xml.contains("<w:br/>"))
        #expect(try wordText(document).suffix(2) == ["Line one", "Line two"])
    }

    // MARK: - The package

    @Test("the rendered file is a zip whose entries are the package parts")
    func packageIsAValidArchive() throws {
        let archive = try ZipReader.read(try render(ExportFixture.meeting))

        #expect(archive.entries.map(\.path) == parts(ExportFixture.meeting).map(\.path))
        #expect(archive.declaredEntryCount == 5)
    }

    /// Readers look for the content-types part at the front of the archive.
    @Test("[Content_Types].xml is the first entry")
    func contentTypesComesFirst() throws {
        let archive = try ZipReader.read(try render(ExportFixture.meeting))

        #expect(archive.entries.first?.path == "[Content_Types].xml")
        #expect(archive.entries.first?.localHeaderOffset == 0)
    }

    @Test("every package entry is stored with a correct checksum")
    func packageEntriesAreStored() throws {
        for entry in try ZipReader.read(try render(ExportFixture.meeting)).entries {
            #expect(entry.method == 0)
            #expect(entry.flags == 0x0800)
            #expect(entry.crc == CRC32.checksum(entry.contents))
            #expect(entry.compressedSize == entry.uncompressedSize)
        }
    }

    @Test("the archived parts are byte-identical to the rendered XML")
    func archivedPartsMatchRenderedXML() throws {
        let archive = try ZipReader.read(try render(ExportFixture.meeting))

        for part in parts(ExportFixture.meeting) {
            #expect(archive.text(part.path) == part.xml, "mismatch in \(part.path)")
        }
    }

    @Test("re-exporting an unchanged transcript produces identical bytes")
    func deterministic() throws {
        #expect(try render(ExportFixture.meeting) == (try render(ExportFixture.meeting)))
    }

    // MARK: - Third-party verification

    @Test("/usr/bin/unzip accepts the .docx package")
    func unzipAcceptsTheDocx() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let url = directory.file("Weekly sync.docx")
        try render(ExportFixture.meeting).write(to: url)

        guard let test = try ExportTool.run("/usr/bin/unzip", ["-t", url.path]) else { return }

        #expect(test.succeeded, "unzip -t rejected the .docx: \(test.output)")
        #expect(test.output.contains("No errors detected"))
    }

    /// macOS's own OOXML reader parsing the file is the closest automated
    /// stand-in for "opens in Word": `textutil` fails outright on a package
    /// whose parts or relationships are wrong.
    @Test("macOS textutil parses the .docx and recovers the transcript text")
    func textutilParsesTheDocx() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let url = directory.file("Weekly sync.docx")
        try render(ExportFixture.meeting).write(to: url)

        guard let converted = try ExportTool.run(
            "/usr/bin/textutil",
            ["-convert", "txt", "-stdout", url.path]
        ) else { return }

        #expect(converted.succeeded, "textutil rejected the .docx: \(converted.output)")
        #expect(converted.output.contains("Weekly sync"))
        #expect(converted.output.contains("Alice"))
        #expect(converted.output.contains("[00:00:05]"))
        #expect(converted.output.contains("Morning, everyone."))
        #expect(converted.output.contains("Wrapping up."))
    }

    @Test("textutil recovers text that needed escaping")
    func textutilRecoversEscapedText() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let url = directory.file("Escapes.docx")
        try render(ExportFixture.document(text: "Tom & Jerry <b> \"quoted\"")).write(to: url)

        guard let converted = try ExportTool.run(
            "/usr/bin/textutil",
            ["-convert", "txt", "-stdout", url.path]
        ) else { return }

        #expect(converted.succeeded, "textutil rejected the .docx: \(converted.output)")
        #expect(converted.output.contains("Tom & Jerry <b> \"quoted\""))
    }
}
