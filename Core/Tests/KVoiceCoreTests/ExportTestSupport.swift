import Foundation

@testable import KVoiceCore

// MARK: - Document fixtures

enum ExportFixture {

    /// Exports are rendered in a fixed zone so golden files do not change with
    /// the machine's region settings.
    static let utc = TimeZone(secondsFromGMT: 0)!

    /// Builds a date from wall-clock parts in `timeZone`.
    static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        _ second: Int = 0,
        timeZone: TimeZone = utc
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        )
        return calendar.date(from: components)!
    }

    /// A two-speaker meeting that alternates and comes back to the first
    /// speaker, with a turn past the one-hour mark and an apostrophe in the
    /// text — enough to exercise grouping, hour-wide timestamps and escaping.
    static var meeting: TranscriptDocument {
        TranscriptDocument(
            title: "Weekly sync",
            date: date(2026, 8, 13, 14, 30),
            utterances: [
                .init(speaker: "Alice", startMs: 5_000, text: "Morning, everyone."),
                .init(speaker: "Alice", startMs: 9_400, text: "Let's start with the roadmap."),
                .init(speaker: "Bob", startMs: 72_000, text: "Morning."),
                .init(speaker: "Alice", startMs: 3_723_000, text: "Wrapping up.")
            ]
        )
    }

    static func utterance(_ speaker: String, _ startMs: Int, _ text: String) -> TranscriptDocument.Utterance {
        TranscriptDocument.Utterance(speaker: speaker, startMs: startMs, text: text)
    }

    /// A single-turn document, for tests that care about one specific string.
    static func document(
        title: String = "Test",
        text: String,
        speaker: String = "Alice"
    ) -> TranscriptDocument {
        TranscriptDocument(
            title: title,
            date: date(2026, 8, 13, 14, 30),
            utterances: [utterance(speaker, 0, text)]
        )
    }
}

// MARK: - Zip reading

/// A zip parser used only to read back what ``ZipArchiveWriter`` produced.
///
/// Deliberately strict and independent of the writer: it walks the end-of-
/// central-directory record to the central directory, follows each entry's
/// offset to its local header, and cross-checks the two. That is how a real
/// reader (Word, Google Docs, `unzip`) navigates an archive, so a round trip
/// through this parser catches exactly the mistakes that would make the
/// `.docx` unopenable.
enum ZipReader {

    struct Entry {
        let path: String
        let contents: Data
        /// From the central directory.
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let method: UInt16
        let flags: UInt16
        let localHeaderOffset: Int
        /// From the local file header, so tests can assert the two agree.
        let localCRC: UInt32
        let localCompressedSize: UInt32
        let localUncompressedSize: UInt32
        let localMethod: UInt16
        let localFlags: UInt16
    }

    struct Archive {
        let entries: [Entry]
        /// Entry count as recorded in the end-of-central-directory record.
        let declaredEntryCount: Int
        let centralDirectorySize: Int
        let centralDirectoryOffset: Int
    }

    enum ReadError: Error, Equatable {
        case truncated(offset: Int)
        case badSignature(part: String, offset: Int)
        case archiveCommentPresent
        case nameMismatch(central: String, local: String)
        case centralDirectorySizeMismatch(declared: Int, walked: Int)
    }

    static let localHeaderSignature: UInt32 = 0x0403_4B50
    static let centralHeaderSignature: UInt32 = 0x0201_4B50
    static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50

    static func read(_ data: Data) throws -> Archive {
        let bytes = [UInt8](data)

        // No archive comment is written, so the record is the last 22 bytes.
        let end = bytes.count - 22
        guard end >= 0 else { throw ReadError.truncated(offset: 0) }
        guard try u32(bytes, end) == endOfCentralDirectorySignature else {
            throw ReadError.badSignature(part: "end of central directory", offset: end)
        }
        guard try u16(bytes, end + 20) == 0 else { throw ReadError.archiveCommentPresent }

        let declaredEntryCount = Int(try u16(bytes, end + 10))
        let centralDirectorySize = Int(try u32(bytes, end + 12))
        let centralDirectoryOffset = Int(try u32(bytes, end + 16))

        var cursor = centralDirectoryOffset
        var entries: [Entry] = []

        for _ in 0..<declaredEntryCount {
            guard try u32(bytes, cursor) == centralHeaderSignature else {
                throw ReadError.badSignature(part: "central directory header", offset: cursor)
            }

            let flags = try u16(bytes, cursor + 8)
            let method = try u16(bytes, cursor + 10)
            let crc = try u32(bytes, cursor + 16)
            let compressedSize = try u32(bytes, cursor + 20)
            let uncompressedSize = try u32(bytes, cursor + 24)
            let nameLength = Int(try u16(bytes, cursor + 28))
            let extraLength = Int(try u16(bytes, cursor + 30))
            let commentLength = Int(try u16(bytes, cursor + 32))
            let localHeaderOffset = Int(try u32(bytes, cursor + 42))
            let path = try string(bytes, cursor + 46, length: nameLength)
            cursor += 46 + nameLength + extraLength + commentLength

            // Follow the offset to the local header and cross-check it.
            guard try u32(bytes, localHeaderOffset) == localHeaderSignature else {
                throw ReadError.badSignature(part: "local file header", offset: localHeaderOffset)
            }
            let localFlags = try u16(bytes, localHeaderOffset + 6)
            let localMethod = try u16(bytes, localHeaderOffset + 8)
            let localCRC = try u32(bytes, localHeaderOffset + 14)
            let localCompressedSize = try u32(bytes, localHeaderOffset + 18)
            let localUncompressedSize = try u32(bytes, localHeaderOffset + 22)
            let localNameLength = Int(try u16(bytes, localHeaderOffset + 26))
            let localExtraLength = Int(try u16(bytes, localHeaderOffset + 28))
            let localPath = try string(bytes, localHeaderOffset + 30, length: localNameLength)
            guard localPath == path else {
                throw ReadError.nameMismatch(central: path, local: localPath)
            }

            let start = localHeaderOffset + 30 + localNameLength + localExtraLength
            let contents = try slice(bytes, start, length: Int(compressedSize))

            entries.append(
                Entry(
                    path: path,
                    contents: contents,
                    crc: crc,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    method: method,
                    flags: flags,
                    localHeaderOffset: localHeaderOffset,
                    localCRC: localCRC,
                    localCompressedSize: localCompressedSize,
                    localUncompressedSize: localUncompressedSize,
                    localMethod: localMethod,
                    localFlags: localFlags
                )
            )
        }

        let walked = cursor - centralDirectoryOffset
        guard walked == centralDirectorySize else {
            throw ReadError.centralDirectorySizeMismatch(declared: centralDirectorySize, walked: walked)
        }

        return Archive(
            entries: entries,
            declaredEntryCount: declaredEntryCount,
            centralDirectorySize: centralDirectorySize,
            centralDirectoryOffset: centralDirectoryOffset
        )
    }

    // MARK: Little-endian readers

    private static func u16(_ bytes: [UInt8], _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { throw ReadError.truncated(offset: offset) }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw ReadError.truncated(offset: offset) }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func slice(_ bytes: [UInt8], _ offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset + length <= bytes.count else {
            throw ReadError.truncated(offset: offset)
        }
        return Data(bytes[offset..<(offset + length)])
    }

    private static func string(_ bytes: [UInt8], _ offset: Int, length: Int) throws -> String {
        String(decoding: try slice(bytes, offset, length: length), as: UTF8.self)
    }
}

extension ZipReader.Archive {
    func entry(_ path: String) -> ZipReader.Entry? {
        entries.first { $0.path == path }
    }

    /// UTF-8 contents of a part, for the XML checks.
    func text(_ path: String) -> String? {
        entry(path).map { String(decoding: $0.contents, as: UTF8.self) }
    }
}

// MARK: - XML checking

/// Collects the text of every `<w:t>` element, so a test can assert that what
/// a *parser* reads back matches what went in — the real test of escaping,
/// since it exercises entity decoding rather than string matching.
final class WordTextCollector: NSObject, XMLParserDelegate {
    private(set) var texts: [String] = []
    private var current: String?

    /// Parses `xml`, returning the `w:t` contents, or `nil` if it is not
    /// well-formed.
    static func parse(_ xml: String) -> [String]? {
        let parser = XMLParser(data: Data(xml.utf8))
        let collector = WordTextCollector()
        parser.delegate = collector
        guard parser.parse() else { return nil }
        return collector.texts
    }

    /// Whether `xml` is well-formed.
    static func isWellFormed(_ xml: String) -> Bool {
        parse(xml) != nil
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        if elementName == "w:t" { current = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { current? += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if elementName == "w:t", let text = current {
            texts.append(text)
            current = nil
        }
    }
}

// MARK: - Command-line tools

/// Runs a system tool and captures its output.
///
/// Only used to prove that software *other than this package* accepts the
/// generated `.docx` — `unzip` for the archive structure, `textutil` for the
/// OOXML. Production code never shells out.
enum ExportTool {

    struct Result {
        let status: Int32
        let output: String
        var succeeded: Bool { status == 0 }
    }

    /// - Returns: `nil` if the tool is not installed on this machine, so the
    ///   test degrades to a skip rather than a false failure.
    static func run(_ launchPath: String, _ arguments: [String]) throws -> Result? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
