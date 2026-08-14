import Foundation
import KVoiceCore
import SwiftData

/// The app half of Phase 7: turning the rows a user has been editing into the
/// files the spec's §Export describes.
///
/// Every export reads **current database state** — the edited `Utterance.text`
/// and the speaker names as assigned, never `transcript.raw.json`. That is the
/// whole point of edits living in rows: the document a user exports is the
/// document they were just looking at.
enum TranscriptExport {

    /// Builds the export document for a recording.
    ///
    /// Speaker names come from `Utterance.displaySpeakerName`, which is the
    /// same resolution the editor renders and the same one "Unknown Speaker N"
    /// falls out of — so a transcript with an unnamed voice exports with that
    /// label rather than a blank header.
    static func document(
        for recordingID: UUID,
        container: ModelContainer
    ) throws -> TranscriptDocument {
        let context = ModelContext(container)
        guard let recording = try context.recording(id: recordingID) else {
            throw TranscriptEditorError.recordingNotFound
        }

        return TranscriptDocument(recording: recording)
    }

    /// The app-wide default export destination: `<library root>/Transcripts`.
    ///
    /// One folder for every recording's rendered transcript, rather than one
    /// file buried in each recording's folder. A user who wants "the transcript
    /// of Tuesday's standup" opens one place and reads filenames; the File menu
    /// can point at it, and it is the destination for the export menu, the
    /// editor toolbar and drag-out alike, so there is never a question of which
    /// copy is current.
    ///
    /// `Exporter` itself stays destination-agnostic — it writes where it is
    /// told. This function is the whole of the app's opinion.
    static func destination(inLibraryRoot libraryRoot: URL) -> URL {
        RecordingStore.transcriptsFolderURL(inLibraryRoot: libraryRoot)
    }

    /// Writes an export into the shared transcripts folder and returns its URL.
    ///
    /// The folder is created on demand by `Exporter`, so a library that has
    /// never exported anything does not grow an empty folder. `Exporter`'s
    /// default `.overwrite` policy means re-exporting after an edit refreshes
    /// the file instead of piling up "Standup 2.md", "Standup 3.md" — safe in a
    /// shared folder because `RecordingStore.rename` keeps one base name per
    /// recording there.
    @discardableResult
    static func export(
        recordingID: UUID,
        container: ModelContainer,
        libraryRoot: URL,
        format: ExportFormat
    ) throws -> URL {
        let document = try document(for: recordingID, container: container)
        return try Exporter.export(document, as: format, to: destination(inLibraryRoot: libraryRoot))
    }
}

// MARK: - Drag-out

/// File drag-out (spec §Export: "drag-out of both audio and transcript").
enum FileDrag {

    /// An item provider that vends a real file URL, so a drop into Finder,
    /// Mail, or Slack copies the file itself rather than a path string.
    ///
    /// Returns an empty provider when the file is missing, which makes the drag
    /// a no-op instead of a dangling promise the receiver would fail on.
    static func provider(for url: URL) -> NSItemProvider {
        guard FileManager.default.fileExists(atPath: url.path),
            let provider = NSItemProvider(contentsOf: url)
        else { return NSItemProvider() }

        provider.suggestedName = url.lastPathComponent
        return provider
    }

    /// Exports the transcript on demand and vends the file that was just
    /// written.
    ///
    /// Synchronous because `onDrag` is: rendering a transcript is string
    /// building plus one atomic write (a stored-entry zip, for `.docx`), which
    /// is microseconds for a meeting-sized document. The export lands in the
    /// shared transcripts folder as usual, so a dragged-out transcript is also
    /// a transcript the user now has on disk.
    static func transcriptProvider(
        recordingID: UUID,
        container: ModelContainer,
        libraryRoot: URL,
        format: ExportFormat
    ) -> NSItemProvider {
        guard let url = try? TranscriptExport.export(
            recordingID: recordingID,
            container: container,
            libraryRoot: libraryRoot,
            format: format
        ) else { return NSItemProvider() }

        return provider(for: url)
    }
}
