import Foundation
import Testing

@testable import KVoiceCore

/// The hand-rolled zip writer.
///
/// A `.docx` is a zip, so a byte wrong here is a document that will not open —
/// and unlike the text exports, the failure is invisible until someone tries.
/// Two independent checks cover that: parsing the archive back the way a real
/// reader navigates it (end-of-central-directory → central directory → local
/// headers), and handing the file to `/usr/bin/unzip -t`.
@Suite("Export zip archive")
struct ExportZipArchiveTests {

    private let stamp = ExportFixture.date(2026, 8, 13, 14, 30, 20)

    private func writer() -> ZipArchiveWriter {
        ZipArchiveWriter(modificationDate: stamp, timeZone: ExportFixture.utc)
    }

    // MARK: - Structure

    @Test("entries survive a write/parse round trip with their contents intact")
    func roundTrip() throws {
        var zip = writer()
        zip.addFile(path: "first.txt", text: "hello")
        zip.addFile(path: "nested/second.xml", text: "<x/>")

        let archive = try ZipReader.read(try zip.archive())

        #expect(archive.entries.map(\.path) == ["first.txt", "nested/second.xml"])
        #expect(archive.text("first.txt") == "hello")
        #expect(archive.text("nested/second.xml") == "<x/>")
    }

    @Test("the end-of-central-directory record counts every entry")
    func endOfCentralDirectoryCounts() throws {
        var zip = writer()
        for index in 1...5 {
            zip.addFile(path: "part\(index).xml", text: "<p>\(index)</p>")
        }

        let archive = try ZipReader.read(try zip.archive())

        #expect(archive.declaredEntryCount == 5)
        #expect(archive.entries.count == 5)
    }

    @Test("entries are stored, not compressed, and flagged UTF-8")
    func storedAndUTF8Flagged() throws {
        var zip = writer()
        zip.addFile(path: "a.txt", text: "payload")

        let entry = try #require(try ZipReader.read(try zip.archive()).entry("a.txt"))

        #expect(entry.method == 0)
        #expect(entry.flags == 0x0800)
        #expect(entry.compressedSize == entry.uncompressedSize)
        #expect(entry.compressedSize == UInt32("payload".utf8.count))
    }

    @Test("each entry's stored CRC is the real CRC-32 of its bytes")
    func checksumsAreReal() throws {
        var zip = writer()
        zip.addFile(path: "a.txt", text: "123456789")
        zip.addFile(path: "b.bin", contents: Data([0x00, 0xFF, 0x10, 0x80]))

        let archive = try ZipReader.read(try zip.archive())

        #expect(try #require(archive.entry("a.txt")).crc == 0xCBF4_3926)
        for entry in archive.entries {
            #expect(entry.crc == CRC32.checksum(entry.contents))
        }
    }

    /// Readers navigate by the central directory but read bytes at the local
    /// header, so the two descriptions of an entry have to agree.
    @Test("local file headers agree with the central directory")
    func headersAgree() throws {
        var zip = writer()
        zip.addFile(path: "[Content_Types].xml", text: "<Types/>")
        zip.addFile(path: "word/document.xml", text: "<w:document/>")

        for entry in try ZipReader.read(try zip.archive()).entries {
            #expect(entry.localCRC == entry.crc)
            #expect(entry.localCompressedSize == entry.compressedSize)
            #expect(entry.localUncompressedSize == entry.uncompressedSize)
            #expect(entry.localMethod == entry.method)
            #expect(entry.localFlags == entry.flags)
        }
    }

    @Test("the first entry starts at offset zero and offsets ascend")
    func offsets() throws {
        var zip = writer()
        zip.addFile(path: "a.txt", text: "aaaa")
        zip.addFile(path: "b.txt", text: "bbbbbbbb")

        let archive = try ZipReader.read(try zip.archive())
        let offsets = archive.entries.map(\.localHeaderOffset)

        #expect(offsets.first == 0)
        #expect(offsets == offsets.sorted())
        // 30-byte header + name + payload for the first entry.
        #expect(offsets[1] == 30 + "a.txt".utf8.count + 4)
        #expect(archive.centralDirectoryOffset == offsets[1] + 30 + "b.txt".utf8.count + 8)
    }

    @Test("an archive with no entries is a bare end-of-central-directory record")
    func emptyArchive() throws {
        let data = try writer().archive()
        let archive = try ZipReader.read(data)

        #expect(data.count == 22)
        #expect(archive.entries.isEmpty)
        #expect(archive.declaredEntryCount == 0)
        #expect(archive.centralDirectorySize == 0)
    }

    @Test("binary payloads round-trip byte for byte")
    func binaryPayload() throws {
        let payload = Data((0...255).map { UInt8($0) })
        var zip = writer()
        zip.addFile(path: "bytes.bin", contents: payload)

        let entry = try #require(try ZipReader.read(try zip.archive()).entry("bytes.bin"))

        #expect(entry.contents == payload)
    }

    @Test("non-ASCII entry names survive, which is what the UTF-8 flag promises")
    func unicodeNames() throws {
        var zip = writer()
        zip.addFile(path: "word/会議.xml", text: "<x/>")

        let archive = try ZipReader.read(try zip.archive())

        #expect(archive.entries.first?.path == "word/会議.xml")
    }

    @Test("the same input always produces the same bytes")
    func deterministic() throws {
        var first = writer()
        first.addFile(path: "a.txt", text: "payload")
        var second = writer()
        second.addFile(path: "a.txt", text: "payload")

        #expect(try first.archive() == (try second.archive()))
    }

    // MARK: - DOS timestamps

    @Test("dates pack into the DOS date/time fields")
    func dosTimestamp() {
        let stamp = ZipArchiveWriter.dosTimestamp(
            from: ExportFixture.date(2026, 8, 13, 14, 30, 20),
            timeZone: ExportFixture.utc
        )

        #expect(stamp.date == UInt16(((2026 - 1980) << 9) | (8 << 5) | 13))
        #expect(stamp.time == UInt16((14 << 11) | (30 << 5) | 10))  // seconds in 2-second units
    }

    @Test("seconds are stored in two-second units, so odd seconds round down")
    func dosSecondsResolution() {
        let odd = ZipArchiveWriter.dosTimestamp(
            from: ExportFixture.date(2026, 8, 13, 0, 0, 59),
            timeZone: ExportFixture.utc
        )

        #expect(odd.time == UInt16(29))
    }

    /// DOS dates begin in 1980; a pre-1980 date must clamp rather than wrap
    /// into a header readers reject.
    @Test("dates before 1980 clamp instead of wrapping")
    func dosEpochClamp() {
        let stamp = ZipArchiveWriter.dosTimestamp(
            from: ExportFixture.date(1970, 1, 1),
            timeZone: ExportFixture.utc
        )

        #expect(stamp.date == UInt16((0 << 9) | (1 << 5) | 1))
    }

    @Test("dates past 2107 clamp to the last representable year")
    func dosFarFutureClamp() {
        let stamp = ZipArchiveWriter.dosTimestamp(
            from: ExportFixture.date(2200, 6, 15),
            timeZone: ExportFixture.utc
        )

        #expect((stamp.date >> 9) == UInt16(2107 - 1980))
    }

    // MARK: - Third-party verification

    /// The point of the round-trip tests above is that they are ours; this one
    /// is that it is not.
    @Test("/usr/bin/unzip accepts the archive and its checksums")
    func unzipAcceptsTheArchive() throws {
        var zip = writer()
        zip.addFile(path: "[Content_Types].xml", text: "<Types/>")
        zip.addFile(path: "word/document.xml", text: "<w:document/>")
        zip.addFile(path: "word/binary.bin", contents: Data((0...255).map { UInt8($0) }))

        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let url = directory.file("archive.zip")
        try zip.archive().write(to: url)

        guard let test = try ExportTool.run("/usr/bin/unzip", ["-t", url.path]) else { return }
        #expect(test.succeeded, "unzip -t rejected the archive: \(test.output)")
        #expect(test.output.contains("No errors detected"))

        guard let list = try ExportTool.run("/usr/bin/unzip", ["-l", url.path]) else { return }
        #expect(list.output.contains("word/document.xml"))
    }

    @Test("unzip extracts the original bytes back out")
    func unzipExtractsContents() throws {
        var zip = writer()
        zip.addFile(path: "word/document.xml", text: "<w:document>café</w:document>")

        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let url = directory.file("archive.zip")
        try zip.archive().write(to: url)

        guard let extracted = try ExportTool.run("/usr/bin/unzip", ["-p", url.path, "word/document.xml"]) else {
            return
        }
        #expect(extracted.output == "<w:document>café</w:document>")
    }
}
