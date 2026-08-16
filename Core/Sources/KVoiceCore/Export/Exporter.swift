import Foundation

/// Renders a ``TranscriptDocument`` to bytes, and writes it where it is told.
///
/// ## Why this no longer names files
///
/// It used to: exports landed in one shared `Transcripts/` folder and took
/// their name from the recording's title, which is what kept two recordings
/// from colliding there. That folder is gone — every transcript now lives in
/// its own recording's folder as `<base> Transcript.md` / `.txt` — so the name
/// is a property of the *recording's layout*, which is ``RecordingFolder``'s
/// job and not this type's. Callers pass the exact URL.
///
/// Writes are unconditional overwrites. A transcript file is a rendering of
/// current database state, regenerated whenever that state changes, so the
/// previous rendering is never worth keeping and a ` 2` suffix would only
/// produce litter that goes stale the moment it is written.
public enum Exporter {

    // MARK: - Rendering

    /// Renders `document` to bytes without touching the filesystem.
    ///
    /// Useful for drag-out and clipboard paths that never write a file.
    public static func data(
        for document: TranscriptDocument,
        format: ExportFormat,
        timeZone: TimeZone = .current
    ) throws -> Data {
        switch format {
        case .markdown:
            return Data(MarkdownRenderer.render(document, timeZone: timeZone).utf8)
        case .plainText:
            return Data(PlainTextRenderer.render(document, timeZone: timeZone).utf8)
        }
    }

    // MARK: - Writing

    /// Writes `document` to exactly `fileURL` and returns it.
    ///
    /// The enclosing folder is created if missing. The write is atomic, so a
    /// failure part-way leaves the previous transcript intact rather than
    /// truncated — which matters more now than it did: this runs on a debounce
    /// while the user is typing, not once when they ask for a file.
    ///
    /// - Throws: ``ExportError``.
    @discardableResult
    public static func write(
        _ document: TranscriptDocument,
        as format: ExportFormat,
        to fileURL: URL,
        timeZone: TimeZone = .current
    ) throws -> URL {
        try prepare(fileURL.deletingLastPathComponent())

        let contents = try data(for: document, format: format, timeZone: timeZone)
        do {
            try contents.write(to: fileURL, options: .atomic)
        } catch {
            throw ExportError.writeFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }

        return fileURL
    }

    /// Ensures `folder` exists and is a directory.
    private static func prepare(_ folder: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ExportError.destinationNotADirectory(path: folder.path)
            }
            return
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ExportError.destinationUnavailable(
                path: folder.path,
                reason: error.localizedDescription
            )
        }
    }
}
