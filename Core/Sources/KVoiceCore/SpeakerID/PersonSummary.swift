import Foundation

/// A `Sendable` snapshot of one person in the profile library — everything the
/// People UI shows about them, and nothing that would drag a `PersistentModel`
/// across an actor boundary.
///
/// **Added in Phase 6.** `ProfileLibrary`/`SpeakerProfile` already cross that
/// boundary for the *matcher*, but they carry every 256-float vector and say
/// nothing about how a person is referenced by existing transcripts. A list of
/// twenty people would move ~400 KB of vectors to render four numbers, and the
/// delete confirmation ("what happens to the transcripts that name them?")
/// could not be answered at all. Hence a summary type: counts, not vectors.
///
/// Produced by ``SwiftDataProfileSource/people()``.
public struct PersonSummary: Sendable, Equatable, Identifiable {

    public let id: UUID
    public let name: String
    public let createdAt: Date

    /// Stored embeddings by where they came from. A source with none is
    /// absent from the dictionary, so read it through ``embeddingCount(source:)``.
    public let embeddingCounts: [EmbeddingSource: Int]

    /// Diarized speaker slots across the whole library currently resolved to
    /// this person — i.e. how many "Speaker A"s in how many transcripts are
    /// showing this name right now.
    ///
    /// This is what makes the delete confirmation honest: those slots are
    /// nullified rather than cascaded (see `Person.speakerSlots`), so the
    /// transcripts survive and their speakers revert to the diarized/unknown
    /// display.
    public let assignedSlotCount: Int

    /// Distinct recordings holding those slots.
    public let assignedRecordingCount: Int

    public init(
        id: UUID,
        name: String,
        createdAt: Date,
        embeddingCounts: [EmbeddingSource: Int],
        assignedSlotCount: Int = 0,
        assignedRecordingCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.embeddingCounts = embeddingCounts
        self.assignedSlotCount = assignedSlotCount
        self.assignedRecordingCount = assignedRecordingCount
    }

    // MARK: - Derived

    public func embeddingCount(source: EmbeddingSource) -> Int {
        embeddingCounts[source] ?? 0
    }

    /// Total stored embeddings.
    public var embeddingCount: Int {
        embeddingCounts.values.reduce(0, +)
    }

    /// Whether this person can be recognized at all yet.
    ///
    /// A person with zero embeddings is a name and nothing else: the matcher
    /// scores against their (empty) vector set and never clears the threshold.
    /// The People UI turns this into the "enroll a voice" empty state rather
    /// than letting the profile look finished when it is not.
    public var hasVoice: Bool { embeddingCount > 0 }

    /// Embeddings that came from a human deliberately supplying audio —
    /// enrollment plus uploaded clips. What "reset learned voice" keeps.
    public var suppliedEmbeddingCount: Int {
        embeddingCount(source: .enrollment) + embeddingCount(source: .upload)
    }

    /// Embeddings folded in from labeled recordings. What "reset learned
    /// voice" removes.
    public var learnedEmbeddingCount: Int {
        embeddingCount(source: .autolearn)
    }
}
