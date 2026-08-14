import AVFoundation
import Foundation
import Testing
@testable import KVoiceCore

/// The on-disk library: folder layout, collisions, rename-with-rollback, and
/// the duration probe. Everything runs against real temporary directories —
/// only the failure injection is faked.
@Suite("Storage recording store")
struct StorageRecordingStoreTests {
    // MARK: - Layout

    @Test("creating a recording makes one folder holding one .m4a path")
    func createsFolderPerRecording() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            let folder = try store.createRecording(title: "2026-08-13 Standup")

            #expect(folder.baseName == "2026-08-13 Standup")
            #expect(folder.folderURL == root.appendingPathComponent("2026-08-13 Standup", isDirectory: true))
            #expect(folder.audioURL.lastPathComponent == "2026-08-13 Standup.m4a")
            #expect(folder.audioURL.deletingLastPathComponent().path == folder.folderURL.path)
            #expect(isDirectory(folder.folderURL))
        }
    }

    @Test("the audio file is named after the folder, and exports share the base")
    func siblingFilesShareTheBaseName() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            let folder = try store.createRecording(title: "Standup")

            #expect(folder.folderURL.lastPathComponent == folder.baseName)
            #expect(folder.audioURL.lastPathComponent == "\(folder.baseName).m4a")
            #expect(folder.fileURL(withExtension: "md").lastPathComponent == "\(folder.baseName).md")
            #expect(folder.fileURL(withExtension: "docx").lastPathComponent == "\(folder.baseName).docx")
        }
    }

    @Test("the library root is created on demand, including missing parents")
    func createsRootOnDemand() throws {
        try withTemporaryDirectory { parent in
            let root = parent.appendingPathComponent("nested/KVoice", isDirectory: true)
            let store = RecordingStore(rootURL: root)

            #expect(!isDirectory(root))
            _ = try store.createRecording(title: "First")
            #expect(isDirectory(root))
        }
    }

    @Test("a file where the root should be is an error, not a crash")
    func rootThatIsAFileIsAnError() throws {
        try withTemporaryDirectory { parent in
            let root = parent.appendingPathComponent("KVoice")
            try Data("not a folder".utf8).write(to: root)

            let store = RecordingStore(rootURL: root)
            #expect(throws: StorageError.notADirectory(path: root.path)) {
                try store.createRootIfNeeded()
            }
        }
    }

    @Test("titles are sanitized on the way to disk")
    func titlesAreSanitized() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            let folder = try store.createRecording(title: "Q1/Q2: Review ")

            #expect(folder.baseName == "Q1 Q2 Review")
            #expect(isDirectory(folder.folderURL))
        }
    }

    // MARK: - Collisions

    @Test("a second recording with the same title gets a ' 2' suffix")
    func collidingTitlesGetSuffixes() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)

            let first = try store.createRecording(title: "Standup")
            let second = try store.createRecording(title: "Standup")
            let third = try store.createRecording(title: "Standup")

            #expect(first.baseName == "Standup")
            #expect(second.baseName == "Standup 2")
            #expect(third.baseName == "Standup 3")

            for folder in [first, second, third] {
                #expect(isDirectory(folder.folderURL))
                #expect(folder.audioURL.lastPathComponent == "\(folder.baseName).m4a")
            }
        }
    }

    @Test("collision suffixes apply after sanitizing, not before")
    func collisionsAreDetectedOnTheSanitizedName() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)

            let first = try store.createRecording(title: "Team: Sync")
            let second = try store.createRecording(title: "Team/Sync")

            #expect(first.baseName == "Team Sync")
            #expect(second.baseName == "Team Sync 2")
        }
    }

    // MARK: - Listing

    @Test("listing returns folders that hold audio, sorted, and skips the rest")
    func listingSkipsFoldersWithoutAudio() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)

            let standup = try store.createRecording(title: "Standup")
            try writeSilentFile(at: standup.audioURL, extension: "m4a")

            let review = try store.createRecording(title: "Review")
            try writeSilentFile(at: review.audioURL, extension: "m4a")

            // A folder the user made by hand, with no recording in it.
            let stray = try store.createRecording(title: "Empty")
            #expect(isDirectory(stray.folderURL))

            let listed = try store.recordings()
            #expect(listed.map(\.baseName) == ["Review", "Standup"])
        }
    }

    @Test("listing a root that does not exist yet returns nothing")
    func listingMissingRootIsEmpty() throws {
        try withTemporaryDirectory { parent in
            let store = RecordingStore(rootURL: parent.appendingPathComponent("missing"))
            let listed = try store.recordings()
            #expect(listed.isEmpty)
        }
    }

    // MARK: - Rename

    @Test("renaming moves the folder, the audio, and every export sharing the base")
    func renameMovesFolderAudioAndExports() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            let folder = try store.createRecording(title: "Standup")

            try writeSilentFile(at: folder.audioURL, extension: "m4a")
            try Data("# notes".utf8).write(to: folder.fileURL(withExtension: "md"))
            try Data("notes".utf8).write(to: folder.fileURL(withExtension: "txt"))
            try Data("PK".utf8).write(to: folder.fileURL(withExtension: "docx"))

            let renamed = try store.rename(folder, to: "Weekly Sync")

            #expect(renamed.baseName == "Weekly Sync")
            #expect(renamed.folderURL.lastPathComponent == "Weekly Sync")
            #expect(!exists(folder.folderURL))
            #expect(isDirectory(renamed.folderURL))

            for pathExtension in ["m4a", "md", "txt", "docx"] {
                #expect(exists(renamed.fileURL(withExtension: pathExtension)))
            }
            #expect(contents(of: renamed.folderURL).sorted() == [
                "Weekly Sync.docx", "Weekly Sync.m4a", "Weekly Sync.md", "Weekly Sync.txt"
            ])
        }
    }

    /// `transcript.raw.json` is not named after the title, so a rename must
    /// leave it exactly where it is.
    @Test("files not named after the recording are left alone")
    func renameLeavesUnrelatedFilesAlone() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            let folder = try store.createRecording(title: "Standup")

            try writeSilentFile(at: folder.audioURL, extension: "m4a")
            let raw = folder.folderURL.appendingPathComponent("transcript.raw.json")
            try Data("{}".utf8).write(to: raw)

            let renamed = try store.rename(folder, to: "Weekly Sync")

            #expect(exists(renamed.folderURL.appendingPathComponent("transcript.raw.json")))
            #expect(contents(of: renamed.folderURL).sorted() == ["Weekly Sync.m4a", "transcript.raw.json"])
        }
    }

    /// A base-named multi-extension file (`<base>.raw.json`) keeps everything
    /// after the base name.
    @Test("compound extensions follow the rename")
    func renameHandlesCompoundExtensions() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            let folder = try store.createRecording(title: "Standup")

            try writeSilentFile(at: folder.audioURL, extension: "m4a")
            try Data("{}".utf8).write(to: folder.folderURL.appendingPathComponent("Standup.raw.json"))

            let renamed = try store.rename(folder, to: "Weekly Sync")
            #expect(exists(renamed.folderURL.appendingPathComponent("Weekly Sync.raw.json")))
        }
    }

    @Test("renaming into an existing name takes the next free suffix")
    func renameIntoExistingNameGetsSuffix() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)

            let existing = try store.createRecording(title: "Weekly Sync")
            try writeSilentFile(at: existing.audioURL, extension: "m4a")

            let folder = try store.createRecording(title: "Standup")
            try writeSilentFile(at: folder.audioURL, extension: "m4a")

            let renamed = try store.rename(folder, to: "Weekly Sync")

            #expect(renamed.baseName == "Weekly Sync 2")
            #expect(exists(renamed.audioURL))
            #expect(exists(existing.audioURL))              // untouched
        }
    }

    @Test("the new title is sanitized")
    func renameSanitizesTheNewTitle() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            let folder = try store.createRecording(title: "Standup")
            try writeSilentFile(at: folder.audioURL, extension: "m4a")

            let renamed = try store.rename(folder, to: " ../Weekly: Sync ")

            #expect(renamed.baseName == "Weekly Sync")
            #expect(renamed.folderURL.deletingLastPathComponent().path == root.path)
        }
    }

    @Test("renaming to the same title is a no-op")
    func renameToSameTitleIsANoOp() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            let folder = try store.createRecording(title: "Standup")
            try writeSilentFile(at: folder.audioURL, extension: "m4a")

            let renamed = try store.rename(folder, to: "Standup")

            #expect(renamed == folder)
            #expect(exists(folder.audioURL))
        }
    }

    @Test("renaming a recording that is gone from disk fails cleanly")
    func renameMissingFolderThrows() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            let folder = RecordingFolder(
                folderURL: root.appendingPathComponent("Gone", isDirectory: true),
                baseName: "Gone"
            )

            #expect(throws: StorageError.fileNotFound(path: folder.folderURL.path)) {
                _ = try store.rename(folder, to: "Anything")
            }
        }
    }

    // MARK: - Rename rollback

    /// The folder move is the last step; if it fails, the file moves that
    /// already happened have to be undone or disk and database disagree.
    @Test("a failure renaming the folder rolls the file moves back")
    func rollsBackWhenTheFolderMoveFails() throws {
        try withTemporaryDirectory { root in
            // Moves are: 1) <base>.m4a  2) <base>.md  3) the folder itself.
            let operations = FailingFileOperations(failingMoveIndices: [3])
            let store = RecordingStore(rootURL: root, operations: operations)

            let folder = try store.createRecording(title: "Standup")
            try writeSilentFile(at: folder.audioURL, extension: "m4a")
            try Data("# notes".utf8).write(to: folder.fileURL(withExtension: "md"))
            try Data("{}".utf8).write(to: folder.folderURL.appendingPathComponent("transcript.raw.json"))

            var thrown: StorageError?
            do {
                _ = try store.rename(folder, to: "Weekly Sync")
            } catch let error as StorageError {
                thrown = error
            }

            let error = try #require(thrown)
            guard case .renameFailed(let from, let to, _, let rolledBack) = error else {
                Issue.record("expected renameFailed, got \(error)")
                return
            }
            #expect(from == "Standup")
            #expect(to == "Weekly Sync")
            #expect(rolledBack)

            // Disk is exactly as it was before the attempt.
            #expect(isDirectory(folder.folderURL))
            #expect(!exists(root.appendingPathComponent("Weekly Sync")))
            #expect(contents(of: folder.folderURL).sorted() == [
                "Standup.m4a", "Standup.md", "transcript.raw.json"
            ])
        }
    }

    @Test("a failure on the first file move leaves everything untouched")
    func rollsBackWhenTheFirstFileMoveFails() throws {
        try withTemporaryDirectory { root in
            let operations = FailingFileOperations(failingMoveIndices: [1])
            let store = RecordingStore(rootURL: root, operations: operations)

            let folder = try store.createRecording(title: "Standup")
            try writeSilentFile(at: folder.audioURL, extension: "m4a")
            try Data("# notes".utf8).write(to: folder.fileURL(withExtension: "md"))

            #expect(throws: StorageError.self) {
                _ = try store.rename(folder, to: "Weekly Sync")
            }

            #expect(contents(of: folder.folderURL).sorted() == ["Standup.m4a", "Standup.md"])
        }
    }

    /// If the undo itself fails, the error has to say so — silently reporting
    /// a clean rollback would let the caller update its database against a
    /// half-renamed folder.
    @Test("a failed rollback is reported rather than hidden")
    func reportsWhenRollbackItselfFails() throws {
        try withTemporaryDirectory { root in
            // 1) .m4a  2) .md  3) folder (fails)  4) undo .md  5) undo .m4a
            let operations = FailingFileOperations(failingMoveIndices: [3, 4, 5])
            let store = RecordingStore(rootURL: root, operations: operations)

            let folder = try store.createRecording(title: "Standup")
            try writeSilentFile(at: folder.audioURL, extension: "m4a")
            try Data("# notes".utf8).write(to: folder.fileURL(withExtension: "md"))

            var thrown: StorageError?
            do {
                _ = try store.rename(folder, to: "Weekly Sync")
            } catch let error as StorageError {
                thrown = error
            }

            let error = try #require(thrown)
            guard case .renameFailed(_, _, _, let rolledBack) = error else {
                Issue.record("expected renameFailed, got \(error)")
                return
            }
            #expect(!rolledBack)
            #expect(error.errorDescription?.contains("could NOT be restored") == true)
        }
    }

    @Test("rollback restores the original names on disk, not just in the error")
    func rollbackRestoresNamesOnDisk() throws {
        try withTemporaryDirectory { root in
            let operations = FailingFileOperations(failingMoveIndices: [2])
            let store = RecordingStore(rootURL: root, operations: operations)

            let folder = try store.createRecording(title: "Standup")
            try writeSilentFile(at: folder.audioURL, extension: "m4a")
            try Data("# notes".utf8).write(to: folder.fileURL(withExtension: "md"))

            #expect(throws: StorageError.self) {
                _ = try store.rename(folder, to: "Weekly Sync")
            }

            // The .m4a moved, then the .md failed: the .m4a must be back.
            #expect(exists(folder.audioURL))
            #expect(!exists(folder.folderURL.appendingPathComponent("Weekly Sync.m4a")))
        }
    }

    // MARK: - Duration probe

    @Test("the duration of a finished file comes from its frame count")
    func probesDurationOfFinishedFile() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("probe.wav")
            try writeSilentFile(at: url, extension: "wav", seconds: 2.5)

            let duration = try RecordingStore.duration(ofAudioAt: url)
            #expect(abs(duration - 2.5) < 0.01)
        }
    }

    @Test("a recording's duration is read through its folder")
    func probesDurationThroughTheFolder() throws {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootURL: root)
            let folder = try store.createRecording(title: "Standup")
            try writeSilentFile(at: folder.audioURL, extension: "m4a", seconds: 1)

            let duration = try store.duration(of: folder)
            #expect(abs(duration - 1) < 0.1)
        }
    }

    @Test("probing a missing file reports the path")
    func probingMissingFileThrows() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("nope.m4a")
            #expect(throws: StorageError.fileNotFound(path: url.path)) {
                _ = try RecordingStore.duration(ofAudioAt: url)
            }
        }
    }

    @Test("probing a file that is not audio fails cleanly")
    func probingNonAudioThrows() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("notes.m4a")
            try Data("this is not audio".utf8).write(to: url)

            #expect(throws: StorageError.self) {
                _ = try RecordingStore.duration(ofAudioAt: url)
            }
        }
    }

    // MARK: - Defaults

    @Test("the default library root is a visible folder in Documents")
    func defaultRootIsUserVisible() {
        let root = RecordingStore.defaultRootURL()
        #expect(root.lastPathComponent == "KVoice")
        #expect(root.deletingLastPathComponent().lastPathComponent == "Documents")
        #expect(RecordingStore.defaultRootURL(appName: "Other").lastPathComponent == "Other")
    }
}

// MARK: - Helpers

/// Runs `body` with a fresh temporary directory that is removed afterwards.
private func withTemporaryDirectory<Result>(_ body: (URL) throws -> Result) throws -> Result {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kvoice-tests-\(UUID().uuidString)", isDirectory: true)
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

private func contents(of url: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
}

/// Writes a real, readable audio file of `seconds` of silence.
///
/// `.wav` is written as linear PCM and `.m4a` as AAC — the same settings the
/// recorder uses, so the duration probe is exercised against a genuinely
/// encoded file. No microphone or audio hardware is involved: this is an
/// encoder writing to a file.
private func writeSilentFile(at url: URL, extension pathExtension: String, seconds: Double = 1) throws {
    let sampleRate: Double = 48_000

    let settings: [String: Any]
    if pathExtension.lowercased() == "m4a" {
        settings = RecordingFormat.aacMono48k.settings
    } else {
        settings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]
    }

    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frameCount = AVAudioFrameCount(sampleRate * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
        throw StorageError.durationProbeFailed(path: url.path, reason: "could not allocate a write buffer")
    }
    buffer.frameLength = frameCount                      // zero-filled: silence
    try file.write(from: buffer)
}

/// `FileOperations` that fails chosen moves, so rollback can be tested.
///
/// Everything else goes to the real filesystem, so assertions afterwards
/// check real on-disk state rather than a mock's bookkeeping.
private final class FailingFileOperations: FileOperations, @unchecked Sendable {
    struct InjectedFailure: Error {
        let moveIndex: Int
    }

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

    func moveItem(at source: URL, to destination: URL) throws {
        let index: Int = lock.withLock {
            moveCount += 1
            return moveCount
        }
        if failingMoveIndices.contains(index) {
            throw InjectedFailure(moveIndex: index)
        }
        try system.moveItem(at: source, to: destination)
    }
}
