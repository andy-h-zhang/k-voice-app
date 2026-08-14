import Foundation

/// Writes a ``TranscriptDocument`` to disk in any supported format.
///
/// The one entry point the app needs: pick a format, pick a folder, get back
/// the URL of the file that was written — ready to reveal in Finder or hand to
/// a drag-out provider.
///
/// Filenames follow the recording title (`docs/spec.md` §Export), sanitized by
/// ``FilenameSanitizer`` — the same function that names the recording's folder
/// and `.m4a`, so an export sits beside its audio under a matching name.
public enum Exporter {

    /// What to do when the destination already holds a file of that name.
    public enum CollisionPolicy: Sendable {
        /// Replace it. The default: an export is a regenerated artifact of the
        /// transcript, and re-exporting into the recording's own folder should
        /// refresh the file rather than pile up ` 2`, ` 3` copies.
        case overwrite
        /// Keep both, adding a ` 2`, ` 3`, … suffix. For exports into a folder
        /// the app does not own, where an existing file may be unrelated.
        case uniqueSuffix
    }

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
        case .word:
            return try DocxRenderer.render(document, timeZone: timeZone)
        }
    }

    // MARK: - Writing

    /// Writes `document` into `folder` and returns the file's URL.
    ///
    /// The folder is created if missing. The write is atomic, so a failure
    /// part-way leaves any previous export intact rather than truncated.
    ///
    /// - Throws: ``ExportError``.
    @discardableResult
    public static func export(
        _ document: TranscriptDocument,
        as format: ExportFormat,
        to folder: URL,
        collision: CollisionPolicy = .overwrite,
        timeZone: TimeZone = .current
    ) throws -> URL {
        try prepare(folder)

        let destination = destinationURL(
            for: document.title,
            format: format,
            in: folder,
            collision: collision
        )
        let contents = try data(for: document, format: format, timeZone: timeZone)

        do {
            try contents.write(to: destination, options: .atomic)
        } catch {
            throw ExportError.writeFailed(
                path: destination.path,
                reason: error.localizedDescription
            )
        }

        return destination
    }

    // MARK: - Naming

    /// The filename a title exports to: sanitized title plus extension.
    public static func fileName(for title: String, format: ExportFormat) -> String {
        "\(FilenameSanitizer.sanitize(title)).\(format.fileExtension)"
    }

    private static func destinationURL(
        for title: String,
        format: ExportFormat,
        in folder: URL,
        collision: CollisionPolicy
    ) -> URL {
        let base = FilenameSanitizer.sanitize(title)

        switch collision {
        case .overwrite:
            return url(folder: folder, base: base, format: format)
        case .uniqueSuffix:
            let unique = FilenameSanitizer.uniqueName(for: base) { candidate in
                FileManager.default.fileExists(
                    atPath: url(folder: folder, base: candidate, format: format).path
                )
            }
            return url(folder: folder, base: unique, format: format)
        }
    }

    private static func url(folder: URL, base: String, format: ExportFormat) -> URL {
        folder.appendingPathComponent("\(base).\(format.fileExtension)", isDirectory: false)
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
