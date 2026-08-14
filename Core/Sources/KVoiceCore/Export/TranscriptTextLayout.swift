import Foundation

/// The block structure shared by the Markdown and plain-text exports.
///
/// The two formats are the same document — title, date, then `Speaker —
/// [hh:mm:ss]` headers followed by paragraphs (`docs/spec.md` §Export) — and
/// differ only in whether headings carry Markdown's `#` markers. Keeping the
/// assembly in one place is what makes "same structure, no formatting"
/// literally true rather than a claim two renderers have to keep in sync.
///
/// Blocks are separated by a blank line and the file ends with a newline.
/// Speaker names and transcript text are emitted verbatim: escaping Markdown
/// metacharacters would corrupt a transcript that legitimately contains `*`
/// or `_`, and these documents are read as prose, not executed.
enum TranscriptTextLayout {

    /// - Parameters:
    ///   - titlePrefix: Prepended to the title line (`"# "` in Markdown).
    ///   - speakerPrefix: Prepended to each turn header (`"## "` in Markdown).
    static func render(
        _ document: TranscriptDocument,
        timeZone: TimeZone,
        titlePrefix: String,
        speakerPrefix: String
    ) -> String {
        var blocks: [String] = [
            titlePrefix + document.displayTitle,
            TimestampFormatter.documentDate(document.date, timeZone: timeZone)
        ]

        for turn in document.turns {
            let timestamp = TimestampFormatter.bracketedClockTime(milliseconds: turn.startMs)
            blocks.append("\(speakerPrefix)\(turn.speaker) — \(timestamp)")
            blocks.append(contentsOf: turn.paragraphs)
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }
}
