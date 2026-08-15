import AVFoundation
import Foundation

/// One recording's folder on disk.
///
/// ```
/// <root>/
/// ├── 2026-08-13 Standup/             ← folderURL   (name == baseName)
/// │   ├── 2026-08-13 Standup.m4a      ← audioURL
/// │   └── transcript.raw.json         ← verbatim provider response
/// └── Transcripts/                    ← RecordingStore.transcriptsFolderURL
///     └── 2026-08-13 Standup.md       ← rendered exports (.md/.txt/.docx)
/// ```
///
/// Rendered exports deliberately do **not** live here: they share one
/// `Transcripts/` folder at the library root so a user has a single place to
/// look for readable transcripts (see ``RecordingStore/transcriptsFolderURL``).
/// The raw response stays beside the audio, because it is the recording's own
/// re-processing input rather than a document.
public struct RecordingFolder: Sendable, Equatable, Identifiable {
    public var id: URL { folderURL }

    /// The recording's folder.
    public let folderURL: URL
    /// Filename stem shared by the audio file, the raw transcript, and the
    /// recording's rendered exports over in `Transcripts/`.
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

    /// A sibling file sharing the base name, e.g. `transcript.raw.json`'s
    /// title-named cousins.
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

    // MARK: - Transcripts folder

    /// The one folder holding every rendered export.
    ///
    /// A reserved name under the library root, so it is a sibling of the
    /// recording folders rather than inside one. ``recordings()`` skips it by
    /// name and never reports it as a recording.
    public static let transcriptsFolderName = "Transcripts"

    /// `<root>/Transcripts`, for callers that only have a root URL.
    public static func transcriptsFolderURL(inLibraryRoot root: URL) -> URL {
        root.appendingPathComponent(transcriptsFolderName, isDirectory: true)
    }

    /// Where every rendered export (`.md`, `.txt`, `.docx`) is written.
    ///
    /// One shared folder rather than one file per recording folder: a user
    /// looking for "the transcript of Tuesday's standup" should find every
    /// transcript in one place, and the File menu can point at it. The raw
    /// `transcript.raw.json` stays in the recording's own folder — it is
    /// re-processing input, not a document.
    ///
    /// Created lazily. Nothing creates it at launch, so a library that has
    /// never exported anything does not grow an empty folder.
    public var transcriptsFolderURL: URL {
        Self.transcriptsFolderURL(inLibraryRoot: rootURL)
    }

    /// Creates the transcripts folder if it does not exist yet.
    @discardableResult
    public func createTranscriptsFolderIfNeeded() throws -> URL {
        let folder = transcriptsFolderURL
        if operations.fileExists(at: folder) {
            guard operations.isDirectory(at: folder) else {
                throw StorageError.notADirectory(path: folder.path)
            }
            return folder
        }
        do {
            try operations.createDirectory(at: folder)
        } catch {
            throw StorageError.folderCreationFailed(
                path: folder.path,
                reason: error.localizedDescription
            )
        }
        return folder
    }

    /// The rendered exports belonging to one recording, by its base name.
    ///
    /// Matches on the `<baseName>.` prefix — the same rule ``rename(_:to:)``
    /// uses inside the recording's folder — so `.md`, `.txt` and `.docx` are
    /// all found in one pass without hard-coding the format list. Returns
    /// nothing when the folder has never been created.
    public func transcriptExports(forBaseName baseName: String) throws -> [URL] {
        let folder = transcriptsFolderURL
        guard operations.fileExists(at: folder), operations.isDirectory(at: folder) else {
            return []
        }
        let prefix = baseName + "."
        return try operations.contentsOfDirectory(at: folder)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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
        try createRecording(title: title, audioFileExtension: format.fileExtension)
    }

    /// Copies an existing audio file into the library as a new recording.
    ///
    /// The point of this is that an imported file becomes indistinguishable
    /// from a recorded one: same folder-per-recording shape, same base name
    /// shared by the audio and everything later rendered from it, so rename,
    /// export, Finder reveal and Trash all work on it without a special case.
    ///
    /// Copies rather than moves. The source is a file the user chose from
    /// somewhere else on their disk, and a picker that silently *removed* it
    /// from their Downloads folder would be a nasty surprise.
    ///
    /// - Throws: ``StorageError/fileNotFound(path:)`` if the source is gone, or
    ///   ``StorageError/folderCreationFailed(path:reason:)`` if the copy fails —
    ///   in which case the half-made folder is cleaned up rather than left as
    ///   an empty recording in the library.
    public func importRecording(from sourceURL: URL, title: String) throws -> RecordingFolder {
        guard operations.fileExists(at: sourceURL) else {
            throw StorageError.fileNotFound(path: sourceURL.path)
        }

        let folder = try createRecording(
            title: title,
            audioFileExtension: sourceURL.pathExtension
        )

        do {
            try operations.copyItem(at: sourceURL, to: folder.audioURL)
        } catch {
            try? FileManager.default.removeItem(at: folder.folderURL)
            throw StorageError.folderCreationFailed(
                path: folder.audioURL.path,
                reason: error.localizedDescription
            )
        }

        return folder
    }

    /// The same, for audio whose container the recorder did not choose.
    ///
    /// An imported file keeps its own extension — and therefore its own bytes.
    /// Transcoding a `.wav` to the recorder's AAC would lose quality to no
    /// purpose: everything downstream reads whatever `AVFoundation` can open,
    /// `Recording.folder(inRoot:)` derives the extension from the stored file
    /// name rather than assuming `m4a`, and AssemblyAI accepts the lot.
    public func createRecording(
        title: String,
        audioFileExtension: String
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
            audioFileExtension: audioFileExtension.isEmpty ? "m4a" : audioFileExtension.lowercased()
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
            // Reserved: exports, not a recording. It holds no audio today, so
            // this is belt-and-braces — but a user dropping an `.m4a` in there
            // should not conjure a phantom recording called "Transcripts".
            guard entry.lastPathComponent != Self.transcriptsFolderName else { return nil }

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

    /// Renames a recording: its folder, its audio file, every sibling file
    /// sharing the base name (the raw transcript), and the recording's
    /// rendered exports over in `Transcripts/`.
    ///
    /// Filesystem first, database second (`docs/implementation-plan.md` §3
    /// decision 6): files are what the user sees, so the caller only updates
    /// its records after this returns. If any move fails, the moves already
    /// made are undone and ``StorageError/renameFailed(from:to:reason:rolledBack:)``
    /// reports whether that undo succeeded.
    ///
    /// ## Why the exports are part of the same transaction
    ///
    /// `Transcripts/` is shared by every recording, so an export left under
    /// the old title is not merely untidy — it is indistinguishable from
    /// another recording's file. The moves therefore join the same
    /// `completed` list and unwind with everything else, folder move included.
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
            if candidate != currentFolderName,
                operations.fileExists(at: parent.appendingPathComponent(candidate)) {
                return true
            }
            // Nor are its own exports — but *another* recording's exports in
            // the shared folder are. Suffixing here beats discovering the
            // clash half-way through the move.
            if candidate != folder.baseName,
                let exports = try? transcriptExports(forBaseName: candidate),
                !exports.isEmpty {
                return true
            }
            return false
        }

        guard newBase != folder.baseName || newBase != currentFolderName else {
            return folder
        }

        var completed: [(from: URL, to: URL)] = []
        do {
            // 1. Files inside the folder, before the folder itself: their
            //    URLs are only valid while the folder is where we left it.
            //    Skipped when only the folder is being renamed, since moving
            //    a file onto itself is a collision, not a rename.
            if newBase != folder.baseName {
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
            }

            // 2. The folder. Recorded in `completed` because step 3 follows
            //    it: a rollback has to put the folder back *before* it can
            //    undo the moves in step 1, which reversed order guarantees.
            var newFolderURL = folder.folderURL
            if newBase != currentFolderName {
                let destination = parent.appendingPathComponent(newBase, isDirectory: true)
                guard !operations.fileExists(at: destination) else {
                    throw StorageError.destinationExists(path: destination.path)
                }
                try operations.moveItem(at: folder.folderURL, to: destination)
                completed.append((from: folder.folderURL, to: destination))
                newFolderURL = destination
            }

            // 3. Rendered exports in the shared `Transcripts/` folder, which
            //    is at the library root and therefore unmoved by step 2.
            if newBase != folder.baseName {
                let transcripts = transcriptsFolderURL
                for url in try transcriptExports(forBaseName: folder.baseName) {
                    let remainder = String(url.lastPathComponent.dropFirst(folder.baseName.count))
                    let destination = transcripts.appendingPathComponent(newBase + remainder)
                    guard !operations.fileExists(at: destination) else {
                        throw StorageError.destinationExists(path: destination.path)
                    }
                    try operations.moveItem(at: url, to: destination)
                    completed.append((from: url, to: destination))
                }
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

    /// Moves the entire library — every recording folder, the shared
    /// `Transcripts/` folder, *and* the SwiftData store file beside them — to a
    /// new root, and returns a store pointing at it (spec §Settings: "Storage
    /// folder").
    ///
    /// Nothing here enumerates those three by name: every child of the root
    /// moves, which is why adding `Transcripts/` to the layout needed no
    /// change to this method.
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
