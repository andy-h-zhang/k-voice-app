import Foundation
import Testing

@testable import KVoiceCore

/// `RecordingStore.moveRoot(to:)` — the Phase-6 "Storage folder" setting.
///
/// This is the one Phase-6 operation that can lose a user's recordings, so its
/// guards are tested before its happy path.
@Suite("Library folder move")
struct StorageLibraryMoveTests {

    // MARK: - Moving

    @Test("every recording folder and the store file move together")
    func movesEverything() throws {
        try withTempDirectory { parent in
            let source = parent.appendingPathComponent("Old", isDirectory: true)
            let store = RecordingStore(rootURL: source)
            try store.createRootIfNeeded()

            let standup = try store.createRecording(title: "Standup")
            try Data("audio".utf8).write(to: standup.audioURL)
            try Data("raw".utf8).write(to: standup.folderURL.appendingPathComponent("transcript.raw.json"))
            _ = try store.createRecording(title: "Retro")

            // The SwiftData store lives in the library root (KVoiceSchema
            // .onDisk(inLibraryRoot:)), so it has to travel with it — including
            // SQLite's sidecar files.
            for name in ["KVoice.store", "KVoice.store-wal", "KVoice.store-shm"] {
                try Data("db".utf8).write(to: source.appendingPathComponent(name))
            }

            let destination = parent.appendingPathComponent("New", isDirectory: true)
            let moved = try store.moveRoot(to: destination)

            #expect(moved.rootURL.standardizedFileURL == destination.standardizedFileURL)
            #expect(names(in: destination) == [
                "KVoice.store", "KVoice.store-shm", "KVoice.store-wal", "Retro", "Standup"
            ])
            #expect(names(in: source).isEmpty)

            let movedAudio = destination
                .appendingPathComponent("Standup", isDirectory: true)
                .appendingPathComponent("Standup.m4a")
            #expect(try Data(contentsOf: movedAudio) == Data("audio".utf8))
            #expect(exists(destination.appendingPathComponent("Standup/transcript.raw.json")))

            // The returned store works at the new location.
            #expect(try moved.recordings().map(\.baseName) == ["Standup"])
        }
    }

    @Test("the old folder is left behind, empty, for the user to remove")
    func leavesOldFolder() throws {
        try withTempDirectory { parent in
            let source = parent.appendingPathComponent("Old", isDirectory: true)
            let store = RecordingStore(rootURL: source)
            try store.createRootIfNeeded()
            _ = try store.createRecording(title: "Standup")

            _ = try store.moveRoot(to: parent.appendingPathComponent("New", isDirectory: true))

            #expect(isDirectory(source))
            #expect(names(in: source).isEmpty)
        }
    }

    @Test("a destination that does not exist yet is created")
    func createsDestination() throws {
        try withTempDirectory { parent in
            let source = parent.appendingPathComponent("Old", isDirectory: true)
            let store = RecordingStore(rootURL: source)
            try store.createRootIfNeeded()
            _ = try store.createRecording(title: "Standup")

            let destination = parent.appendingPathComponent("Nested/Deeper/New", isDirectory: true)
            let moved = try store.moveRoot(to: destination)

            #expect(isDirectory(destination))
            #expect(names(in: moved.rootURL) == ["Standup"])
        }
    }

    @Test("an empty destination — the folder an open panel just created — is accepted")
    func acceptsEmptyDestination() throws {
        try withTempDirectory { parent in
            let source = parent.appendingPathComponent("Old", isDirectory: true)
            let store = RecordingStore(rootURL: source)
            try store.createRootIfNeeded()
            _ = try store.createRecording(title: "Standup")

            let destination = parent.appendingPathComponent("New", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            #expect(try names(in: store.moveRoot(to: destination).rootURL) == ["Standup"])
        }
    }

    @Test("a library that was never written to is just a settings change")
    func movesAbsentRoot() throws {
        try withTempDirectory { parent in
            let source = parent.appendingPathComponent("NeverUsed", isDirectory: true)
            let store = RecordingStore(rootURL: source)

            let destination = parent.appendingPathComponent("New", isDirectory: true)
            let moved = try store.moveRoot(to: destination)

            #expect(moved.rootURL.standardizedFileURL == destination.standardizedFileURL)
            #expect(isDirectory(destination))
            #expect(!exists(source))
        }
    }

    @Test("moving to where it already is does nothing")
    func noOp() throws {
        try withTempDirectory { parent in
            let source = parent.appendingPathComponent("Library", isDirectory: true)
            let store = RecordingStore(rootURL: source)
            try store.createRootIfNeeded()
            _ = try store.createRecording(title: "Standup")

            let moved = try store.moveRoot(to: source)
            #expect(moved.rootURL == store.rootURL)
            #expect(names(in: source) == ["Standup"])

            // Including a differently-spelled path for the same folder.
            let indirect = parent
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("..", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
            #expect(try store.moveRoot(to: indirect).rootURL == store.rootURL)
            #expect(names(in: source) == ["Standup"])
        }
    }

    // MARK: - Guards

    @Test("a destination with files in it is refused, and nothing moves")
    func refusesNonEmptyDestination() throws {
        try withTempDirectory { parent in
            let source = parent.appendingPathComponent("Old", isDirectory: true)
            let store = RecordingStore(rootURL: source)
            try store.createRootIfNeeded()
            _ = try store.createRecording(title: "Standup")

            let destination = parent.appendingPathComponent("New", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("someone else's".utf8).write(to: destination.appendingPathComponent("notes.txt"))

            #expect(throws: StorageError.destinationNotEmpty(path: destination.path)) {
                _ = try store.moveRoot(to: destination)
            }
            #expect(names(in: source) == ["Standup"])
            #expect(names(in: destination) == ["notes.txt"])
        }
    }

    @Test("a destination inside the library itself is refused")
    func refusesDestinationInsideSource() throws {
        try withTempDirectory { parent in
            let source = parent.appendingPathComponent("Library", isDirectory: true)
            let store = RecordingStore(rootURL: source)
            try store.createRootIfNeeded()
            _ = try store.createRecording(title: "Standup")

            let inside = source.appendingPathComponent("Inside", isDirectory: true)
            #expect(
                throws: StorageError.destinationInsideSource(
                    source: source.standardizedFileURL.path,
                    destination: inside.standardizedFileURL.path
                )
            ) {
                _ = try store.moveRoot(to: inside)
            }
            #expect(names(in: source) == ["Standup"])
        }
    }

    @Test("a destination that is a file, not a folder, is refused")
    func refusesFileDestination() throws {
        try withTempDirectory { parent in
            let source = parent.appendingPathComponent("Old", isDirectory: true)
            let store = RecordingStore(rootURL: source)
            try store.createRootIfNeeded()

            let destination = parent.appendingPathComponent("New")
            try Data("not a folder".utf8).write(to: destination)

            #expect(throws: StorageError.notADirectory(path: destination.path)) {
                _ = try store.moveRoot(to: destination)
            }
        }
    }

    // MARK: - Failure part-way

    @Test("a failure part-way puts everything back")
    func rollsBack() throws {
        try withTempDirectory { parent in
            let source = parent.appendingPathComponent("Old", isDirectory: true)
            // Fail the third move: two recording folders have already moved.
            let operations = MoveFailingOperations(failingMoveIndices: [3])
            let store = RecordingStore(rootURL: source, operations: operations)
            try store.createRootIfNeeded()

            for title in ["Alpha", "Bravo", "Charlie", "Delta"] {
                let folder = try store.createRecording(title: title)
                try Data(title.utf8).write(to: folder.audioURL)
            }

            let destination = parent.appendingPathComponent("New", isDirectory: true)

            var thrown: StorageError?
            do {
                _ = try store.moveRoot(to: destination)
            } catch let error as StorageError {
                thrown = error
            }

            guard case .rootMoveFailed(_, _, _, let rolledBack) = try #require(thrown) else {
                Issue.record("expected a rootMoveFailed error")
                return
            }
            #expect(rolledBack)

            // Every recording is back where it started, contents intact.
            #expect(names(in: source) == ["Alpha", "Bravo", "Charlie", "Delta"])
            #expect(names(in: destination).isEmpty)
            let audio = source.appendingPathComponent("Bravo/Bravo.m4a")
            #expect(try Data(contentsOf: audio) == Data("Bravo".utf8))
        }
    }

    @Test("a rollback that itself fails says so, rather than reporting success")
    func reportsFailedRollback() throws {
        try withTempDirectory { parent in
            let source = parent.appendingPathComponent("Old", isDirectory: true)
            // Move 3 fails; moves 4 and 5 are the two rollback attempts.
            let operations = MoveFailingOperations(failingMoveIndices: [3, 4, 5])
            let store = RecordingStore(rootURL: source, operations: operations)
            try store.createRootIfNeeded()

            for title in ["Alpha", "Bravo", "Charlie"] {
                _ = try store.createRecording(title: title)
            }

            var thrown: StorageError?
            do {
                _ = try store.moveRoot(to: parent.appendingPathComponent("New", isDirectory: true))
            } catch let error as StorageError {
                thrown = error
            }

            guard case .rootMoveFailed(_, _, _, let rolledBack) = try #require(thrown) else {
                Issue.record("expected a rootMoveFailed error")
                return
            }
            #expect(!rolledBack)
            #expect(thrown?.errorDescription?.contains("WARNING") == true)
        }
    }
}

// MARK: - Helpers

private func withTempDirectory<Result>(_ body: (URL) throws -> Result) throws -> Result {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kvoice-move-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    let found = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    return found && isDirectory.boolValue
}

/// Visible entries, sorted — what a user would see in Finder.
private func names(in url: URL) -> [String] {
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )) ?? []
    return contents.map(\.lastPathComponent).sorted()
}

/// `FileOperations` that fails chosen moves, so rollback can be tested against
/// a real filesystem rather than a mock's bookkeeping.
private final class MoveFailingOperations: FileOperations, @unchecked Sendable {
    struct InjectedFailure: Error {}

    private let system = SystemFileOperations()
    private let failingMoveIndices: Set<Int>
    private let lock = NSLock()
    private var moveCount = 0

    init(failingMoveIndices: Set<Int>) {
        self.failingMoveIndices = failingMoveIndices
    }

    func fileExists(at url: URL) -> Bool { system.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { system.isDirectory(at: url) }
    func createDirectory(at url: URL) throws { try system.createDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try system.contentsOfDirectory(at: url) }
    func copyItem(at source: URL, to destination: URL) throws { try system.copyItem(at: source, to: destination) }

    func moveItem(at source: URL, to destination: URL) throws {
        let index: Int = lock.withLock {
            moveCount += 1
            return moveCount
        }
        if failingMoveIndices.contains(index) { throw InjectedFailure() }
        try system.moveItem(at: source, to: destination)
    }
}
