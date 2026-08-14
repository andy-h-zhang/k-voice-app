import Foundation

/// Where a stored embedding came from. Spec §Voice profiles lists exactly
/// three creation paths, and Phase 6's "reset learned voice" action is
/// defined as *drop the `autolearn` ones, keep the rest* — which is only
/// possible because every embedding is tagged at write time.
public enum EmbeddingSource: String, Codable, Sendable, CaseIterable {
    /// Guided in-app enrollment (the ~30 s scripted read).
    case enrollment
    /// Existing audio of the person, supplied as clips.
    case upload
    /// Folded in from a labeled recording — the auto-learn path (spec §4).
    case autolearn
}

/// One stored voice vector inside a profile.
public struct ProfileEmbedding: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// L2-normalized embedding. Normalization happens on the way in
    /// (`SpeakerProfile.foldIn`) so every comparison is scale-free.
    public var vector: [Float]
    public var addedAt: Date
    public var source: EmbeddingSource

    public init(
        id: UUID = UUID(),
        vector: [Float],
        addedAt: Date = Date(),
        source: EmbeddingSource
    ) {
        self.id = id
        self.vector = vector
        self.addedAt = addedAt
        self.source = source
    }
}

/// A named person's local voice profile.
///
/// Mirrors the `Person` + `ProfileEmbedding` pair in plan §1's SwiftData
/// schema, but as a plain `Codable` value so the Phase-1 CLI can persist it
/// to JSON without pulling in SwiftData. Phase 3 maps these fields onto the
/// `@Model` classes one-for-one.
public struct SpeakerProfile: Codable, Sendable, Equatable, Identifiable {

    /// FIFO cap on stored embeddings (spec §4: "cap stored embeddings per
    /// profile, e.g. 20, drop oldest").
    public static let defaultEmbeddingCap = 20

    public let id: UUID
    public var name: String
    public var createdAt: Date
    public private(set) var embeddings: [ProfileEmbedding]

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        embeddings: [ProfileEmbedding] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.embeddings = embeddings
    }

    /// Every stored vector, for the matcher.
    public var vectors: [[Float]] { embeddings.map(\.vector) }

    public var embeddingCount: Int { embeddings.count }

    public func embeddingCount(source: EmbeddingSource) -> Int {
        embeddings.lazy.filter { $0.source == source }.count
    }

    /// Adds an embedding, enforcing the FIFO cap.
    ///
    /// This is the auto-learn core (spec §4). The two rules — normalize on the
    /// way in, evict strictly oldest-first regardless of source — live in
    /// ``ProfileFoldPolicy``, because Phase 3's SwiftData profile source has to
    /// behave identically and a second copy of the arithmetic would drift.
    ///
    /// - Returns: The embeddings evicted to stay within `cap`.
    @discardableResult
    public mutating func foldIn(
        _ vector: [Float],
        source: EmbeddingSource,
        at date: Date = Date(),
        cap: Int = SpeakerProfile.defaultEmbeddingCap
    ) -> [ProfileEmbedding] {
        guard let normalized = ProfileFoldPolicy.storableVector(vector) else { return [] }

        embeddings.append(ProfileEmbedding(vector: normalized, addedAt: date, source: source))
        return trim(to: cap)
    }

    /// Bulk `foldIn` preserving order (used by `enroll`, which produces one
    /// embedding per ~5 s window of a clip).
    @discardableResult
    public mutating func foldIn(
        contentsOf vectors: [[Float]],
        source: EmbeddingSource,
        at date: Date = Date(),
        cap: Int = SpeakerProfile.defaultEmbeddingCap
    ) -> [ProfileEmbedding] {
        var evicted: [ProfileEmbedding] = []
        for vector in vectors {
            evicted.append(contentsOf: foldIn(vector, source: source, at: date, cap: cap))
        }
        return evicted
    }

    /// Drops auto-learned embeddings, keeping enrollment and uploaded ones.
    /// Backs the profile action of the same name in spec §Voice profiles.
    @discardableResult
    public mutating func resetLearnedVoice() -> Int {
        let before = embeddings.count
        embeddings.removeAll { $0.source == .autolearn }
        return before - embeddings.count
    }

    /// Removes every embedding (used by "re-enroll").
    public mutating func removeAllEmbeddings() {
        embeddings.removeAll()
    }

    @discardableResult
    private mutating func trim(to cap: Int) -> [ProfileEmbedding] {
        let overflow = ProfileFoldPolicy.evictionCount(currentCount: embeddings.count, cap: cap)
        guard overflow > 0 else { return [] }
        let evicted = Array(embeddings.prefix(overflow))
        embeddings.removeFirst(overflow)
        return evicted
    }
}

/// The whole local profile library — the JSON document `speakerlab` reads and
/// writes (default `~/.speakerlab/profiles.json`).
public struct ProfileLibrary: Codable, Sendable, Equatable {

    /// Schema version, so a future format change can migrate rather than
    /// silently mis-decode.
    public static let currentVersion = 1

    public var version: Int
    public var profiles: [SpeakerProfile]

    public init(version: Int = ProfileLibrary.currentVersion, profiles: [SpeakerProfile] = []) {
        self.version = version
        self.profiles = profiles
    }

    /// Case-insensitive name lookup — the CLI addresses people by name.
    public func profile(named name: String) -> SpeakerProfile? {
        let key = Self.key(name)
        return profiles.first { Self.key($0.name) == key }
    }

    public func index(ofProfileNamed name: String) -> Int? {
        let key = Self.key(name)
        return profiles.firstIndex { Self.key($0.name) == key }
    }

    /// Returns the existing profile with this name, creating an empty one if
    /// absent. The returned index is stable for the duration of the mutation.
    public mutating func upsert(name: String, now: Date = Date()) -> Int {
        if let index = index(ofProfileNamed: name) { return index }
        profiles.append(SpeakerProfile(name: name, createdAt: now))
        return profiles.count - 1
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
