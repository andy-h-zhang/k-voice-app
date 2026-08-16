import Foundation

/// The block structure shared by the Markdown and plain-text exports.
///
/// The two formats are the same document — a title, a date, then one line per
/// utterance — and differ only in whether the speaker's name carries Markdown's
/// emphasis markers. Keeping the assembly in one place is what makes "same
/// structure, no formatting" literally true rather than a claim two renderers
/// have to keep in sync.
///
/// ```
/// **Alice** [00:00:05]: Morning, everyone.
///
/// **Bob** [00:00:41]: Thursday works for me.
/// ```
///
/// ## One line per utterance, not per turn
///
/// The speaker used to be a heading with its paragraphs beneath it, which cost
/// four lines to say one sentence and made a transcript hard to skim or to
/// quote a single line out of. Attribution now sits inline, and each utterance
/// carries its own timestamp — so a run by one speaker repeats their name
/// rather than merging, and every line can be pointed at.
///
/// Turn *grouping* still exists and is unchanged: the editor renders turns, and
/// maps paragraph *i* of a turn back to the *i*-th surviving utterance. This
/// walks those same paragraphs, which is why each one carries its own start.
///
/// Blocks are separated by a blank line and the file ends with a newline.
/// Speaker names and transcript text are emitted verbatim: escaping Markdown
/// metacharacters would corrupt a transcript that legitimately contains `*`
/// or `_`, and these documents are read as prose, not executed.
enum TranscriptTextLayout {

    /// - Parameters:
    ///   - titlePrefix: Prepended to the title line (`"# "` in Markdown).
    ///   - speakerEmphasis: Wrapped around the speaker's name (`"**"` in
    ///     Markdown, empty in plain text, where literal asterisks would be
    ///     markup a reader has to look past rather than bold text).
    static func render(
        _ document: TranscriptDocument,
        timeZone: TimeZone,
        titlePrefix: String,
        speakerEmphasis: String
    ) -> String {
        var blocks: [String] = [
            titlePrefix + document.displayTitle,
            TimestampFormatter.documentDate(document.date, timeZone: timeZone)
        ]

        for turn in document.turns {
            let speaker = speakerEmphasis + turn.speaker + speakerEmphasis
            for paragraph in turn.paragraphs {
                let timestamp = TimestampFormatter.bracketedClockTime(
                    milliseconds: paragraph.startMs
                )
                blocks.append("\(speaker) \(timestamp): \(paragraph.text)")
            }
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }
}
