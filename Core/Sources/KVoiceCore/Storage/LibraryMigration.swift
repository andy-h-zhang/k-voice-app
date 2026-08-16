import Foundation

/// Moves a library from the pre-project layout to the current one.
///
/// ```
/// before                                  after
/// 2026-08-14 09.15 Recording/             2026-08-14/
///   2026-08-14 09.15 Recording.m4a          2026-08-14 Recording.m4a
/// Transcripts/                              2026-08-14 Transcript.md
///   2026-08-14 09.15 Recording.md
/// ```
///
/// Three things change per recording: the folder loses its ` HH.MM` time and
/// its trailing ` Recording`, the audio gains a ` Recording` role suffix, and
/// the recording's exports come home from the shared `Transcripts/` folder as
/// `<base> Transcript.<ext>`.
///
/// ## Safety
///
/// This rewrites files a user cannot get back, so it is built to be dull:
///
/// - **Per-folder transactions.** Each recording's moves succeed or unwind on
///   their own. One unmigratable folder — a permission problem, a name that
///   collides in a way the suffixer cannot resolve — is reported and skipped,
///   never a reason to leave the other forty half-done.
/// - **Idempotent.** Every step is skipped when its result is already true, so
///   a run interrupted by a crash or a quit is finished by the next one, and a
///   second run over a migrated library does nothing at all.
/// - **Never deletes.** `Transcripts/` is removed only when empty, and a
///   `.docx` from a version that still exported Word is *moved* into the
///   project folder rather than dropped. The app no longer writes them; that
///   is not a reason to destroy the ones a user already has.
/// - **Nothing is trusted to be well-formed.** A folder with no audio, a name
///   that does not start with a date, an export whose recording is gone — each
///   has a defined outcome below rather than an assumption.
public struct LibraryMigration: Sendable {

    /// What happened to one recording folder.
    public struct FolderOutcome: Sendable, Equatable {
        public let oldFolderName: String
        public let newFolderName: String
        /// Nil when the folder migrated cleanly.
        public let failure: String?

        public var didFail: Bool { failure != nil }
        public var didChange: Bool { oldFolderName != newFolderName && failure == nil }
    }

    /// What happened overall. Returned rather than logged so the app can
    /// surface a failure instead of a migration silently doing nothing.
    public struct Report: Sendable, Equatable {
        public var folders: [FolderOutcome] = []
        public var transcriptsFolderRemoved = false
        /// Legacy exports whose recording folder no longer exists. Left where
        /// they are — deleting a user's transcript because its audio was
        /// removed would be the worst possible reading of "tidy up".
        public var orphanedExports: [String] = []

        public var migrated: [FolderOutcome] { folders.filter(\.didChange) }
        public var failures: [FolderOutcome] { folders.filter(\.didFail) }
        public var didAnything: Bool {
            !migrated.isEmpty || transcriptsFolderRemoved || !failures.isEmpty
        }
    }

    private let store: RecordingStore
    private let operations: FileOperations

    public init(store: RecordingStore, operations: FileOperations = SystemFileOperations()) {
        self.store = store
        self.operations = operations
    }

    // MARK: - Naming

    /// The project name a legacy folder name becomes.
    ///
    /// `2026-08-14 09.15 Recording` → `2026-08-14`. Two rules, applied in that
    /// order, and only ever to a name that starts with a `YYYY-MM-DD` date:
    /// drop a trailing ` Recording`, then drop a ` HH.MM` (or ` HH-MM-SS`,
    /// which `speakerlab record` produced) immediately after the date.
    ///
    /// A name that does not start with a date is returned untouched. Those are
    /// user-chosen titles — "Standup", "Q3 planning" — and inventing a date for
    /// them would be worse than leaving them alone; the date is only *known*
    /// for names that already carry one.
    public static func projectName(fromLegacyFolderName name: String) -> String {
        var result = name

        if result.hasSuffix(" \(RecordingFolder.audioSuffix)") {
            result = String(result.dropLast(RecordingFolder.audioSuffix.count + 1))
        }

        guard let date = leadingDate(of: result) else { return name }

        let remainder = result.dropFirst(date.count)
            .trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return date }

        // Only a bare clock time is dropped. "2026-08-14 Weekly Sync" keeps
        // its name; "2026-08-14 09.15" becomes "2026-08-14".
        let firstToken = remainder.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard isClockTime(firstToken) else { return result }

        let afterTime = remainder.dropFirst(firstToken.count).trimmingCharacters(in: .whitespaces)
        return afterTime.isEmpty ? date : "\(date) \(afterTime)"
    }

    /// `YYYY-MM-DD` at the start of `name`, if there is one.
    private static func leadingDate(of name: String) -> String? {
        guard name.count >= 10 else { return nil }
        let candidate = String(name.prefix(10))
        let parts = candidate.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
            parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }
        // A date must end the component: "2026-08-1499" is not one.
        let next = name.dropFirst(10).first
        guard next == nil || next == " " else { return nil }
        return candidate
    }

    /// `09.15`, `09-15`, `09.15.30` — digits separated by dots or dashes.
    private static func isClockTime(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let fields = token.split(whereSeparator: { $0 == "." || $0 == "-" })
        guard fields.count >= 2, fields.count <= 3 else { return false }
        return fields.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isNumber) }
    }

    // MARK: - Running

    /// Migrates every recording folder, then retires `Transcripts/`.
    ///
    /// Safe to call on an already-migrated library: it walks the same folders,
    /// finds every step already satisfied, and reports nothing changed.
    public func run() throws -> Report {
        var report = Report()
        guard operations.fileExists(at: store.rootURL) else { return report }

        // Names claimed as we go, so two folders collapsing onto one date get
        // `2026-08-14` and `2026-08-14 2` rather than racing for the same name.
        // Seeded with every current folder name: a folder later in the list
        // that already holds the name we want must not be trampled.
        var taken = Set(
            try operations.contentsOfDirectory(at: store.rootURL)
                .filter { operations.isDirectory(at: $0) }
                .map(\.lastPathComponent)
        )

        for folder in try store.recordings() {
            let outcome = migrate(folder, taken: &taken)
            report.folders.append(outcome)
        }

        retireTranscriptsFolder(into: &report)
        return report
    }

    // MARK: - One folder

    private func migrate(
        _ folder: RecordingFolder,
        taken: inout Set<String>
    ) -> FolderOutcome {
        let oldName = folder.folderURL.lastPathComponent
        let desired = FilenameSanitizer.sanitize(Self.projectName(fromLegacyFolderName: oldName))

        // Its own name is not a collision with itself.
        taken.remove(oldName)
        let newName = FilenameSanitizer.uniqueName(for: desired) { taken.contains($0) }
        taken.insert(newName)

        var completed: [(from: URL, to: URL)] = []
        do {
            // 1. Legacy exports in, before anything moves: they are addressed
            //    by the *old* base name, which stops being true in step 3.
            let folderURL = folder.folderURL
            for export in try store.legacyTranscriptExports(forBaseName: folder.baseName) {
                let ext = export.pathExtension
                let destination = folderURL.appendingPathComponent(
                    "\(folder.baseName) \(RecordingFolder.transcriptSuffix).\(ext)"
                )
                guard !operations.fileExists(at: destination) else { continue }
                try operations.moveItem(at: export, to: destination)
                completed.append((from: export, to: destination))
            }

            // 2. The audio gains its role suffix, while the folder is still
            //    where `folder.audioURL` says it is.
            if folder.audioURL != folder.canonicalAudioURL,
                operations.fileExists(at: folder.audioURL),
                !operations.fileExists(at: folder.canonicalAudioURL) {
                try operations.moveItem(at: folder.audioURL, to: folder.canonicalAudioURL)
                completed.append((from: folder.audioURL, to: folder.canonicalAudioURL))
            }

            // 3. Every file named after the old base follows the new one.
            if newName != folder.baseName {
                for url in try operations.contentsOfDirectory(at: folderURL)
                    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = url.lastPathComponent
                    guard name.hasPrefix(folder.baseName + " ")
                        || name.hasPrefix(folder.baseName + ".")
                    else { continue }

                    let remainder = String(name.dropFirst(folder.baseName.count))
                    let destination = folderURL.appendingPathComponent(newName + remainder)
                    guard !operations.fileExists(at: destination) else {
                        throw StorageError.destinationExists(path: destination.path)
                    }
                    try operations.moveItem(at: url, to: destination)
                    completed.append((from: url, to: destination))
                }

                // 4. The folder itself, last, so a rollback unwinds it first.
                let destination = store.rootURL.appendingPathComponent(newName, isDirectory: true)
                guard !operations.fileExists(at: destination) else {
                    throw StorageError.destinationExists(path: destination.path)
                }
                try operations.moveItem(at: folderURL, to: destination)
                completed.append((from: folderURL, to: destination))
            }

            return FolderOutcome(oldFolderName: oldName, newFolderName: newName, failure: nil)
        } catch {
            let rolledBack = rollBack(completed)
            taken.remove(newName)
            taken.insert(oldName)

            let reason = (error as? StorageError)?.errorDescription ?? error.localizedDescription
            return FolderOutcome(
                oldFolderName: oldName,
                newFolderName: oldName,
                failure: rolledBack
                    ? reason
                    : "\(reason) The folder was left part-migrated and needs a look in Finder."
            )
        }
    }

    // MARK: - The shared folder

    /// Removes `Transcripts/` once it is empty, and reports whatever is left.
    private func retireTranscriptsFolder(into report: inout Report) {
        let folder = store.legacyTranscriptsFolderURL
        guard operations.fileExists(at: folder), operations.isDirectory(at: folder) else { return }

        let remaining = (try? operations.contentsOfDirectory(at: folder)) ?? []
        // `.DS_Store` is Finder's, not the user's, and would otherwise keep an
        // empty folder alive forever.
        let meaningful = remaining.filter { $0.lastPathComponent != ".DS_Store" }

        guard meaningful.isEmpty else {
            report.orphanedExports = meaningful.map(\.lastPathComponent).sorted()
            return
        }

        do {
            try FileManager.default.removeItem(at: folder)
            report.transcriptsFolderRemoved = true
        } catch {
            // An un-removable empty folder is cosmetic. Nothing writes to it.
        }
    }

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
}
