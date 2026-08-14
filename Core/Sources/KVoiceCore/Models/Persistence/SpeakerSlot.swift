import Foundation
import SwiftData

/// One diarized speaker *within one recording* — plan §1's `SpeakerSlot` row.
///
/// The load-bearing detail is the third bullet of plan §1's "deliberate
/// choices": **the cluster embedding is persisted even when nothing matched.**
/// Diarization says "Speaker C"; if no profile clears the threshold the slot
/// is an "Unknown Speaker N" placeholder — but its 256-d cluster embedding is
/// already computed and stored, so naming that person weeks later folds a real
/// voice vector into their profile without re-reading (or even still having)
/// the audio. That is what makes the spec's acceptance criterion — "a third
/// unknown voice is flagged and, once named, auto-recognized next time" —
/// cheap instead of a re-run of the whole pipeline.
@Model
public final class SpeakerSlot {

    /// The diarized label from the provider: "A", "B", …
    public var diarizedSpeaker: String

    /// Cluster embedding as a little-endian Float32 blob (`EmbeddingBlob`).
    /// Empty when no span could be embedded at all.
    public var clusterEmbeddingData: Data

    /// 1-based index behind the "Unknown Speaker N" label. Non-nil exactly
    /// when `person` is nil.
    public var unknownIndex: Int?

    /// Best-matching profile name at match time, kept even when the score fell
    /// below the threshold — it is the near-miss the user sees when naming.
    public var matchedName: String?

    /// Cosine similarity of the best match, `-1...1`.
    public var matchScore: Float?

    /// Threshold in force when this slot was matched, so a later threshold
    /// change is visibly *not* retroactive.
    public var matchThreshold: Float?

    /// False when fewer than the target number of clean spans were available —
    /// the verdict rests on thin evidence and the UI can say so.
    public var meetsTarget: Bool

    /// How many audio spans went into the cluster embedding.
    public var spanCount: Int

    /// True once a human confirmed or corrected this slot. Auto-learn only
    /// folds embeddings in on a human's say-so (spec §4).
    public var isConfirmed: Bool

    @Relationship(deleteRule: .nullify)
    public var recording: Recording?

    /// The resolved person, or nil for an unknown speaker.
    @Relationship(deleteRule: .nullify)
    public var person: Person?

    @Relationship(deleteRule: .nullify, inverse: \Utterance.speakerSlot)
    public var utterances: [Utterance]

    public init(
        diarizedSpeaker: String,
        clusterEmbedding: [Float] = [],
        unknownIndex: Int? = nil,
        matchedName: String? = nil,
        matchScore: Float? = nil,
        matchThreshold: Float? = nil,
        meetsTarget: Bool = true,
        spanCount: Int = 0,
        isConfirmed: Bool = false
    ) {
        self.diarizedSpeaker = diarizedSpeaker
        self.clusterEmbeddingData = EmbeddingBlob.data(from: clusterEmbedding)
        self.unknownIndex = unknownIndex
        self.matchedName = matchedName
        self.matchScore = matchScore
        self.matchThreshold = matchThreshold
        self.meetsTarget = meetsTarget
        self.spanCount = spanCount
        self.isConfirmed = isConfirmed
        self.utterances = []
    }

    // MARK: - Derived

    /// The cluster embedding. Empty when the slot has none.
    public var clusterEmbedding: [Float] {
        get { EmbeddingBlob.vector(from: clusterEmbeddingData) }
        set { clusterEmbeddingData = EmbeddingBlob.data(from: newValue) }
    }

    /// Whether this slot still carries a usable voice vector for auto-learn.
    public var hasClusterEmbedding: Bool {
        !clusterEmbeddingData.isEmpty
    }

    /// Whether this is an unnamed speaker awaiting a human.
    public var isUnknown: Bool { person == nil }

    /// What the editor shows: the person's name, else "Unknown Speaker N".
    public var displayName: String {
        if let person { return person.name }
        if let unknownIndex { return "Unknown Speaker \(unknownIndex)" }
        return "Speaker \(diarizedSpeaker)"
    }

    /// Assigns a person to this slot, clearing the unknown placeholder.
    ///
    /// Does **not** fold the embedding into the person's profile — that is
    /// `SwiftDataProfileSource.foldIn`, kept separate so the caller decides
    /// whether an assignment is a confirmation worth learning from.
    public func assign(_ newPerson: Person, confirmed: Bool = true) {
        person = newPerson
        unknownIndex = nil
        matchedName = newPerson.name
        isConfirmed = confirmed
    }

    /// Detaches the person, restoring the "Unknown Speaker N" placeholder.
    public func clearPerson(unknownIndex newIndex: Int?) {
        person = nil
        unknownIndex = newIndex
        isConfirmed = false
    }
}
