import Foundation

/// The auto-learn arithmetic, in one place.
///
/// Spec §4 defines auto-learn as "fold that recording's cluster embedding into
/// the person's profile … cap stored embeddings per profile, e.g. 20, drop
/// oldest". Phase 1 implemented that against a JSON library
/// (`SpeakerProfile.foldIn`); Phase 3 needs the identical behavior against
/// SwiftData rows.
///
/// Rather than write the rules twice and hope they stay in step, both callers
/// go through this type. Two rules, and they are the whole policy:
///
/// 1. **Normalize on the way in.** A profile is a set of unit vectors no matter
///    what the embedding backend returned, so cosine similarity is scale-free.
///    A zero-length (or non-finite) vector carries no speaker information and
///    is refused rather than stored.
/// 2. **Evict strictly oldest-first, regardless of source.** Enrollment
///    embeddings are *not* privileged: plan §3 risk 9 wants real meeting audio
///    to dominate over time, because a 30-second scripted read is a poor model
///    of how someone talks in a meeting. "Reset learned voice" is the escape
///    hatch when a user disagrees.
public enum ProfileFoldPolicy {

    /// FIFO cap on stored embeddings per profile (spec §4).
    public static var defaultCap: Int { SpeakerProfile.defaultEmbeddingCap }

    /// The form in which a vector is stored, or nil when it is not storable.
    public static func storableVector(_ vector: [Float]) -> [Float]? {
        let normalized = VectorMath.l2Normalized(vector)
        guard VectorMath.l2Norm(normalized) > 0 else { return nil }
        return normalized
    }

    /// How many of the oldest embeddings must go for a profile of
    /// `currentCount` embeddings to fit within `cap`.
    ///
    /// A non-positive cap means "store nothing" and evicts everything, which
    /// is how a caller disables learning for a profile without a special case.
    public static func evictionCount(currentCount: Int, cap: Int) -> Int {
        guard cap > 0 else { return max(0, currentCount) }
        return max(0, currentCount - cap)
    }
}

/// What one auto-learn fold-in did.
///
/// Returned by every `ProfileLearningSource` so callers can report "learned:
/// speaker B → Bob (20 embeddings stored, 1 evicted at the cap)" without
/// knowing whether the profile lives in JSON or SwiftData.
public struct ProfileFoldOutcome: Sendable, Equatable {

    /// Identity of the profile that was written to.
    public var profileID: UUID

    /// Its name, as stored (the caller's spelling wins for a new profile;
    /// an existing profile keeps its own).
    public var name: String

    /// True when the profile did not exist and was created by this call.
    public var created: Bool

    /// False when the vector was unusable (zero-length / non-finite) and
    /// nothing was stored. Everything else still describes the profile.
    public var stored: Bool

    /// Embeddings the profile holds after the fold-in.
    public var embeddingCount: Int

    /// How many were dropped to stay within the cap.
    public var evictedCount: Int

    public init(
        profileID: UUID,
        name: String,
        created: Bool,
        stored: Bool,
        embeddingCount: Int,
        evictedCount: Int
    ) {
        self.profileID = profileID
        self.name = name
        self.created = created
        self.stored = stored
        self.embeddingCount = embeddingCount
        self.evictedCount = evictedCount
    }
}
