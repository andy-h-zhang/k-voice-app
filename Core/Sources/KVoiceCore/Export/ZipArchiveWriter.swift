import Foundation

/// A minimal zip writer: stored (uncompressed) entries, no zip64, no
/// encryption, no data descriptors.
///
/// A `.docx` is a zip of XML parts, and stored entries are perfectly valid
/// zip — Word and Google Docs both accept them — so the export needs neither a
/// compression library nor a zip dependency (`docs/implementation-plan.md` §3,
/// decision 8). Transcripts are tens of kilobytes; compressing them would save
/// nothing a user would notice and cost a dependency the spec explicitly does
/// not want.
///
/// Layout written, in order:
///
/// ```text
/// [local file header + name + data] × n
/// [central directory header + name] × n
/// [end of central directory record]
/// ```
///
/// Every entry stores its CRC-32 and its size twice (compressed ==
/// uncompressed, since nothing is compressed), and flags bit 11 so filenames
/// are read as UTF-8 rather than the legacy code page.
struct ZipArchiveWriter {

    private struct Entry {
        let path: String
        let data: Data
    }

    private var entries: [Entry] = []
    private let dosDate: UInt16
    private let dosTime: UInt16

    /// - Parameters:
    ///   - modificationDate: Timestamp recorded on every entry. Callers pass
    ///     the document's own date, which makes the archive a pure function of
    ///     its input — the same document exports to the same bytes.
    ///   - timeZone: Zone the DOS timestamp's wall clock is written in.
    init(modificationDate: Date, timeZone: TimeZone = .current) {
        let stamp = Self.dosTimestamp(from: modificationDate, timeZone: timeZone)
        self.dosDate = stamp.date
        self.dosTime = stamp.time
    }

    /// Adds a stored file at `path` (a forward-slash-separated archive path).
    mutating func addFile(path: String, contents: Data) {
        entries.append(Entry(path: path, data: contents))
    }

    /// Adds a stored file whose contents are UTF-8 text — the XML parts.
    mutating func addFile(path: String, text: String) {
        addFile(path: path, contents: Data(text.utf8))
    }

    /// Serializes the archive.
    ///
    /// - Throws: ``ExportError/archiveEntryTooLarge(path:bytes:)`` if an entry
    ///   or the archive would exceed the 4 GB a non-zip64 header can address.
    func archive() throws -> Data {
        var output = Data()
        var centralDirectory = Data()

        for entry in entries {
            let name = Array(entry.path.utf8)
            let checksum = CRC32.checksum(entry.data)

            guard
                entry.data.count <= UInt32.max,
                name.count <= UInt16.max,
                output.count <= UInt32.max
            else {
                throw ExportError.archiveEntryTooLarge(path: entry.path, bytes: entry.data.count)
            }

            let size = UInt32(entry.data.count)
            let localHeaderOffset = UInt32(output.count)

            // Local file header, immediately followed by the name and the
            // (stored) bytes.
            output.appendUInt32LE(Self.localHeaderSignature)
            output.appendUInt16LE(Self.versionNeeded)
            output.appendUInt16LE(Self.generalPurposeFlags)
            output.appendUInt16LE(Self.methodStored)
            output.appendUInt16LE(dosTime)
            output.appendUInt16LE(dosDate)
            output.appendUInt32LE(checksum)
            output.appendUInt32LE(size)  // compressed size
            output.appendUInt32LE(size)  // uncompressed size
            output.appendUInt16LE(UInt16(name.count))
            output.appendUInt16LE(0)  // extra field length
            output.append(contentsOf: name)
            output.append(entry.data)

            // Central directory header — the index readers actually trust.
            centralDirectory.appendUInt32LE(Self.centralHeaderSignature)
            centralDirectory.appendUInt16LE(Self.versionMadeBy)
            centralDirectory.appendUInt16LE(Self.versionNeeded)
            centralDirectory.appendUInt16LE(Self.generalPurposeFlags)
            centralDirectory.appendUInt16LE(Self.methodStored)
            centralDirectory.appendUInt16LE(dosTime)
            centralDirectory.appendUInt16LE(dosDate)
            centralDirectory.appendUInt32LE(checksum)
            centralDirectory.appendUInt32LE(size)
            centralDirectory.appendUInt32LE(size)
            centralDirectory.appendUInt16LE(UInt16(name.count))
            centralDirectory.appendUInt16LE(0)  // extra field length
            centralDirectory.appendUInt16LE(0)  // file comment length
            centralDirectory.appendUInt16LE(0)  // disk number start
            centralDirectory.appendUInt16LE(0)  // internal file attributes
            centralDirectory.appendUInt32LE(0)  // external file attributes
            centralDirectory.appendUInt32LE(localHeaderOffset)
            centralDirectory.append(contentsOf: name)
        }

        guard
            output.count <= UInt32.max,
            centralDirectory.count <= UInt32.max,
            entries.count <= UInt16.max
        else {
            throw ExportError.archiveEntryTooLarge(path: "(archive)", bytes: output.count)
        }

        let centralDirectoryOffset = UInt32(output.count)
        output.append(centralDirectory)

        // End of central directory. Single-disk archive, no comment.
        output.appendUInt32LE(Self.endOfCentralDirectorySignature)
        output.appendUInt16LE(0)  // this disk's number
        output.appendUInt16LE(0)  // disk holding the central directory
        output.appendUInt16LE(UInt16(entries.count))  // entries on this disk
        output.appendUInt16LE(UInt16(entries.count))  // entries in total
        output.appendUInt32LE(UInt32(centralDirectory.count))
        output.appendUInt32LE(centralDirectoryOffset)
        output.appendUInt16LE(0)  // archive comment length

        return output
    }

    // MARK: - Format constants

    static let localHeaderSignature: UInt32 = 0x0403_4B50
    static let centralHeaderSignature: UInt32 = 0x0201_4B50
    static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50

    /// Zip 2.0 — the floor for stored and deflated entries.
    static let versionNeeded: UInt16 = 20
    /// Upper byte 0 (MS-DOS/FAT, so external attributes stay 0), lower byte 20.
    static let versionMadeBy: UInt16 = 20
    /// Bit 11: filenames and comments are UTF-8.
    static let generalPurposeFlags: UInt16 = 0x0800
    /// Compression method 0 — stored.
    static let methodStored: UInt16 = 0

    // MARK: - DOS timestamps

    /// Converts a `Date` to the packed MS-DOS date/time a zip header stores.
    ///
    /// DOS dates start in 1980 and run out in 2107, and store seconds in two-
    /// second units. Dates outside the range clamp instead of wrapping, so a
    /// nonsense timestamp can never produce a header that readers reject.
    static func dosTimestamp(from date: Date, timeZone: TimeZone) -> (date: UInt16, time: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )

        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let month = min(max(parts.month ?? 1, 1), 12)
        let day = min(max(parts.day ?? 1, 1), 31)
        let hour = min(max(parts.hour ?? 0, 0), 23)
        let minute = min(max(parts.minute ?? 0, 0), 59)
        // Leap seconds (60) fold into 30, the largest value the field holds.
        let second = min(max(parts.second ?? 0, 0), 59) / 2

        let packedDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        let packedTime = UInt16((hour << 11) | (minute << 5) | second)
        return (packedDate, packedTime)
    }
}

// MARK: - Little-endian serialization

/// Zip stores every numeric field little-endian regardless of host byte order.
private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
