import AVFoundation
import Foundation

/// One recording's folder on disk.
///
/// ```
/// <root>/2026-08-13 Standup/          ← folderURL   (name == baseName)
///        ├── 2026-08-13 Standup.m4a   ← audioURL
///        ├── transcript.raw.json      ← written in Phase 3
///        └── 2026-08-13 Standup.md    ← exports, Phase 7
/// ```
public struct RecordingFolder: Sendable, Equatable, Identifiable {
    public var id: URL { folderURL }

    /// The recording's folder.
    public let folderURL: URL
    /// Filename stem shared by the audio file and every export.
    public let baseName: String
    /// Extension of the audio file, without the dot.
    public let audioFileExtension: String

    public init(folderURL: URL, baseName: String, audioFileExtension: String = "m4a") {
        self.folderURL = folderURL
        self.baseName = baseName
        self.audioFileExtension = audioFileExtension
    }

    /// The recording's audio file.
    public var audioURL: URL {
        fileURL(withExtension: audioFileExtension)
    }

    /// A sibling file sharing the base name, e.g. the `.md` export.
    public func fileURL(withExtension pathExtension: String) -> URL {
        folderURL.appendingPathComponent("\(baseName).\(pathExtension)")
    }
}

/// The user-visible recording library on disk.
///
/// Layout is deliberately plain (`docs/implementation-plan.md` §1): a
/// configurable root, one folder per recording, files named after the
/// recording's title so everything is grabbable in Finder. Nothing here
/// knows about SwiftData — the database stores IDs and follows the
/// filesystem, not the other way round.
public struct RecordingStore: Sendable {
    /// Root folder holding one subfolder per recording.
    public let rootURL: URL

    private let operations: FileOperations

    public init(rootURL: URL, operations: FileOperations = SystemFileOperations()) {
        self.rootURL = rootURL
        self.operations = operations
    }

    /// The default library root, `~/Documents/<appName>`.
    public static func defaultRootURL(appName: String = "KVoice") -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent(appName, isDirectory: true)
    }

    // MARK: - Creating

    /// Creates the library root if it does not exist yet.
    public func createRootIfNeeded() throws {
        if operations.fileExists(at: rootURL) {
            guard operations.isDirectory(at: rootURL) else {
                throw StorageError.notADirectory(path: rootURL.path)
            }
            return
        }
        do {
            try operations.createDirectory(at: rootURL)
        } catch {
            throw StorageError.rootCreationFailed(
                path: rootURL.path,
                reason: error.localizedDescription
            )
        }
    }

    /// Creates an empty folder for a new recording.
    ///
    /// The title is sanitized and collision-suffixed, so two recordings
    /// called "Standup" become `Standup` and `Standup 2`. The audio file
    /// itself is created by the recorder writing to ``RecordingFolder/audioURL``.
    public func createRecording(
        title: String,
        format: RecordingFormat = .aacMono48k
    ) throws -> RecordingFolder {
        try createRootIfNeeded()

        let sanitized = FilenameSanitizer.sanitize(title)
        let uniqueName = FilenameSanitizer.uniqueName(for: sanitized) { candidate in
            operations.fileExists(at: rootURL.appendingPathComponent(candidate))
        }

        let folderURL = rootURL.appendingPathComponent(uniqueName, isDirectory: true)
        do {
            try operations.createDirectory(at: folderURL)
        } catch {
            throw StorageError.folderCreationFailed(
                path: folderURL.path,
                reason: error.localizedDescription
            )
        }

        return RecordingFolder(
            folderURL: folderURL,
            baseName: uniqueName,
            audioFileExtension: format.fileExtension
        )
    }

    // MARK: - Listing

    /// Every recording folder under the root, by name.
    ///
    /// A folder counts as a recording once it holds an audio file; the base
    /// name is read from that file rather than assumed, so a folder someone
    /// renamed by hand in Finder still resolves.
    public func recordings(audioFileExtension: String = "m4a") throws -> [RecordingFolder] {
        guard operations.fileExists(at: rootURL) else { return [] }

        let entries = try operations.contentsOfDirectory(at: rootURL)
        let folders: [RecordingFolder] = try entries.compactMap { entry in
            guard operations.isDirectory(at: entry) else { return nil }

            let contents = try operations.contentsOfDirectory(at: entry)
            let audioFiles = contents.filter {
                $0.pathExtension.lowercased() == audioFileExtension.lowercased()
            }
            // Prefer the file named after the folder; otherwise take the
            // first, so a hand-renamed folder still yields a usable base.
            let folderName = entry.lastPathComponent
            let match = audioFiles.first { $0.deletingPathExtension().lastPathComponent == folderName }
                ?? audioFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first
            guard let match else { return nil }

            return RecordingFolder(
                folderURL: entry,
                baseName: match.deletingPathExtension().lastPathComponent,
                audioFileExtension: match.pathExtension
            )
        }

        return folders.sorted { $0.folderURL.lastPathComponent < $1.folderURL.lastPathComponent }
    }

    // MARK: - Renaming

    /// Renames a recording: its folder, its audio file, and every sibling
    /// file sharing the base name (exports, raw transcript).
    ///
    /// Filesystem first, database second (`docs/implementation-plan.md` §3
    /// decision 6): files are what the user sees, so the caller only updates
    /// its records after this returns. If any move fails, the moves already
    /// made are undone and ``StorageError/renameFailed(from:to:reason:rolledBack:)``
    /// reports whether that undo succeeded.
    ///
    /// - Returns: The recording's new location. May carry a collision suffix.
    public func rename(_ folder: RecordingFolder, to newTitle: String) throws -> RecordingFolder {
        guard operations.fileExists(at: folder.folderURL) else {
            throw StorageError.fileNotFound(path: folder.folderURL.path)
        }

        let parent = folder.folderURL.deletingLastPathComponent()
        let currentFolderName = folder.folderURL.lastPathComponent
        let sanitized = FilenameSanitizer.sanitize(newTitle)

        let newBase = FilenameSanitizer.uniqueName(for: sanitized) { candidate in
            // The recording's own folder is not a collision with itself.
            candidate != currentFolderName
                && operations.fileExists(at: parent.appendingPathComponent(candidate))
        }

        guard newBase != folder.baseName || newBase != currentFolderName else {
            return folder
        }

        var completed: [(from: URL, to: URL)] = []
        do {
            // 1. Files inside the folder, before the folder itself: their
            //    URLs are only valid while the folder is where we left it.
            let prefix = folder.baseName + "."
            let contents = try operations.contentsOfDirectory(at: folder.folderURL)
            for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.lastPathComponent
                guard name.hasPrefix(prefix) else { continue }

                // Keep everything after the base name, so "<base>.raw.json"
                // and "<base>.m4a" both follow the rename.
                let remainder = String(name.dropFirst(folder.baseName.count))
                let destination = folder.folderURL.appendingPathComponent(newBase + remainder)
                guard !operations.fileExists(at: destination) else {
                    throw StorageError.destinationExists(path: destination.path)
                }

                try operations.moveItem(at: url, to: destination)
                completed.append((from: url, to: destination))
            }

            // 2. The folder.
            var newFolderURL = folder.folderURL
            if newBase != currentFolderName {
                let destination = parent.appendingPathComponent(newBase, isDirectory: true)
                guard !operations.fileExists(at: destination) else {
                    throw StorageError.destinationExists(path: destination.path)
                }
                try operations.moveItem(at: folder.folderURL, to: destination)
                newFolderURL = destination
            }

            return RecordingFolder(
                folderURL: newFolderURL,
                baseName: newBase,
                audioFileExtension: folder.audioFileExtension
            )
        } catch {
            let rolledBack = rollBack(completed)
            let reason = (error as? StorageError)?.errorDescription ?? error.localizedDescription
            throw StorageError.renameFailed(
                from: folder.baseName,
                to: newBase,
                reason: reason,
                rolledBack: rolledBack
            )
        }
    }

    // MARK: - Moving the whole library (Phase 6)

    /// Moves the entire library — every recording folder *and* the SwiftData
    /// store file beside them — to a new root, and returns a store pointing at
    /// it (spec §Settings: "Storage folder").
    ///
    /// ## The semantics, stated honestly
    ///
    /// - **The destination must be empty or absent.** Merging two libraries
    ///   would silently interleave two sets of recording folders and two
    ///   `KVoice.store` files; there is no correct answer for the second one,
    ///   so this refuses rather than guesses.
    /// - **Contents move, not the folder itself.** Every child of the root is
    ///   moved individually, so the destination a user just created in the open
    ///   panel is a valid target. The consequence is that the *old* root folder
    ///   is left behind, empty, for the user to delete — deleting a folder the
    ///   user chose is not this type's call.
    /// - **Rollback on partial failure.** Moves already made are undone, and
    ///   ``StorageError/rootMoveFailed(from:to:reason:rolledBack:)`` reports
    ///   whether that succeeded. Same contract as `rename`.
    /// - **Hidden files stay put.** `contentsOfDirectory` skips them, so a
    ///   stray `.DS_Store` remains in the old folder. Nothing KVoice writes is
    ///   hidden — including SQLite's `-wal`/`-shm` sidecars, which do move.
    ///
    /// The caller is responsible for the part this cannot do: an open
    /// `ModelContainer` holds the store file by path, so the app must not be
    /// mid-write, and it has to reopen (in practice, relaunch) afterwards.
    ///
    /// - Returns: A store rooted at `destination`.
    public func moveRoot(to destination: URL) throws -> RecordingStore {
        let source = rootURL.standardizedFileURL
        let target = destination.standardizedFileURL
        guard source != target else { return self }

        // Moving a folder's contents into a folder inside itself would either
        // recurse or lose data depending on enumeration order.
        guard !target.path.hasPrefix(source.path + "/") else {
            throw StorageError.destinationInsideSource(source: source.path, destination: target.path)
        }

        if operations.fileExists(at: target) {
            guard operations.isDirectory(at: target) else {
                throw StorageError.notADirectory(path: target.path)
            }
            guard try operations.contentsOfDirectory(at: target).isEmpty else {
                throw StorageError.destinationNotEmpty(path: target.path)
            }
        } else {
            do {
                try operations.createDirectory(at: target)
            } catch {
                throw StorageError.rootCreationFailed(
                    path: target.path,
                    reason: error.localizedDescription
                )
            }
        }

        // A library that was never written to is a settings change, not a move.
        guard operations.fileExists(at: source) else {
            return RecordingStore(rootURL: target, operations: operations)
        }
        guard operations.isDirectory(at: source) else {
            throw StorageError.notADirectory(path: source.path)
        }

        var completed: [(from: URL, to: URL)] = []
        do {
            let contents = try operations.contentsOfDirectory(at: source)
            for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let itemDestination = target.appendingPathComponent(url.lastPathComponent)
                guard !operations.fileExists(at: itemDestination) else {
                    throw StorageError.destinationExists(path: itemDestination.path)
                }
                try operations.moveItem(at: url, to: itemDestination)
                completed.append((from: url, to: itemDestination))
            }
        } catch {
            let rolledBack = rollBack(completed)
            let reason = (error as? StorageError)?.errorDescription ?? error.localizedDescription
            throw StorageError.rootMoveFailed(
                from: source.path,
                to: target.path,
                reason: reason,
                rolledBack: rolledBack
            )
        }

        return RecordingStore(rootURL: target, operations: operations)
    }

    /// Undoes completed moves, newest first. Returns whether every undo
    /// succeeded.
    private func rollBack(_ completed: [(from: URL, to: URL)]) -> Bool {
        var succeeded = true
        for move in completed.reversed() {
            do {
                try operations.moveItem(at: move.to, to: move.from)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    // MARK: - Probing

    /// Duration of a finished audio file, in seconds.
    ///
    /// Read from the file's own frame count rather than tracked in memory,
    /// so it is correct for files this process did not record (imports) and
    /// for recordings cut short by a crash.
    public static func duration(ofAudioAt url: URL) throws -> TimeInterval {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StorageError.fileNotFound(path: url.path)
        }

        do {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.fileFormat.sampleRate
            guard sampleRate > 0 else {
                throw StorageError.durationProbeFailed(
                    path: url.path,
                    reason: "the file reports a sample rate of zero"
                )
            }
            return Double(file.length) / sampleRate
        } catch let error as StorageError {
            throw error
        } catch {
            throw StorageError.durationProbeFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    /// Duration of a recording's audio file, in seconds.
    public func duration(of folder: RecordingFolder) throws -> TimeInterval {
        try Self.duration(ofAudioAt: folder.audioURL)
    }
}
