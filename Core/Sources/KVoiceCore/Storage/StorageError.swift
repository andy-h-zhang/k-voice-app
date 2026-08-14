import Foundation

/// Typed failures from the on-disk recording library.
public enum StorageError: Error, Equatable, Sendable {
    /// The library root could not be created.
    case rootCreationFailed(path: String, reason: String)
    /// A path that must be a directory is a file.
    case notADirectory(path: String)
    /// A recording's folder could not be created.
    case folderCreationFailed(path: String, reason: String)
    /// A file expected on disk is missing.
    case fileNotFound(path: String)
    /// A move would have clobbered something already there.
    case destinationExists(path: String)
    /// A rename failed part-way.
    ///
    /// `rolledBack` reports whether the files moved before the failure were
    /// put back. `false` means disk and database may now disagree and the
    /// folder needs manual inspection.
    case renameFailed(from: String, to: String, reason: String, rolledBack: Bool)
    /// The duration of a finished recording could not be read.
    case durationProbeFailed(path: String, reason: String)
}

extension StorageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rootCreationFailed(let path, let reason):
            return "Could not create the recordings folder at \(path): \(reason)"
        case .notADirectory(let path):
            return "\(path) exists but is not a folder."
        case .folderCreationFailed(let path, let reason):
            return "Could not create the recording folder at \(path): \(reason)"
        case .fileNotFound(let path):
            return "No file at \(path)."
        case .destinationExists(let path):
            return "Something already exists at \(path)."
        case .renameFailed(let from, let to, let reason, let rolledBack):
            let recovery = rolledBack
                ? "The original names were restored."
                : "WARNING: the original names could NOT be restored; check the folder on disk."
            return "Could not rename '\(from)' to '\(to)': \(reason) \(recovery)"
        case .durationProbeFailed(let path, let reason):
            return "Could not read the duration of \(path): \(reason)"
        }
    }
}
