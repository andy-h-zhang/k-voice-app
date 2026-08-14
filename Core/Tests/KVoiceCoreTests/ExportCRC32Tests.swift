import Foundation
import Testing

@testable import KVoiceCore

/// CRC-32, checked against the canonical vectors.
///
/// Every zip entry header carries this checksum, and a wrong one is not a
/// cosmetic problem: `unzip -t`, Word and Google Docs all reject the archive.
/// Since the implementation is hand-rolled, the published vectors are the only
/// honest way to know it is right.
@Suite("Export CRC-32")
struct ExportCRC32Tests {

    /// The check value every CRC-32 specification quotes.
    @Test("\"123456789\" checksums to the standard check value 0xCBF43926")
    func standardCheckValue() {
        #expect(CRC32.checksum("123456789") == 0xCBF4_3926)
    }

    @Test("published vectors match")
    func publishedVectors() {
        #expect(CRC32.checksum("") == 0x0000_0000)
        #expect(CRC32.checksum("a") == 0xE8B7_BE43)
        #expect(CRC32.checksum("abc") == 0x3524_41C2)
        #expect(CRC32.checksum("The quick brown fox jumps over the lazy dog") == 0x414F_A339)
    }

    @Test("the polynomial is the reversed IEEE one that zip uses")
    func polynomial() {
        #expect(CRC32.polynomial == 0xEDB8_8320)
    }

    @Test("bytes and their string form checksum identically")
    func bytesMatchStrings() {
        let text = "Weekly sync — 会議"

        #expect(CRC32.checksum(Data(text.utf8)) == CRC32.checksum(text))
        #expect(CRC32.checksum([UInt8](text.utf8)) == CRC32.checksum(text))
    }

    @Test("non-UTF-8 byte content checksums without special-casing")
    func binaryInput() {
        // 0x00 and 0xFF exercise the table's first and last rows.
        #expect(CRC32.checksum([0x00] as [UInt8]) == 0xD202_EF8D)
        #expect(CRC32.checksum([0xFF] as [UInt8]) == 0xFF00_0000)
    }

    @Test("a single flipped bit changes the checksum")
    func sensitiveToChange() {
        #expect(CRC32.checksum("Weekly sync") != CRC32.checksum("Weekly sinc"))
        #expect(CRC32.checksum("ab") != CRC32.checksum("ba"))
    }

    @Test("checksumming is deterministic across calls")
    func deterministic() {
        let payload = String(repeating: "transcript ", count: 500)

        #expect(CRC32.checksum(payload) == CRC32.checksum(payload))
    }
}
