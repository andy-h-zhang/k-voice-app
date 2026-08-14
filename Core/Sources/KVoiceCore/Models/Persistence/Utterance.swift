import Foundation
import SwiftData

/// One diarized speaker turn — plan §1's `Utterance` row.
///
/// This is the **edited** copy of the text: the spec requires transcript edits
/// to persist to the database and never to the raw API response. Rebuilding
/// from `transcript.raw.json` (the `reprocess` path) therefore discards edits
/// by design, which is exactly what "re-process" means.
///
/// Distinct from `TranscriptResponse.Utterance`, which is the wire shape and
/// carries `words[]`. Words stop at the DB boundary (plan §3 decision 5).
@Model
public final class Utterance {

    /// Position in the transcript, 0-based. The sort key — SwiftData
    /// to-many relationships are not order-preserving.
    public var index: Int

    /// The label diarization assigned: "A", "B", … Kept alongside the
    /// `speakerSlot` relationship so a slot-less row still renders.
    public var diarizedSpeaker: String

    /// Editable transcript text.
    public var text: String

    /// Start offset in **milliseconds** from the beginning of the audio.
    public var startMs: Int

    /// End offset in **milliseconds**.
    public var endMs: Int

    /// Provider confidence in `0...1`, when reported.
    public var confidence: Double?

    /// True once a human has edited `text`, so a future "re-process" can warn
    /// before overwriting hand-corrections.
    public var isEdited: Bool

    @Relationship(deleteRule: .nullify)
    public var recording: Recording?

    /// The per-recording speaker this turn belongs to. Reassigning a single
    /// utterance's speaker (spec §Transcript editor) repoints this.
    @Relationship(deleteRule: .nullify)
    public var speakerSlot: SpeakerSlot?

    public init(
        index: Int,
        diarizedSpeaker: String,
        text: String,
        startMs: Int,
        endMs: Int,
        confidence: Double? = nil,
        isEdited: Bool = false
    ) {
        self.index = index
        self.diarizedSpeaker = diarizedSpeaker
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
        self.isEdited = isEdited
    }

    /// Builds a row from the wire DTO. Words are deliberately dropped.
    public convenience init(index: Int, dto: TranscriptResponse.Utterance) {
        self.init(
            index: index,
            diarizedSpeaker: dto.speaker,
            text: dto.text,
            startMs: dto.start,
            endMs: dto.end,
            confidence: dto.confidence
        )
    }

    public var durationMs: Int { max(0, endMs - startMs) }

    public var startSeconds: Double { Double(startMs) / 1000 }
    public var endSeconds: Double { Double(endMs) / 1000 }

    /// The name to show for this turn: the resolved person, else the
    /// "Unknown Speaker N" placeholder, else the bare diarized letter.
    public var displaySpeakerName: String {
        speakerSlot?.displayName ?? "Speaker \(diarizedSpeaker)"
    }
}
