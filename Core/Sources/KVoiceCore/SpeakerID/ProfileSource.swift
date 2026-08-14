import Foundation

/// Where enrolled voice profiles come from.
///
/// The matcher is pure arithmetic over a `ProfileLibrary` and has no business
/// knowing whether that library was read from the CLI's JSON file or from
/// SwiftData rows. This protocol is that seam:
///
/// | Backing | Type | Used by |
/// |---|---|---|
/// | `~/.speakerlab/profiles.json` | ``JSONProfileSource`` | `speakerlab` (Phase 1, unchanged) |
/// | `Person` / `PersonEmbedding` rows | ``SwiftDataProfileSource`` | the app (Phase 3+) |
/// | an in-memory value | ``StaticProfileSource`` | tests, and one-shot matching |
///
/// A whole-library snapshot is the right granularity here rather than a
/// per-profile query: this is a personal tool whose library is tens of people
/// × ≤20 vectors × 256 floats — a few hundred kilobytes — and matching scores
/// a cluster against *every* profile anyway. Fetching once keeps the matcher
/// synchronous and keeps SwiftData's `ModelContext` from escaping its actor.
public protocol ProfileSource: Sendable {
    /// A point-in-time snapshot of the whole profile library.
    func library() async throws -> ProfileLibrary
}

/// A profile source that can also be written to — the auto-learn path.
///
/// Split from `ProfileSource` so a read-only view (e.g. an imported library
/// being previewed) is expressible, and so a caller that only matches cannot
/// accidentally mutate a profile.
public protocol ProfileLearningSource: ProfileSource {

    /// Folds a cluster embedding into the named profile, creating it if
    /// needed (spec §4, "label once, it remembers").
    ///
    /// Behavior is `ProfileFoldPolicy`'s, identically for every backing:
    /// L2-normalize on the way in, refuse a zero vector, evict oldest-first
    /// past `cap`.
    ///
    /// - Parameters:
    ///   - name: Matched case-insensitively, trimmed — the same identity rule
    ///     `ProfileLibrary.profile(named:)` uses.
    ///   - cap: FIFO limit. Defaults to 20 (spec §4).
    @discardableResult
    func foldIn(
        _ vector: [Float],
        intoProfileNamed name: String,
        source: EmbeddingSource,
        at date: Date,
        cap: Int
    ) async throws -> ProfileFoldOutcome

    /// Drops `autolearn` embeddings from a profile, keeping enrollment and
    /// uploaded ones. Backs the "reset learned voice" action.
    ///
    /// - Returns: How many embeddings were removed.
    @discardableResult
    func resetLearnedVoice(forProfileNamed name: String) async throws -> Int
}

extension ProfileLearningSource {
    /// `foldIn` with the spec's defaults (now, cap 20).
    @discardableResult
    public func foldIn(
        _ vector: [Float],
        intoProfileNamed name: String,
        source: EmbeddingSource
    ) async throws -> ProfileFoldOutcome {
        try await foldIn(
            vector,
            intoProfileNamed: name,
            source: source,
            at: Date(),
            cap: ProfileFoldPolicy.defaultCap
        )
    }
}

// MARK: - Static

/// A `ProfileSource` over a library already in memory.
///
/// The adapter that lets every existing call site — and every Phase-1 test —
/// keep passing a plain `ProfileLibrary` while the pipeline talks to the
/// protocol.
public struct StaticProfileSource: ProfileSource {
    public let snapshot: ProfileLibrary

    public init(_ snapshot: ProfileLibrary) {
        self.snapshot = snapshot
    }

    public func library() async throws -> ProfileLibrary { snapshot }
}

// MARK: - JSON

/// A `ProfileSource` backed by the Phase-1 JSON library (`ProfileStore`).
///
/// This is what `speakerlab` uses. Reads go straight through to the file on
/// every call, so an external edit to `profiles.json` between two commands is
/// picked up — the CLI has no long-lived process to cache for.
public struct JSONProfileSource: ProfileLearningSource {
    public let store: ProfileStore

    public init(store: ProfileStore) {
        self.store = store
    }

    public init(url: URL = ProfileStore.defaultURL) {
        self.init(store: ProfileStore(url: url))
    }

    public func library() async throws -> ProfileLibrary {
        try store.load()
    }

    @discardableResult
    public func foldIn(
        _ vector: [Float],
        intoProfileNamed name: String,
        source: EmbeddingSource,
        at date: Date = Date(),
        cap: Int = ProfileFoldPolicy.defaultCap
    ) async throws -> ProfileFoldOutcome {
        try store.update { library in
            let existed = library.index(ofProfileNamed: name) != nil
            let index = library.upsert(name: name, now: date)
            let evicted = library.profiles[index].foldIn(
                vector,
                source: source,
                at: date,
                cap: cap
            )
            let profile = library.profiles[index]
            return ProfileFoldOutcome(
                profileID: profile.id,
                name: profile.name,
                created: !existed,
                // `foldIn` returns no evictions both when it stored nothing and
                // when it stored under the cap; the count settles which.
                stored: ProfileFoldPolicy.storableVector(vector) != nil,
                embeddingCount: profile.embeddingCount,
                evictedCount: evicted.count
            )
        }
    }

    @discardableResult
    public func resetLearnedVoice(forProfileNamed name: String) async throws -> Int {
        try store.update { library in
            guard let index = library.index(ofProfileNamed: name) else { return 0 }
            return library.profiles[index].resetLearnedVoice()
        }
    }
}
