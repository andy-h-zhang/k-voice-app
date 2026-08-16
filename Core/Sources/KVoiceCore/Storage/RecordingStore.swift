import AVFoundation
import Foundation

/// One recording's folder on disk — a *project*: the audio and every transcript
/// rendered from it, together under one name.
///
/// ```
/// <root>/
/// └── 2026-08-13 Standup/                      ← folderURL   (name == baseName)
///     ├── 2026-08-13 Standup Recording.m4a     ← audioURL
///     ├── 2026-08-13 Standup Transcript.md     ← transcriptURL(.markdown)
///     ├── 2026-08-13 Standup Transcript.txt    ← transcriptURL(.plainText)
///     └── transcript.raw.json                  ← verbatim provider response
/// ```
///
/// Rendered transcripts used to live in one shared `Transcripts/` folder at the
/// library root. They do not any more: a recording is a thing you open, and
/// having to visit a second folder to read what was said in it — matching files
/// up by name, with no folder to drag as a unit — was the wrong shape. The
/// price is that `Transcripts/` no longer answers "show me every transcript" in
/// one place; Finder search does that well enough, and the folder-per-project
/// is what a user actually moves, copies and shares.
///
/// The `Recording` / `Transcript` suffixes are why `baseName` is no longer the
/// audio file's stem: everything in the folder is named `<baseName> <role>`, so
/// the role is visible in the filename once the file leaves the folder.
/// `transcript.raw.json` is the exception — a fixed name, because it is the
/// recording's own re-processing input rather than a document anyone reads.
public struct RecordingFolder: Sendable, Equatable, Identifiable {
    public var id: URL { folderURL }

    /// The recording's folder.
    public let folderURL: URL
    /// Filename stem shared by every file in the folder: `YYYY-MM-DD [NAME]`,
    /// the same string as the folder's own name.
    public let baseName: String
    /// The audio file's actual name on disk, extension included.
    ///
    /// Stored rather than derived from `baseName`, because it is not always
    /// `<baseName> Recording.m4a`: a library written before this layout has
    /// `<baseName>.m4a`, and a folder a user renamed in Finder can have
    /// anything at all. Deriving it would make those recordings' audio
    /// unreachable — silently, since the folder would still list.
    public let audioFileName: String

    /// Role suffix on the audio file: `<baseName> Recording.m4a`.
    public static let audioSuffix = "Recording"
    /// Role suffix on rendered transcripts: `<baseName> Transcript.md`.
    public static let transcriptSuffix = "Transcript"

    /// A folder whose audio follows the canonical layout.
    ///
    /// Used when *creating* a recording, where the name is this type's to
    /// choose rather than something to discover.
    public init(folderURL: URL, baseName: String, audioFileExtension: String = "m4a") {
        let ext = audioFileExtension.isEmpty ? "m4a" : audioFileExtension.lowercased()
        self.init(
            folderURL: folderURL,
            baseName: baseName,
            audioFileName: "\(baseName) \(Self.audioSuffix).\(ext)"
        )
    }

    /// A folder whose audio is whatever is actually on disk.
    public init(folderURL: URL, baseName: String, audioFileName: String) {
        self.folderURL = folderURL
        self.baseName = baseName
        self.audioFileName = audioFileName
    }

    /// Extension of the audio file, without the dot.
    public var audioFileExtension: String {
        let ext = (audioFileName as NSString).pathExtension
        return ext.isEmpty ? "m4a" : ext
    }

    /// The recording's audio file.
    public var audioURL: URL {
        folderURL.appendingPathComponent(audioFileName)
    }

    /// Where the audio *should* live under the current layout.
    ///
    /// Differs from ``audioURL`` only on a folder the migration has not
    /// reached yet; that difference is exactly what the migration acts on.
    public var canonicalAudioURL: URL {
        folderURL.appendingPathComponent("\(baseName) \(Self.audioSuffix).\(audioFileExtension)")
    }

    /// The rendered transcript in `format`.
    public func transcriptURL(_ format: ExportFormat) -> URL {
        folderURL.appendingPathComponent(
            "\(baseName) \(Self.transcriptSuffix).\(format.fileExtension)"
        )
    }

    /// Every transcript this recording can have, whether or not it exists yet.
    public var transcriptURLs: [URL] {
        ExportFormat.allCases.map(transcriptURL)
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

    // MARK: - The former transcripts folder

    /// The shared exports folder that libraries written before the
    /// project-folder layout still have.
    ///
    /// Nothing writes here any more — ``LibraryMigration`` empties it into the
    /// recording folders and removes it. The name survives so that
    /// ``recordings()`` keeps skipping it on a library that has not been
    /// migrated yet, and so the migration has one place to read it from.
    public static let legacyTranscriptsFolderName = "Transcripts"

    /// `<root>/Transcripts`, for callers that only have a root URL.
    public static func legacyTranscriptsFolderURL(inLibraryRoot root: URL) -> URL {
        root.appendingPathComponent(legacyTranscriptsFolderName, isDirectory: true)
    }

    /// This library's legacy exports folder, whether or not it exists.
    public var legacyTranscriptsFolderURL: URL {
        Self.legacyTranscriptsFolderURL(inLibraryRoot: rootURL)
    }

    /// The legacy exports belonging to one recording, by its old base name.
    ///
    /// Matches on the `<baseName>.` prefix, so `.md`, `.txt` and `.docx` are
    /// all found in one pass. Returns nothing once the folder is gone, which
    /// is what makes the migration idempotent.
    public func legacyTranscriptExports(forBaseName baseName: String) throws -> [URL] {
        let folder = legacyTranscriptsFolderURL
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
    /// A folder counts as a recording once it holds an audio file. The base
    /// name is the folder's own name — the audio inside is expected to be
    /// `<folder> Recording.<ext>` — but the audio file is *found* rather than
    /// assumed, in three descending preferences, so neither an unmigrated
    /// library nor a folder somebody renamed in Finder drops out of the list:
    ///
    /// 1. `<folder> Recording.<ext>` — the current layout.
    /// 2. `<folder>.<ext>` — the layout before transcripts moved in, where the
    ///    audio was named exactly after its folder.
    /// 3. Any audio file at all, alphabetically — a hand-renamed folder.
    public func recordings(audioFileExtension: String = "m4a") throws -> [RecordingFolder] {
        guard operations.fileExists(at: rootURL) else { return [] }

        let entries = try operations.contentsOfDirectory(at: rootURL)
        let folders: [RecordingFolder] = try entries.compactMap {
            (entry: URL) -> RecordingFolder? in
            guard operations.isDirectory(at: entry) else { return nil }
            // Reserved on an unmigrated library: exports, not a recording. A
            // user dropping an `.m4a` in there should not conjure a phantom
            // recording called "Transcripts".
            guard entry.lastPathComponent != Self.legacyTranscriptsFolderName else { return nil }

            let contents = try operations.contentsOfDirectory(at: entry)
            let audioFiles = contents.filter {
                $0.pathExtension.lowercased() == audioFileExtension.lowercased()
            }

            let folderName = entry.lastPathComponent
            let stem = { (url: URL) in url.deletingPathExtension().lastPathComponent }
            let match = audioFiles.first { stem($0) == "\(folderName) \(RecordingFolder.audioSuffix)" }
                ?? audioFiles.first { stem($0) == folderName }
                ?? audioFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first
            guard let match else { return nil }

            return RecordingFolder(
                folderURL: entry,
                baseName: folderName,
                audioFileName: match.lastPathComponent
            )
        }

        return folders.sorted { $0.folderURL.lastPathComponent < $1.folderURL.lastPathComponent }
    }

    // MARK: - Renaming

    /// Renames a recording: its folder, and every file inside it named after
    /// the old base — the audio and both rendered transcripts.
    ///
    /// Filesystem first, database second (`docs/implementation-plan.md` §3
    /// decision 6): files are what the user sees, so the caller only updates
    /// its records after this returns. If any move fails, the moves already
    /// made are undone and ``StorageError/renameFailed(from:to:reason:rolledBack:)``
    /// reports whether that undo succeeded.
    ///
    /// ## What is *not* renamed
    ///
    /// `transcript.raw.json` has a fixed name, deliberately: it is the
    /// provider's verbatim response, re-processing input rather than a
    /// document, and nothing outside the folder ever refers to it by name.
    ///
    /// This used to also move the recording's exports in the shared
    /// `Transcripts/` folder, in the same transaction, because a stale export
    /// there was indistinguishable from another recording's file. With
    /// transcripts inside the project folder that whole class of collision is
    /// gone — the folder move carries them along by definition, and only the
    /// per-file rename below is left.
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
        var newAudioFileName = folder.audioFileName
        do {
            // 1. Files inside the folder, before the folder itself: their
            //    URLs are only valid while the folder is where we left it.
            //    Skipped when only the folder is being renamed, since moving
            //    a file onto itself is a collision, not a rename.
            if newBase != folder.baseName {
                let contents = try operations.contentsOfDirectory(at: folder.folderURL)
                for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = url.lastPathComponent
                    // Both separators: `<base> Recording.m4a` in the current
                    // layout, `<base>.m4a` in one this migration has not
                    // reached. Renaming a folder must not depend on having
                    // migrated it first.
                    guard name.hasPrefix(folder.baseName + " ")
                        || name.hasPrefix(folder.baseName + ".")
                    else { continue }

                    let remainder = String(name.dropFirst(folder.baseName.count))
                    let destination = folder.folderURL.appendingPathComponent(newBase + remainder)
                    guard !operations.fileExists(at: destination) else {
                        throw StorageError.destinationExists(path: destination.path)
                    }

                    try operations.moveItem(at: url, to: destination)
                    completed.append((from: url, to: destination))
                    if name == folder.audioFileName {
                        newAudioFileName = destination.lastPathComponent
                    }
                }
            }

            // 2. The folder, last, so a rollback unwinds it before the moves
            //    in step 1 — which reversed order guarantees.
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

            return RecordingFolder(
                folderURL: newFolderURL,
                baseName: newBase,
                audioFileName: newAudioFileName
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
