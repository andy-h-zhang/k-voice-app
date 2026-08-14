import Foundation
import SwiftData

/// A named person with a local voice profile — plan §1's `Person` row.
///
/// The SwiftData counterpart of the Phase-1 `SpeakerProfile` value type. Both
/// back the same matcher through `ProfileSource`: the CLI reads a JSON file,
/// the app reads these rows, and `ClusterMatcher` never learns the difference.
@Model
public final class Person {

    public var id: UUID
    public var name: String
    public var createdAt: Date

    /// Monotonic counter handing out `PersonEmbedding.sequence` values. FIFO
    /// eviction orders by that, not by `addedAt`: a bulk enrollment fold-in
    /// shares one timestamp across every window it produced, so dates alone
    /// cannot say which of them arrived first.
    public var embeddingSequence: Int

    @Relationship(deleteRule: .cascade, inverse: \PersonEmbedding.person)
    public var embeddings: [PersonEmbedding]

    /// Slots across the library that resolved to this person. Nullified rather
    /// than cascaded on delete: removing a person must not delete transcripts.
    @Relationship(deleteRule: .nullify, inverse: \SpeakerSlot.person)
    public var speakerSlots: [SpeakerSlot]

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.embeddingSequence = 0
        self.embeddings = []
        self.speakerSlots = []
    }

    // MARK: - Derived

    /// Stored embeddings oldest-first — the order FIFO eviction walks.
    public var orderedEmbeddings: [PersonEmbedding] {
        embeddings.sorted { $0.sequence < $1.sequence }
    }

    public var embeddingCount: Int { embeddings.count }

    public func embeddingCount(source: EmbeddingSource) -> Int {
        embeddings.lazy.filter { $0.source == source }.count
    }

    /// This person as the value type the matcher scores against.
    public var profile: SpeakerProfile {
        SpeakerProfile(
            id: id,
            name: name,
            createdAt: createdAt,
            embeddings: orderedEmbeddings.map(\.value)
        )
    }
}

/// One stored voice vector belonging to a `Person` — plan §1's
/// `ProfileEmbedding` row.
///
/// - Note: **Named `PersonEmbedding`, not `ProfileEmbedding`.** Phase 1 already
///   ships a `ProfileEmbedding` value type (`Models/SpeakerProfile.swift`) that
///   the CLI's JSON library and `ProfileStore` are built on. Renaming that
///   would churn working Phase-1 code for no gain, so the SwiftData row takes
///   the adjacent name. Field-for-field they are the same thing, and
///   `value` / `init(value:)` convert between them.
@Model
public final class PersonEmbedding {

    public var id: UUID

    /// L2-normalized embedding as a little-endian Float32 blob.
    /// Normalization happens on the way in, exactly as in `SpeakerProfile`.
    public var vectorData: Data

    public var addedAt: Date

    /// Persisted discriminant of `source`; stored raw so `#Predicate` can
    /// filter on it (e.g. "reset learned voice" = delete where source is
    /// `autolearn`).
    public var sourceRaw: String

    /// Insertion order within the owning person. Strictly increasing.
    public var sequence: Int

    @Relationship(deleteRule: .nullify)
    public var person: Person?

    public init(
        id: UUID = UUID(),
        vector: [Float],
        addedAt: Date = Date(),
        source: EmbeddingSource,
        sequence: Int = 0
    ) {
        self.id = id
        self.vectorData = EmbeddingBlob.data(from: vector)
        self.addedAt = addedAt
        self.sourceRaw = source.rawValue
        self.sequence = sequence
    }

    /// Mirrors a Phase-1 `ProfileEmbedding` into a row.
    public convenience init(value: ProfileEmbedding, sequence: Int) {
        self.init(
            id: value.id,
            vector: value.vector,
            addedAt: value.addedAt,
            source: value.source,
            sequence: sequence
        )
    }

    // MARK: - Derived

    public var vector: [Float] {
        get { EmbeddingBlob.vector(from: vectorData) }
        set { vectorData = EmbeddingBlob.data(from: newValue) }
    }

    /// Where this embedding came from. Unknown raw values fall back to
    /// `.autolearn`, the only source a future schema is likely to add more of.
    public var source: EmbeddingSource {
        get { EmbeddingSource(rawValue: sourceRaw) ?? .autolearn }
        set { sourceRaw = newValue.rawValue }
    }

    /// The Phase-1 value type, for the matcher and for JSON export.
    public var value: ProfileEmbedding {
        ProfileEmbedding(id: id, vector: vector, addedAt: addedAt, source: source)
    }
}
