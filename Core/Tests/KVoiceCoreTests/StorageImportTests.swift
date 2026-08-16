import Foundation
import Testing

@testable import KVoiceCore

/// Importing an existing audio file must produce a recording indistinguishable
/// from a captured one — same folder shape, same shared base name — so that
/// rename, export, reveal and trash need no special case for it.
@Suite("Storage: importing existing audio")
struct StorageImportTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSourceFile(named name: String, bytes: [UInt8] = [1, 2, 3, 4]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    @Test("copies the file into its own folder under the shared base name")
    func importsIntoOwnFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceFile(named: "Team Sync.m4a")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let store = RecordingStore(rootURL: root)
        let folder = try store.importRecording(from: source, title: "Team Sync")

        #expect(folder.baseName == "Team Sync")
        #expect(folder.folderURL == root.appendingPathComponent("Team Sync", isDirectory: true))
        #expect(folder.audioURL == folder.folderURL.appendingPathComponent("Team Sync Recording.m4a"))
        #expect(FileManager.default.fileExists(atPath: folder.audioURL.path))
    }

    /// Transcoding a `.wav` to the recorder's AAC would lose quality for
    /// nothing — everything downstream reads whatever AVFoundation opens.
    @Test("keeps the source format rather than forcing m4a")
    func keepsSourceExtension() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecordingStore(rootURL: root)

        for ext in ["wav", "mp3", "aiff", "caf"] {
            let source = try makeSourceFile(named: "Clip.\(ext)")
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

            let folder = try store.importRecording(from: source, title: "Clip \(ext)")
            #expect(folder.audioFileExtension == ext)
            #expect(folder.audioURL.pathExtension == ext)
            #expect(FileManager.default.fileExists(atPath: folder.audioURL.path))
        }
    }

    @Test("an uppercase extension is normalized")
    func normalizesExtensionCase() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceFile(named: "Loud.WAV")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let folder = try RecordingStore(rootURL: root).importRecording(from: source, title: "Loud")
        #expect(folder.audioFileExtension == "wav")
    }

    /// The source is a file the user picked from elsewhere on their disk. A
    /// picker that silently removed it from their Downloads folder would be a
    /// nasty surprise.
    @Test("copies rather than moves — the original survives")
    func leavesSourceInPlace() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceFile(named: "Keep Me.m4a", bytes: [9, 9, 9])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let folder = try RecordingStore(rootURL: root).importRecording(from: source, title: "Keep Me")

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: source) == Data([9, 9, 9]))
        #expect(try Data(contentsOf: folder.audioURL) == Data([9, 9, 9]))
    }

    @Test("two imports of the same name get collision-suffixed folders")
    func suffixesCollisions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceFile(named: "Standup.m4a")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let store = RecordingStore(rootURL: root)
        let first = try store.importRecording(from: source, title: "Standup")
        let second = try store.importRecording(from: source, title: "Standup")

        #expect(first.baseName == "Standup")
        #expect(second.baseName != first.baseName)
        #expect(FileManager.default.fileExists(atPath: first.audioURL.path))
        #expect(FileManager.default.fileExists(atPath: second.audioURL.path))
    }

    @Test("a missing source is reported and leaves nothing behind")
    func missingSource() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = root.appendingPathComponent("nope.m4a")

        #expect(throws: StorageError.self) {
            _ = try RecordingStore(rootURL: root).importRecording(from: absent, title: "Nope")
        }
        // No half-made folder in the library.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(leftovers.filter { !$0.hasPrefix(".") }.isEmpty)
    }

    /// A failed copy must not leave an empty folder that reads as a recording
    /// with no audio.
    @Test("a failed copy cleans up the folder it made")
    func failedCopyCleansUp() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceFile(named: "Doomed.m4a")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let store = RecordingStore(rootURL: root, operations: CopyFailingOperations())

        #expect(throws: StorageError.self) {
            _ = try store.importRecording(from: source, title: "Doomed")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(leftovers.filter { !$0.hasPrefix(".") }.isEmpty)
    }
}

/// Real filesystem for everything except the copy, which always fails.
private struct CopyFailingOperations: FileOperations {
    struct InjectedFailure: Error {}

    private let system = SystemFileOperations()

    func fileExists(at url: URL) -> Bool { system.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { system.isDirectory(at: url) }
    func createDirectory(at url: URL) throws { try system.createDirectory(at: url) }
    func moveItem(at source: URL, to destination: URL) throws { try system.moveItem(at: source, to: destination) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try system.contentsOfDirectory(at: url) }
    func copyItem(at source: URL, to destination: URL) throws { throw InjectedFailure() }
}
