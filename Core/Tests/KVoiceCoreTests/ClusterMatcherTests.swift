import Foundation
import Testing

@testable import KVoiceCore

@Suite("Cluster matcher")
struct ClusterMatcherTests {

    /// Builds a library where each name maps to embeddings at the given
    /// similarities to `reference`.
    private func library(
        reference: [Float],
        _ entries: [(name: String, similarities: [Float])]
    ) -> ProfileLibrary {
        var library = ProfileLibrary()
        for (offset, entry) in entries.enumerated() {
            let index = library.upsert(name: entry.name)
            for (position, similarity) in entry.similarities.enumerated() {
                library.profiles[index].foldIn(
                    TestVectors.neighbor(of: reference, similarity: similarity, seed: 1000 + offset * 10 + position),
                    source: .enrollment
                )
            }
        }
        return library
    }

    @Test("the default threshold sits in the spec's 0.60–0.65 band")
    func defaultThreshold() {
        #expect(ClusterMatcher.defaultThreshold == 0.62)
        #expect(ClusterMatcher.defaultThreshold >= 0.60)
        #expect(ClusterMatcher.defaultThreshold <= 0.65)
    }

    /// A profile deliberately holds vectors from different occasions; scoring
    /// by max asks "does this look like *any* recording of this person?"
    @Test("a profile scores as the maximum over its stored embeddings")
    func scoreIsMaxOverEmbeddings() throws {
        let cluster = TestVectors.unit(seed: 7)
        let library = library(reference: cluster, [("Alice", [0.20, 0.85, 0.40])])
        let matcher = ClusterMatcher()

        let profile = try #require(library.profile(named: "Alice"))
        let score = try #require(matcher.score(cluster: cluster, profile: profile))
        #expect(abs(score - 0.85) < 1e-3)
    }

    @Test("a score at or above the threshold is a match")
    func matchesAboveThreshold() throws {
        let cluster = TestVectors.unit(seed: 11)
        let library = library(reference: cluster, [("Alice", [0.80]), ("Bob", [0.30])])

        let match = ClusterMatcher(threshold: 0.62).match(cluster: cluster, in: library)

        #expect(match.verdict == .matched)
        #expect(match.name == "Alice")
        #expect(abs(match.score - 0.80) < 1e-3)
        #expect(try #require(match.runnerUp).name == "Bob")
    }

    @Test("a score below the threshold is unknown, but still reports the near miss")
    func belowThresholdIsUnknown() throws {
        let cluster = TestVectors.unit(seed: 13)
        let library = library(reference: cluster, [("Alice", [0.55])])

        let match = ClusterMatcher(threshold: 0.62).match(cluster: cluster, in: library)

        #expect(match.verdict == .unknown)
        #expect(match.name == nil)
        // The near miss is retained — this is what makes threshold tuning possible.
        #expect(try #require(match.best).name == "Alice")
        #expect(abs(match.score - 0.55) < 1e-3)
    }

    @Test("the threshold boundary is inclusive")
    func thresholdIsInclusive() {
        let cluster = TestVectors.unit(seed: 17)
        var library = ProfileLibrary()
        let index = library.upsert(name: "Alice")
        library.profiles[index].foldIn(cluster, source: .enrollment)

        // Identical vectors score 1.0 exactly.
        let match = ClusterMatcher(threshold: 1.0).match(cluster: cluster, in: library)
        #expect(match.verdict == .matched)
    }

    @Test("an empty library yields unknown with no best match")
    func emptyLibrary() {
        let match = ClusterMatcher().match(cluster: TestVectors.unit(seed: 19), in: ProfileLibrary())

        #expect(match.verdict == .unknown)
        #expect(match.best == nil)
        #expect(match.runnerUp == nil)
        #expect(match.margin == nil)
    }

    @Test("a profile with no embeddings is not ranked at all")
    func emptyProfileIsSkipped() {
        let cluster = TestVectors.unit(seed: 23)
        var library = ProfileLibrary()
        _ = library.upsert(name: "Empty")

        let matcher = ClusterMatcher()
        #expect(matcher.score(cluster: cluster, profile: library.profiles[0]) == nil)
        #expect(matcher.rank(cluster: cluster, in: library).isEmpty)
    }

    @Test("ranking is ordered by score, then name for stability")
    func rankingIsStable() {
        let cluster = TestVectors.unit(seed: 29)
        let library = library(
            reference: cluster,
            [("Charlie", [0.50]), ("Alice", [0.90]), ("Bob", [0.70])]
        )

        let names = ClusterMatcher().rank(cluster: cluster, in: library).map(\.name)
        #expect(names == ["Alice", "Bob", "Charlie"])
    }

    @Test("margin is the gap to the runner-up")
    func margin() throws {
        let cluster = TestVectors.unit(seed: 31)
        let library = library(reference: cluster, [("Alice", [0.90]), ("Bob", [0.70])])

        let match = ClusterMatcher().match(cluster: cluster, in: library)
        let margin = try #require(match.margin)
        #expect(abs(margin - 0.20) < 1e-3)
    }

    @Test("a stale-dimension profile fails to match instead of crashing")
    func dimensionMismatchDoesNotCrash() {
        var library = ProfileLibrary()
        let index = library.upsert(name: "LegacyBackend")
        library.profiles[index].foldIn(TestVectors.unit(seed: 3, dimension: 192), source: .enrollment)

        let match = ClusterMatcher().match(cluster: TestVectors.unit(seed: 3, dimension: 256), in: library)

        #expect(match.verdict == .unknown)
        #expect(match.score == 0)
    }

    @Test("matching is deterministic across repeated runs")
    func deterministic() {
        let cluster = TestVectors.unit(seed: 37)
        let library = library(reference: cluster, [("Alice", [0.80]), ("Bob", [0.79])])
        let matcher = ClusterMatcher()

        let first = matcher.match(cluster: cluster, in: library)
        let second = matcher.match(cluster: cluster, in: library)
        #expect(first == second)
    }
}
