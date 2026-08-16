import Foundation
import KVoiceCore
import SwiftData

/// Keeps each recording's transcript files current.
///
/// Every export reads **current database state** — the edited `Utterance.text`
/// and the speaker names as assigned, never `transcript.raw.json`. That is the
/// whole point of edits living in rows: the document on disk is the document
/// the user was just looking at.
///
/// ## Why both formats, always
///
/// There is no default-format setting any more. A transcript is not something
/// a user asks for and receives once — it is part of what a recording *is*, so
/// both renderings sit in the folder from the moment transcription finishes and
/// are rewritten whenever the transcript changes. Markdown for reading and for
/// anything that understands it; plain text for everything that does not.
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

    /// Rewrites every transcript file for a recording, and returns their URLs.
    ///
    /// Called after transcription lands and after every edit that changes what
    /// a transcript says — text, speaker assignment, merge, clear. Overwrites
    /// in place, because these files are renderings of database state rather
    /// than documents with their own history.
    ///
    /// A recording with no utterances writes nothing: an empty transcript file
    /// is worse than no file, because it looks like a transcription that
    /// produced silence rather than one that has not run.
    @discardableResult
    static func sync(
        recordingID: UUID,
        container: ModelContainer,
        libraryRoot: URL
    ) throws -> [URL] {
        let context = ModelContext(container)
        guard let recording = try context.recording(id: recordingID) else {
            throw TranscriptEditorError.recordingNotFound
        }
        guard !recording.utterances.isEmpty else { return [] }

        let document = TranscriptDocument(recording: recording)
        let folder = recording.folder(inRoot: libraryRoot)

        return try ExportFormat.allCases.map { format in
            try Exporter.write(document, as: format, to: folder.transcriptURL(format))
        }
    }

    /// The transcript files that exist on disk for a recording, if any.
    ///
    /// Used by the drag chips, which now vend real files rather than exporting
    /// one on the fly — the files are always there once a transcript is.
    static func existingFiles(
        recordingID: UUID,
        container: ModelContainer,
        libraryRoot: URL
    ) -> [ExportFormat: URL] {
        let context = ModelContext(container)
        guard let recording = try? context.recording(id: recordingID) else { return [:] }
        let folder = recording.folder(inRoot: libraryRoot)

        var found: [ExportFormat: URL] = [:]
        for format in ExportFormat.allCases {
            let url = folder.transcriptURL(format)
            if FileManager.default.fileExists(atPath: url.path) { found[format] = url }
        }
        return found
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
    ///
    /// Every drag goes through here now. It used to be that dragging a
    /// transcript *exported* one first, because no transcript file existed
    /// until someone asked for it; with both formats maintained in the project
    /// folder there is always a real file to hand over.
    static func provider(for url: URL) -> NSItemProvider {
        guard FileManager.default.fileExists(atPath: url.path),
            let provider = NSItemProvider(contentsOf: url)
        else { return NSItemProvider() }

        provider.suggestedName = url.lastPathComponent
        return provider
    }
}
