import Foundation

/// Renders a ``TranscriptDocument`` as plain text.
///
/// Structurally identical to the Markdown export — title, date, `Speaker —
/// [hh:mm:ss]` headers, blank-line-separated paragraphs — with no markup at
/// all, per `docs/spec.md` §Export.
///
/// ```text
/// Weekly sync
///
/// 2026-08-13 14:30
///
/// Alice — [00:00:05]
///
/// Morning, everyone.
/// ```
public enum PlainTextRenderer {

    /// - Parameter timeZone: Zone for the header date. Defaults to the
    ///   caller's.
    public static func render(_ document: TranscriptDocument, timeZone: TimeZone = .current) -> String {
        TranscriptTextLayout.render(
            document,
            timeZone: timeZone,
            titlePrefix: "",
            speakerPrefix: ""
        )
    }
}
