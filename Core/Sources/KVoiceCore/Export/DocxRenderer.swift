import Foundation

/// Renders a ``TranscriptDocument`` as a Word `.docx`.
///
/// A `.docx` is an Open Packaging Conventions zip of XML parts, so the export
/// builds the four parts a word-processing document needs plus the
/// relationship part that binds them, and packages them with
/// ``ZipArchiveWriter`` — no third-party dependency, per
/// `docs/implementation-plan.md` §3, decision 8.
///
/// Parts written:
///
/// | Path | Role |
/// |---|---|
/// | `[Content_Types].xml` | declares the content type of every part |
/// | `_rels/.rels` | package → main document |
/// | `word/_rels/document.xml.rels` | document → styles |
/// | `word/document.xml` | the transcript itself |
/// | `word/styles.xml` | document defaults and the speaker-turn style |
///
/// Formatting follows the spec (`docs/spec.md` §Export): speaker names bold,
/// timestamps in subdued gray, transcript text plain. No font or size is
/// specified for body text, so Word and Google Docs each apply their own
/// default — which is what "sensible" means for a document the user will edit
/// anyway.
public enum DocxRenderer {

    // MARK: - Rendering

    /// Renders the document as `.docx` bytes.
    ///
    /// The output is a pure function of its input: entry timestamps come from
    /// the document's own date, so re-exporting an unchanged transcript
    /// produces identical bytes.
    ///
    /// - Throws: ``ExportError/archiveEntryTooLarge(path:bytes:)`` — see
    ///   ``ZipArchiveWriter``.
    public static func render(_ document: TranscriptDocument, timeZone: TimeZone = .current) throws -> Data {
        var writer = ZipArchiveWriter(modificationDate: document.date, timeZone: timeZone)
        for part in parts(for: document, timeZone: timeZone) {
            writer.addFile(path: part.path, text: part.xml)
        }
        return try writer.archive()
    }

    /// One XML part of the package.
    struct Part: Equatable {
        let path: String
        let xml: String
    }

    /// The package's parts, in the order they are written.
    ///
    /// `[Content_Types].xml` goes first because readers look for it at the
    /// front of the archive.
    static func parts(for document: TranscriptDocument, timeZone: TimeZone) -> [Part] {
        [
            Part(path: contentTypesPath, xml: contentTypesXML),
            Part(path: packageRelationshipsPath, xml: packageRelationshipsXML),
            Part(path: documentRelationshipsPath, xml: documentRelationshipsXML),
            Part(path: documentPath, xml: documentXML(document, timeZone: timeZone)),
            Part(path: stylesPath, xml: stylesXML)
        ]
    }

    // MARK: - Part paths

    static let contentTypesPath = "[Content_Types].xml"
    static let packageRelationshipsPath = "_rels/.rels"
    static let documentRelationshipsPath = "word/_rels/document.xml.rels"
    static let documentPath = "word/document.xml"
    static let stylesPath = "word/styles.xml"

    // MARK: - Formatting constants

    /// Gray for timestamps and the header date — readable, clearly secondary.
    static let subduedGray = "808080"
    /// Title size in half-points: 32 → 16 pt.
    static let titleHalfPoints = "32"
    /// Paragraph style applied to speaker-turn headers.
    static let speakerTurnStyleID = "SpeakerTurn"

    private static let xmlDeclaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private static let wordprocessingNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let relationshipsNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"

    // MARK: - Fixed parts

    static let contentTypesXML = """
        \(xmlDeclaration)
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """

    static let packageRelationshipsXML = """
        \(xmlDeclaration)
        <Relationships xmlns="\(relationshipsNamespace)">
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
        Target="word/document.xml"/>
        </Relationships>
        """

    /// Binds `word/document.xml` to `word/styles.xml`.
    ///
    /// Without this part the styles part is unreachable in the package graph
    /// and both Word and Google Docs ignore it, so the "four parts" sketch in
    /// the plan needs this fifth one to actually take effect.
    static let documentRelationshipsXML = """
        \(xmlDeclaration)
        <Relationships xmlns="\(relationshipsNamespace)">
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" \
        Target="styles.xml"/>
        </Relationships>
        """

    /// Document defaults plus the one custom style the transcript uses.
    ///
    /// `SpeakerTurn` keeps a header with the paragraph it introduces
    /// (`w:keepNext`) so a turn never starts at the bottom of a page with its
    /// text on the next one, and adds space above to separate turns.
    static let stylesXML = """
        \(xmlDeclaration)
        <w:styles xmlns:w="\(wordprocessingNamespace)">
        <w:docDefaults>
        <w:rPrDefault><w:rPr/></w:rPrDefault>
        <w:pPrDefault><w:pPr><w:spacing w:after="120"/></w:pPr></w:pPrDefault>
        </w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
        <w:name w:val="Normal"/><w:qFormat/>
        </w:style>
        <w:style w:type="paragraph" w:styleId="\(speakerTurnStyleID)">
        <w:name w:val="Speaker Turn"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
        <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="60"/></w:pPr>
        </w:style>
        </w:styles>
        """

    /// US Letter with one-inch margins — Word's own default page setup.
    private static let sectionProperties = """
        <w:sectPr>\
        <w:pgSz w:w="12240" w:h="15840"/>\
        <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>\
        </w:sectPr>
        """

    // MARK: - The document part

    static func documentXML(_ document: TranscriptDocument, timeZone: TimeZone) -> String {
        var paragraphs: [String] = [
            paragraph(runs: [
                run(document.displayTitle, properties: "<w:b/><w:sz w:val=\"\(titleHalfPoints)\"/><w:szCs w:val=\"\(titleHalfPoints)\"/>")
            ]),
            paragraph(runs: [
                run(TimestampFormatter.documentDate(document.date, timeZone: timeZone), properties: grayProperties)
            ])
        ]

        for turn in document.turns {
            let timestamp = TimestampFormatter.bracketedClockTime(milliseconds: turn.startMs)
            paragraphs.append(
                paragraph(style: speakerTurnStyleID, runs: [
                    run(turn.speaker, properties: "<w:b/>"),
                    run(" — \(timestamp)", properties: grayProperties)
                ])
            )
            for text in turn.paragraphs {
                paragraphs.append(paragraph(runs: [run(text)]))
            }
        }

        return """
            \(xmlDeclaration)
            <w:document xmlns:w="\(wordprocessingNamespace)">
            <w:body>
            \(paragraphs.joined(separator: "\n"))
            \(sectionProperties)
            </w:body>
            </w:document>
            """
    }

    private static let grayProperties = "<w:color w:val=\"\(subduedGray)\"/>"

    // MARK: - Building blocks

    private static func paragraph(style: String? = nil, runs: [String]) -> String {
        let properties = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        return "<w:p>\(properties)\(runs.joined())</w:p>"
    }

    /// One run of text with optional run properties (already-serialized `w:rPr`
    /// children, in schema order).
    private static func run(_ text: String, properties: String = "") -> String {
        let runProperties = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        return "<w:r>\(runProperties)\(runContent(text))</w:r>"
    }

    /// Splits text on line breaks into `w:t` elements joined by `w:br`.
    ///
    /// A newline inside `w:t` is not a line break in WordprocessingML — it is
    /// insignificant whitespace — so an edited utterance containing one would
    /// silently lose its structure. `xml:space="preserve"` keeps the leading
    /// space of the timestamp run and any deliberate spacing in the text.
    private static func runContent(_ text: String) -> String {
        text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { "<w:t xml:space=\"preserve\">\(XMLText.escaped(String($0)))</w:t>" }
            .joined(separator: "<w:br/>")
    }
}
