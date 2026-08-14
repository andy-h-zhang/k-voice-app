import Foundation

/// CRC-32 (IEEE 802.3), the checksum every zip entry header carries.
///
/// Hand-written because the `.docx` export deliberately takes no third-party
/// dependency (`docs/implementation-plan.md` §3, decision 8) and the platform
/// exposes no CRC-32. Table-driven: the 256-entry lookup table is built once
/// on first use, which is both the standard formulation and fast enough that
/// checksumming a transcript is unmeasurable.
///
/// Verified against the canonical vectors — `"123456789"` → `0xCBF43926`.
enum CRC32 {

    /// The reversed (least-significant-bit-first) form of the IEEE polynomial
    /// `0x04C11DB7`, which is the form zip uses.
    static let polynomial: UInt32 = 0xEDB8_8320

    /// Remainders for every possible byte, so the inner loop is one xor and
    /// one table lookup instead of eight bit steps.
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var remainder = UInt32(index)
            for _ in 0..<8 {
                remainder = (remainder & 1) == 1
                    ? (remainder >> 1) ^ polynomial
                    : remainder >> 1
            }
            return remainder
        }
    }()

    /// Checksums any byte sequence — `Data`, `[UInt8]`, a slice.
    ///
    /// Pre-conditioned with all ones and post-inverted, per the standard.
    static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var remainder: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            let index = Int((remainder ^ UInt32(byte)) & 0xFF)
            remainder = (remainder >> 8) ^ table[index]
        }
        return remainder ^ 0xFFFF_FFFF
    }

    /// Checksums a string's UTF-8 bytes.
    static func checksum(_ text: String) -> UInt32 {
        checksum(text.utf8)
    }
}
