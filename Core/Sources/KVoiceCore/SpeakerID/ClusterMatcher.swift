import Foundation

/// One profile's similarity to a cluster embedding.
public struct ProfileScore: Sendable, Equatable {
    public var profileID: UUID
    public var name: String
    /// Cosine similarity in `-1...1`.
    public var score: Float
    /// How many stored embeddings the profile was scored against.
    public var embeddingCount: Int

    public init(profileID: UUID, name: String, score: Float, embeddingCount: Int) {
        self.profileID = profileID
        self.name = name
        self.score = score
        self.embeddingCount = embeddingCount
    }
}

/// The verdict for one diarized speaker.
public struct SpeakerMatch: Sendable, Equatable {
    public enum Verdict: String, Sendable, Equatable {
        /// Score cleared the threshold — auto-assign the name (spec §3 step 5).
        case matched
        /// Below threshold, or nothing to match against. The app labels these
        /// "Unknown Speaker N" and asks the user to name them.
        case unknown
    }

    public var verdict: Verdict
    /// Best-scoring profile, present even when the verdict is `.unknown` —
    /// seeing the near-miss and its score is what makes threshold tuning
    /// possible in `speakerlab eval`.
    public var best: ProfileScore?
    public var runnerUp: ProfileScore?
    public var threshold: Float

    public init(verdict: Verdict, best: ProfileScore?, runnerUp: ProfileScore?, threshold: Float) {
        self.verdict = verdict
        self.best = best
        self.runnerUp = runnerUp
        self.threshold = threshold
    }

    public var name: String? { verdict == .matched ? best?.name : nil }
    public var score: Float { best?.score ?? 0 }

    /// Gap between the best and second-best profile. A confident match is both
    /// above threshold *and* clearly ahead of the runner-up; a small margin
    /// between two people is worth surfacing even when the score is high.
    public var margin: Float? {
        guard let best, let runnerUp else { return nil }
        return best.score - runnerUp.score
    }
}

/// Cosine-matches a cluster embedding against the enrolled profile library.
///
/// Spec §3 steps 4–5 and plan §2 Phase 1 item 6. Two rules define it:
///
/// - **A profile's score is the maximum over its stored embeddings**, not the
///   mean. Profiles deliberately hold several vectors from different
///   occasions (a scripted read, a phone-quality upload, meeting audio); a
///   mean would blur them together and let one bad enrollment drag the whole
///   profile down, whereas a max asks "does this cluster look like *any*
///   recording we have of this person?"
/// - **Below `threshold` is unknown.** Default 0.62, inside the spec's
///   0.60–0.65 band; the value is settled by `speakerlab eval` in Phase 1b.
///
/// Pure arithmetic — no model, no I/O, fully unit-tested.
public struct ClusterMatcher: Sendable {

    /// Plan §3 decision 7. Tunable at runtime (`--threshold`) and, later, in
    /// Settings across 0.40–0.80.
    public static let defaultThreshold: Float = 0.62

    public var threshold: Float

    public init(threshold: Float = ClusterMatcher.defaultThreshold) {
        self.threshold = threshold
    }

    /// Similarity of a cluster embedding to one profile: the best score across
    /// that profile's stored embeddings. Returns nil for a profile with no
    /// usable embeddings — it cannot match, and ranking it at 0 would be a lie.
    public func score(cluster: [Float], profile: SpeakerProfile) -> Float? {
        var best: Float?
        for vector in profile.vectors {
            let score = VectorMath.cosineSimilarity(cluster, vector)
            if let current = best {
                best = max(current, score)
            } else {
                best = score
            }
        }
        return best
    }

    /// All profiles scored and ranked, best first. Ties break on name so the
    /// output is stable for tests and for `eval` diffs.
    public func rank(cluster: [Float], in library: ProfileLibrary) -> [ProfileScore] {
        library.profiles
            .compactMap { profile -> ProfileScore? in
                guard let score = score(cluster: cluster, profile: profile) else { return nil }
                return ProfileScore(
                    profileID: profile.id,
                    name: profile.name,
                    score: score,
                    embeddingCount: profile.embeddingCount
                )
            }
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.name < rhs.name : lhs.score > rhs.score
            }
    }

    /// The verdict for one cluster embedding.
    public func match(cluster: [Float], in library: ProfileLibrary) -> SpeakerMatch {
        let ranked = rank(cluster: cluster, in: library)
        let best = ranked.first
        let verdict: SpeakerMatch.Verdict = (best?.score ?? -1) >= threshold ? .matched : .unknown

        return SpeakerMatch(
            verdict: verdict,
            best: best,
            runnerUp: ranked.dropFirst().first,
            threshold: threshold
        )
    }
}
