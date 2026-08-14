import Foundation

/// Typed failures from the export layer.
public enum ExportError: Error, Equatable, Sendable {
    /// The export destination exists but is a file, not a folder.
    case destinationNotADirectory(path: String)
    /// The destination folder does not exist and could not be created.
    case destinationUnavailable(path: String, reason: String)
    /// The export file could not be written.
    case writeFailed(path: String, reason: String)
    /// A `.docx` part exceeded what a non-zip64 archive can address (4 GB).
    ///
    /// Unreachable for a transcript — an hour of speech is tens of kilobytes —
    /// but the zip writer refuses to emit a header it would have to truncate
    /// rather than produce a silently corrupt file.
    case archiveEntryTooLarge(path: String, bytes: Int)
}

extension ExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .destinationNotADirectory(let path):
            return "\(path) is a file, not a folder to export into."
        case .destinationUnavailable(let path, let reason):
            return "Could not create the export folder at \(path): \(reason)"
        case .writeFailed(let path, let reason):
            return "Could not write the export to \(path): \(reason)"
        case .archiveEntryTooLarge(let path, let bytes):
            return "The transcript part '\(path)' is \(bytes) bytes, too large for a .docx package."
        }
    }
}
