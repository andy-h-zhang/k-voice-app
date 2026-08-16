import Foundation

/// A transcript in the shape the exporters render: a title, a date, and
/// speaker turns.
///
/// This is deliberately independent of both the UI and the database. The
/// persistence layer's `Utterance` rows carry diarized speaker letters,
/// per-recording speaker slots and edit state; none of that belongs in a
/// renderer. The app resolves speakers to display names, hands over
/// ``TranscriptDocument/Utterance`` values, and the grouping here produces the
/// turns that Markdown, plain text and `.docx` all share.
///
/// The same grouping backs the Phase-5 transcript editor, which shows turns
/// rather than raw utterances (`docs/implementation-plan.md` §Phase 5) — hence
/// ``turns(from:unknownSpeakerLabel:)`` being a standalone, separately tested
/// function rather than something buried in a renderer.
public struct TranscriptDocument: Equatable, Sendable {

    // MARK: - Input

    /// One utterance as the caller has it: a speaker display name already
    /// resolved, a start offset, and the (possibly user-edited) text.
    ///
    /// A lightweight value on purpose — callers map their own rows onto it, so
    /// nothing here depends on the storage layer.
    public struct Utterance: Equatable, Sendable {
        /// Display name of the speaker, e.g. `"Alice"` or `"Unknown Speaker 2"`.
        /// Blank names fall back to the unknown-speaker label during grouping.
        public var speaker: String
        /// Offset from the start of the recording, in milliseconds.
        public var startMs: Int
        /// The utterance text. Becomes one paragraph.
        public var text: String

        public init(speaker: String, startMs: Int, text: String) {
            self.speaker = speaker
            self.startMs = startMs
            self.text = text
        }
    }

    // MARK: - Output

    /// A run of consecutive utterances by one speaker.
    public struct Turn: Equatable, Sendable {

        /// One utterance's worth of text, with the time it was said.
        ///
        /// The time is carried per paragraph rather than only on the turn
        /// because the rendered transcript stamps every line:
        /// `**Alice** [00:00:19]: …`. A turn's own `startMs` is the first of
        /// these, which is no longer enough to render its later lines.
        public struct Paragraph: Equatable, Sendable {
            public var text: String
            public var startMs: Int

            public init(text: String, startMs: Int) {
                self.text = text
                self.startMs = startMs
            }
        }

        /// The speaker's display name, never blank.
        public var speaker: String
        /// Start of the turn: the start of its *first* utterance.
        public var startMs: Int
        /// One paragraph per contributing utterance, in transcript order.
        public var paragraphs: [Paragraph]

        public init(speaker: String, startMs: Int, paragraphs: [Paragraph]) {
            self.speaker = speaker
            self.startMs = startMs
            self.paragraphs = paragraphs
        }

        /// Convenience for callers and tests that only care about the words.
        public init(speaker: String, startMs: Int, texts: [String]) {
            self.init(
                speaker: speaker,
                startMs: startMs,
                paragraphs: texts.map { Paragraph(text: $0, startMs: startMs) }
            )
        }

        /// Just the words, in order — the half of a turn most callers assert on.
        public var texts: [String] { paragraphs.map(\.text) }
    }

    // MARK: - Stored properties

    /// The recording title. Also the baseline for export filenames
    /// (`docs/spec.md` §Export), sanitized by ``Exporter``.
    public var title: String
    /// When the recording was made. Rendered in the document header.
    public var date: Date
    /// Speaker turns in transcript order.
    public var turns: [Turn]

    public init(title: String, date: Date, turns: [Turn]) {
        self.title = title
        self.date = date
        self.turns = turns
    }

    /// Builds a document by grouping a flat utterance list into turns.
    public init(
        title: String,
        date: Date,
        utterances: [Utterance],
        unknownSpeakerLabel: String = defaultUnknownSpeakerLabel
    ) {
        self.init(
            title: title,
            date: date,
            turns: Self.turns(from: utterances, unknownSpeakerLabel: unknownSpeakerLabel)
        )
    }

    /// Stands in for a speaker whose display name is blank.
    ///
    /// Callers that know the slot number pass a numbered label
    /// (`"Unknown Speaker 2"`) on the utterance itself; this is the last-resort
    /// label for an empty string, so a document never renders a nameless
    /// header.
    public static let defaultUnknownSpeakerLabel = "Unknown Speaker"

    /// The title as rendered, falling back when the recording is untitled.
    ///
    /// Matches ``FilenameSanitizer/fallbackName`` so the heading and the
    /// filename agree.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? FilenameSanitizer.fallbackName : trimmed
    }

    // MARK: - Grouping

    /// Groups a flat utterance list into speaker turns.
    ///
    /// Rules:
    ///
    /// 1. Utterances whose text is blank contribute nothing and are dropped
    ///    before grouping — an utterance edited down to nothing should not
    ///    produce an empty paragraph, nor split a speaker's turn in two.
    /// 2. A blank speaker name becomes `unknownSpeakerLabel`; names are
    ///    otherwise compared exactly, after trimming.
    /// 3. Consecutive utterances by the same speaker merge into one turn,
    ///    stamped with the *first* utterance's start.
    /// 4. Each surviving utterance becomes exactly one paragraph, trimmed of
    ///    surrounding whitespace, in input order. Paragraph *i* of a turn is
    ///    the *i*-th surviving utterance of that run — the invariant the
    ///    editor relies on to map a paragraph back to its row.
    ///
    /// Input order is preserved as given; utterances are not re-sorted by
    /// time, because the transcript's own ordering is authoritative.
    public static func turns(
        from utterances: [Utterance],
        unknownSpeakerLabel: String = defaultUnknownSpeakerLabel
    ) -> [Turn] {
        var turns: [Turn] = []

        for utterance in utterances {
            let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let speaker = speakerName(utterance.speaker, unknownSpeakerLabel: unknownSpeakerLabel)

            let paragraph = Turn.Paragraph(text: text, startMs: utterance.startMs)
            if turns.isEmpty || turns[turns.count - 1].speaker != speaker {
                turns.append(
                    Turn(speaker: speaker, startMs: utterance.startMs, paragraphs: [paragraph])
                )
            } else {
                turns[turns.count - 1].paragraphs.append(paragraph)
            }
        }

        return turns
    }

    private static func speakerName(_ raw: String, unknownSpeakerLabel: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }

        let fallback = unknownSpeakerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? defaultUnknownSpeakerLabel : fallback
    }
}
