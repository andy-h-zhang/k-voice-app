import Foundation
import Testing

@testable import KVoiceCore

/// ``LibraryMigration`` rewrites folders a user cannot get back, so these lean
/// hard on the properties that make that survivable: idempotency, per-folder
/// isolation, rollback, and never deleting anything.
@Suite("Storage library migration")
struct StorageLibraryMigrationTests {

    // MARK: - Name derivation

    @Test("a legacy folder name loses its time and its 'Recording'")
    func projectNames() {
        let name = LibraryMigration.projectName(fromLegacyFolderName:)

        #expect(name("2026-08-14 09.15 Recording") == "2026-08-14")
        #expect(name("2026-08-14 09.15") == "2026-08-14")
        #expect(name("2026-08-14 Recording") == "2026-08-14")
        #expect(name("2026-08-14") == "2026-08-14")
        // `speakerlab record`'s format.
        #expect(name("2026-08-14 09-15-30 Recording") == "2026-08-14")
    }

    /// A name the user chose is not the migration's to reinterpret. Only the
    /// machine-generated shape — a date, optionally a clock, optionally the
    /// word "Recording" — is rewritten.
    @Test("a user's own title is left alone")
    func keepsUserTitles() {
        let name = LibraryMigration.projectName(fromLegacyFolderName:)

        #expect(name("Standup") == "Standup")
        #expect(name("Q3 planning") == "Q3 planning")
        #expect(name("2026-08-14 Weekly Sync") == "2026-08-14 Weekly Sync")
        #expect(name("2026-08-14 09.15 Weekly Sync") == "2026-08-14 Weekly Sync")
        // Not a date, so nothing is stripped — including the trailing word.
        // "Morning Recording" is a name somebody chose; the migration has no
        // business deciding the last word of it was boilerplate.
        #expect(name("Morning Recording") == "Morning Recording")
        #expect(name("2026-8-14 09.15") == "2026-8-14 09.15")
    }

    // MARK: - The happy path

    @Test("a legacy library becomes project folders")
    func migratesALibrary() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            try makeLegacyRecording(named: "2026-08-14 09.15 Recording", in: root)
            try makeLegacyExport(
                base: "2026-08-14 09.15 Recording", extension: "md", body: "# notes", in: root
            )

            let report = try LibraryMigration(store: store).run()

            #expect(report.failures.isEmpty)
            #expect(report.migrated.map(\.newFolderName) == ["2026-08-14"])
            #expect(report.transcriptsFolderRemoved)

            let folder = root.appendingPathComponent("2026-08-14")
            #expect(contents(of: folder).sorted() == [
                "2026-08-14 Recording.m4a",
                "2026-08-14 Transcript.md",
                "transcript.raw.json",
            ])
            #expect(!exists(root.appendingPathComponent("Transcripts")))
        }
    }

    @Test("two recordings from one day dedupe rather than collide")
    func sameDayDedupes() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            try makeLegacyRecording(named: "2026-08-14 09.15 Recording", in: root)
            try makeLegacyRecording(named: "2026-08-14 16.40 Recording", in: root)

            let report = try LibraryMigration(store: store).run()

            #expect(report.failures.isEmpty)
            #expect(report.migrated.map(\.newFolderName).sorted() == ["2026-08-14", "2026-08-14 2"])
            #expect(exists(root.appendingPathComponent("2026-08-14/2026-08-14 Recording.m4a")))
            #expect(exists(root.appendingPathComponent("2026-08-14 2/2026-08-14 2 Recording.m4a")))
        }
    }

    /// A folder that already holds the name a *later* folder wants must not be
    /// trampled — which is why the claimed-name set is seeded with every
    /// existing folder before the walk starts.
    @Test("an existing folder already holding the target name is not overwritten")
    func doesNotTrampleAnExistingName() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            try makeLegacyRecording(named: "2026-08-14", in: root)
            try makeLegacyRecording(named: "2026-08-14 09.15 Recording", in: root)

            let report = try LibraryMigration(store: store).run()

            #expect(report.failures.isEmpty)
            #expect(exists(root.appendingPathComponent("2026-08-14")))
            #expect(exists(root.appendingPathComponent("2026-08-14 2")))
            // The pre-existing folder kept its own audio.
            #expect(exists(root.appendingPathComponent("2026-08-14/2026-08-14 Recording.m4a")))
        }
    }

    // MARK: - Idempotency

    @Test("running twice changes nothing the second time")
    func isIdempotent() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            try makeLegacyRecording(named: "2026-08-14 09.15 Recording", in: root)
            try makeLegacyExport(
                base: "2026-08-14 09.15 Recording", extension: "md", body: "# notes", in: root
            )

            _ = try LibraryMigration(store: store).run()
            let before = contents(of: root.appendingPathComponent("2026-08-14")).sorted()

            let second = try LibraryMigration(store: store).run()

            #expect(second.migrated.isEmpty)
            #expect(second.failures.isEmpty)
            #expect(!second.didAnything)
            #expect(contents(of: root.appendingPathComponent("2026-08-14")).sorted() == before)
        }
    }

    @Test("an already-current library is left exactly as it is")
    func leavesCurrentLayoutAlone() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            let folder = try store.createRecording(title: "2026-08-14 Weekly Sync")
            try Data("audio".utf8).write(to: folder.audioURL)
            try Data("# notes".utf8).write(to: folder.transcriptURL(.markdown))

            let report = try LibraryMigration(store: store).run()

            #expect(!report.didAnything)
            #expect(contents(of: folder.folderURL).sorted() == [
                "2026-08-14 Weekly Sync Recording.m4a",
                "2026-08-14 Weekly Sync Transcript.md",
            ])
        }
    }

    // MARK: - Not deleting things

    /// An export whose recording folder is gone has nowhere to be filed. It
    /// stays where it is, and the report names it, rather than the migration
    /// deciding a user's transcript is disposable.
    @Test("an orphaned export is kept and reported, and keeps the folder alive")
    func keepsOrphanedExports() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            try makeLegacyExport(base: "Recording From A Deleted Meeting", extension: "md",
                                 body: "# notes", in: root)

            let report = try LibraryMigration(store: store).run()

            #expect(!report.transcriptsFolderRemoved)
            #expect(report.orphanedExports == ["Recording From A Deleted Meeting.md"])
            #expect(exists(root.appendingPathComponent("Transcripts")))
        }
    }

    /// The app no longer writes Word, which is not a reason to destroy a
    /// `.docx` an earlier version produced.
    @Test("a legacy .docx is moved in, not deleted")
    func keepsLegacyWordExports() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            try makeLegacyRecording(named: "2026-08-14 09.15 Recording", in: root)
            for ext in ["md", "txt", "docx"] {
                try makeLegacyExport(
                    base: "2026-08-14 09.15 Recording", extension: ext, body: "x", in: root
                )
            }

            _ = try LibraryMigration(store: store).run()

            #expect(contents(of: root.appendingPathComponent("2026-08-14")).sorted() == [
                "2026-08-14 Recording.m4a",
                "2026-08-14 Transcript.docx",
                "2026-08-14 Transcript.md",
                "2026-08-14 Transcript.txt",
                "transcript.raw.json",
            ])
        }
    }

    @Test("a Finder .DS_Store does not keep the transcripts folder alive")
    func ignoresDSStore() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            let transcripts = root.appendingPathComponent("Transcripts", isDirectory: true)
            try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
            try Data().write(to: transcripts.appendingPathComponent(".DS_Store"))

            let report = try LibraryMigration(store: store).run()

            #expect(report.transcriptsFolderRemoved)
            #expect(!exists(transcripts))
        }
    }

    // MARK: - Failure isolation

    /// One unmigratable folder is reported and skipped. Forty others still
    /// migrate — a library half in each layout because of one bad folder would
    /// be worse than either layout.
    @Test("a folder that cannot move is rolled back, and the rest still migrate")
    func isolatesFailures() throws {
        try withTemporaryDirectory { root in
            try makeLegacyRecording(named: "2026-08-13 08.00 Recording", in: root)
            try makeLegacyRecording(named: "2026-08-14 09.15 Recording", in: root)
            try makeLegacyRecording(named: "2026-08-15 10.30 Recording", in: root)

            // Fail only the folder move of the middle recording. Each folder
            // needs two moves here (audio, then folder), so index 3 is the
            // second folder's folder-move.
            let operations = MoveFailingOperations(failingMoveIndices: [4])
            let store = RecordingStore(rootURL: root, operations: operations)

            let report = try LibraryMigration(store: store, operations: operations).run()

            #expect(report.failures.count == 1)
            #expect(report.failures.first?.oldFolderName == "2026-08-14 09.15 Recording")
            #expect(report.migrated.count == 2)

            // The failed one is intact under its original name, audio included.
            let untouched = root.appendingPathComponent("2026-08-14 09.15 Recording")
            #expect(isDirectory(untouched))
            #expect(contents(of: untouched).sorted() == [
                "2026-08-14 09.15 Recording.m4a", "transcript.raw.json",
            ])

            // The others went through.
            #expect(exists(root.appendingPathComponent("2026-08-13/2026-08-13 Recording.m4a")))
            #expect(exists(root.appendingPathComponent("2026-08-15/2026-08-15 Recording.m4a")))
        }
    }

    @Test("a folder holding no audio is not reported as a recording at all")
    func ignoresFoldersWithoutAudio() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            let stray = root.appendingPathComponent("Notes", isDirectory: true)
            try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: stray.appendingPathComponent("readme.txt"))

            let report = try LibraryMigration(store: store).run()

            #expect(report.folders.isEmpty)
            #expect(contents(of: stray) == ["readme.txt"])
        }
    }

    @Test("migrating a library that does not exist yet is a no-op")
    func handlesMissingRoot() throws {
        try withTemporaryDirectory { parent in
            let root = parent.appendingPathComponent("NeverUsed", isDirectory: true)
            let report = try LibraryMigration(store: RecordingStore(rootURL: root)).run()

            #expect(!report.didAnything)
        }
    }

    // MARK: - Fixtures

    private func makeLegacyRecording(named name: String, in root: URL) throws {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The old layout: audio named exactly after its folder.
        try Data("audio".utf8).write(to: folder.appendingPathComponent("\(name).m4a"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("transcript.raw.json"))
    }

    private func makeLegacyExport(
        base: String,
        extension pathExtension: String,
        body: String,
        in root: URL
    ) throws {
        let transcripts = root.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        try Data(body.utf8).write(
            to: transcripts.appendingPathComponent("\(base).\(pathExtension)")
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return found && isDirectory.boolValue
    }

    private func contents(of url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0 != ".DS_Store" }
    }

    private func withTemporaryDirectory<Result>(_ body: (URL) throws -> Result) throws -> Result {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }
}

/// Fails the *n*th move, so a rollback can be observed. A local copy of the
/// one in `StorageLibraryMoveTests`, which is file-private there — sharing it
/// would couple two suites' move counting, and the count is the whole point.
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
    func copyItem(at source: URL, to destination: URL) throws {
        try system.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        let index: Int = lock.withLock {
            moveCount += 1
            return moveCount
        }
        if failingMoveIndices.contains(index) { throw InjectedFailure() }
        try system.moveItem(at: source, to: destination)
    }
}
