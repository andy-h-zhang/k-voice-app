import Foundation

/// Renders a ``TranscriptDocument`` as Markdown.
///
/// The format the spec asks for (`docs/spec.md` §Export): `## Speaker —
/// [hh:mm:ss]` turn headers, each followed by blank-line-separated paragraphs,
/// under a `#` title and the recording date.
///
/// ```markdown
/// # Weekly sync
///
/// 2026-08-13 14:30
///
/// ## Alice — [00:00:05]
///
/// Morning, everyone.
///
/// ## Bob — [00:01:12]
///
/// Morning.
/// ```
public enum MarkdownRenderer {

    /// - Parameter timeZone: Zone for the header date. Defaults to the
    ///   caller's.
    public static func render(_ document: TranscriptDocument, timeZone: TimeZone = .current) -> String {
        TranscriptTextLayout.render(
            document,
            timeZone: timeZone,
            titlePrefix: "# ",
            speakerPrefix: "## "
        )
    }
}
