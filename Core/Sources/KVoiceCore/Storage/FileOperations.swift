import Foundation

/// The filesystem operations ``RecordingStore`` performs.
///
/// Injected rather than called directly so tests can fail a specific step of
/// a multi-step rename and assert that the rollback actually restores the
/// earlier moves — the one path that is impossible to provoke reliably
/// against a real filesystem.
public protocol FileOperations: Sendable {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    /// Directory contents, excluding hidden files (`.DS_Store` and friends
    /// are never part of a recording).
    func contentsOfDirectory(at url: URL) throws -> [URL]
}

/// `FileOperations` backed by `FileManager`.
public struct SystemFileOperations: FileOperations {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }
}
