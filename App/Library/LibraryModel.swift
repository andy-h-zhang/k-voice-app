import Foundation
import KVoiceCore
import Observation
import SwiftData

/// One row of the library list.
///
/// Built from a `RecordingSnapshot` — the `Sendable` copy Core already hands
/// out — rather than from a live `Recording`, so nothing in the view layer
/// holds a `PersistentModel` whose context has moved on.
struct LibraryRow: Identifiable, Equatable {

    let snapshot: RecordingSnapshot
    /// The recording's folder on disk, for Finder and Trash.
    let folderURL: URL
    /// Whether a finished response is on disk, which is what makes
    /// "Re-process" meaningful (and free).
    let hasRawTranscript: Bool

    var id: UUID { snapshot.id }
    var title: String { snapshot.title }
    var createdAt: Date { snapshot.createdAt }
    var durationSec: Double { snapshot.durationSec }
    var participantNames: [String] { snapshot.participantNames }
}

/// The recording library: what the list shows, and every mutation it offers.
///
/// ## Fresh context per operation
///
/// Every read and every write opens its own `ModelContext` and lets it go.
/// Contexts are cheap, and a job running in the background writes through a
/// *different* context — so a long-lived one here could serve rows that were
/// current ten minutes ago. Re-fetching is both simpler and always right.
@MainActor
@Observable
final class LibraryModel {

    private(set) var rows: [LibraryRow] = []

    /// Surfaced to the user as an alert; set by a failed rename or delete.
    var errorMessage: String?

    // No `selection` here. Which recording is on screen is a fact about the
    // *window* — and one the tab bar can also change — so it lives in
    // ``NavigationModel`` alongside the tabs it is mutually exclusive with. A
    // copy here would be a second source of truth for the same question.

    private let container: ModelContainer
    private let store: RecordingStore

    private var root: URL { store.rootURL }

    init(container: ModelContainer, store: RecordingStore) {
        self.container = container
        self.store = store
    }

    // MARK: - Reading

    /// Re-reads every row, newest first.
    func reload() {
        do {
            let context = ModelContext(container)
            let recordings = try context.fetch(
                FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            )
            rows = recordings.map { recording in
                let folder = recording.folder(inRoot: root)
                // A stat, not a parse: `rawResponseFile` is only set once a
                // *completed* body has landed, so its presence plus the file
                // still being there is the whole precondition for re-process.
                let rawURL = recording.rawResponseURL(inRoot: root)
                let hasRaw = rawURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                return LibraryRow(
                    snapshot: RecordingSnapshot(recording),
                    folderURL: folder.folderURL,
                    hasRawTranscript: hasRaw
                )
            }
        } catch {
            errorMessage = "Could not read the recording library: \(Self.describe(error))"
        }
    }

    func row(id: UUID) -> LibraryRow? {
        rows.first { $0.id == id }
    }

    // MARK: - Creating

    /// Adds a finished recording to the library.
    ///
    /// The title is the folder's base name, not the name that was requested:
    /// `RecordingStore` may have added a collision suffix, and the library
    /// must show what Finder shows.
    @discardableResult
    func insert(
        folder: RecordingFolder,
        duration: TimeInterval,
        createdAt: Date
    ) throws -> UUID {
        let context = ModelContext(container)
        let recording = Recording(
            title: folder.baseName,
            folderName: folder.folderURL.lastPathComponent,
            audioFileName: folder.audioURL.lastPathComponent,
            createdAt: createdAt,
            durationSec: duration,
            status: .recorded
        )
        context.insert(recording)
        try context.save()

        let id = recording.id
        reload()
        // Deliberately does not select the new row: finishing a recording leaves
        // you on the record screen, ready to start another, and the "Saved …"
        // banner is what offers to open it.
        return id
    }

    // MARK: - Renaming

    /// Renames a recording on disk, then in the database.
    ///
    /// Filesystem first (plan §3 decision 6): `RecordingStore.rename` moves the
    /// folder and every file inside it named after the old base — the audio and
    /// both transcripts — rolling back if any step fails. Only once that has
    /// succeeded does the row change, so Finder and
    /// the library can never disagree.
    func rename(id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let context = ModelContext(container)
            guard let recording = try context.recording(id: id) else { return }
            guard trimmed != recording.title || trimmed != recording.folderName else { return }

            let renamed = try store.rename(recording.folder(inRoot: root), to: trimmed)

            recording.title = renamed.baseName
            recording.folderName = renamed.folderURL.lastPathComponent
            recording.audioFileName = renamed.audioURL.lastPathComponent
            try context.save()

            reload()
        } catch {
            errorMessage = "Could not rename the recording: \(Self.describe(error))"
        }
    }

    // MARK: - Deleting

    /// Moves the recording's folder to the Trash, and removes its row.
    ///
    /// The Trash rather than an unlink, because the folder holds the only copy
    /// of the audio — a misclick has to be recoverable. It now also holds the
    /// only copy of the transcripts, which makes that doubly true, and makes
    /// the delete a single move: this used to need a second pass over the
    /// shared `Transcripts/` folder, and a transcript orphaned by a failure in
    /// that pass was indistinguishable from another recording's.
    func moveToTrash(id: UUID) {
        do {
            let context = ModelContext(container)
            guard let recording = try context.recording(id: id) else { return }

            // One folder holds the audio and both transcripts, so trashing it
            // takes the whole recording. This used to need a second pass over
            // the shared `Transcripts/` folder to catch the exports.
            let folderURL = recording.folder(inRoot: root).folderURL
            if FileManager.default.fileExists(atPath: folderURL.path) {
                try FileManager.default.trashItem(at: folderURL, resultingItemURL: nil)
            }

            context.delete(recording)
            try context.save()

            reload()
        } catch {
            errorMessage = "Could not move the recording to the Trash: \(Self.describe(error))"
        }
    }

    // MARK: - Finder

    func revealInFinder(id: UUID) {
        guard let row = row(id: id) else { return }
        FinderIntegration.reveal(row.folderURL)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
