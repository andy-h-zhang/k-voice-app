import Foundation
import KVoiceCore
import SwiftData

/// Runs ``LibraryMigration`` once, then points the database at what it did.
///
/// Core moves the files; this moves the rows. They are separate because the
/// migration is a filesystem operation that has to be testable without a store,
/// and because the order matters: **files first, database second**, the same
/// rule renaming follows (`docs/implementation-plan.md` §3 decision 6). Files
/// are what the user sees, so a crash between the two leaves a library that
/// looks right in Finder and reconciles itself on the next launch, rather than
/// rows pointing confidently at folders that are not there.
///
/// Runs synchronously on the main actor during `AppServices.init`, which is
/// deliberate: it is one pass on first launch only, and there is nothing
/// coherent to show while it is half-done — every screen in the app reads the
/// library it is rewriting.
@MainActor
enum LibraryLayoutMigrator {

    struct Outcome {
        /// A message worth putting in front of the user, or nil.
        var warning: String?
        /// Whether anything on disk actually moved.
        var didMigrate = false
    }

    /// Migrates the library if it has not been migrated already.
    ///
    /// The version is only bumped on a **clean** run. A library where one
    /// folder failed stays marked unmigrated, so the next launch tries that
    /// folder again — the migration is idempotent, so the ones that already
    /// went through cost nothing to walk a second time.
    @discardableResult
    static func runIfNeeded(
        settings: SettingsStore,
        store: RecordingStore,
        container: ModelContainer
    ) -> Outcome {
        guard settings.libraryLayoutVersion < SettingsStore.currentLibraryLayoutVersion else {
            return Outcome()
        }

        let report: LibraryMigration.Report
        do {
            report = try LibraryMigration(store: store).run()
        } catch {
            return Outcome(
                warning: "Your recordings could not be reorganized into project folders: "
                    + "\(LibraryModel.describe(error)) Nothing was changed; the app will try "
                    + "again next launch."
            )
        }

        applyToDatabase(report, container: container)

        if report.failures.isEmpty {
            settings.libraryLayoutVersion = SettingsStore.currentLibraryLayoutVersion
        }

        return Outcome(warning: warning(for: report), didMigrate: report.didAnything)
    }

    /// Repoints each migrated recording's row at its new folder.
    ///
    /// Matched by the *old* folder name, which is the only handle shared by a
    /// row and the folder it came from — the row's own `id` means nothing on
    /// disk. A row whose folder was not part of the migration is left alone.
    private static func applyToDatabase(
        _ report: LibraryMigration.Report,
        container: ModelContainer
    ) {
        let renames = report.migrated
        guard !renames.isEmpty else { return }

        do {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let recordings = try context.fetch(FetchDescriptor<Recording>())
            var byFolderName: [String: Recording] = [:]
            for recording in recordings { byFolderName[recording.folderName] = recording }

            for rename in renames {
                guard let recording = byFolderName[rename.oldFolderName] else { continue }

                let ext = (recording.audioFileName as NSString).pathExtension
                recording.folderName = rename.newFolderName
                recording.title = rename.newFolderName
                recording.audioFileName =
                    "\(rename.newFolderName) \(RecordingFolder.audioSuffix)"
                    + ".\(ext.isEmpty ? "m4a" : ext)"
            }

            if context.hasChanges { try context.save() }
        } catch {
            // The files are already where they belong, and `RecordingStore`
            // finds recordings by walking the folder rather than by trusting
            // the database, so a failure here is recoverable rather than
            // destructive. Staying unmigrated means the next launch retries.
        }
    }

    private static func warning(for report: LibraryMigration.Report) -> String? {
        var parts: [String] = []

        if !report.failures.isEmpty {
            let names = report.failures.map(\.oldFolderName).sorted().joined(separator: ", ")
            parts.append(
                "\(report.failures.count) recording\(report.failures.count == 1 ? "" : "s") "
                    + "could not be reorganized into project folders (\(names)). They are "
                    + "unchanged and still playable; the app will try again next launch."
            )
        }

        if !report.orphanedExports.isEmpty {
            parts.append(
                "\(report.orphanedExports.count) transcript"
                    + "\(report.orphanedExports.count == 1 ? "" : "s") in the old Transcripts "
                    + "folder had no matching recording, so they were left there for you to "
                    + "look at rather than moved or deleted."
            )
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
