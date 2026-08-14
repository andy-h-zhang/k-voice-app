import Foundation
import Testing

@testable import KVoiceCore

@Suite("Speaker profile math (auto-learn core)")
struct SpeakerProfileTests {

    @Test("foldIn stores an L2-normalized copy")
    func foldInNormalizes() throws {
        var profile = SpeakerProfile(name: "Alice")
        profile.foldIn([3, 4], source: .enrollment)

        let stored = try #require(profile.embeddings.first)
        #expect(abs(VectorMath.l2Norm(stored.vector) - 1) < 1e-6)
        #expect(stored.source == .enrollment)
    }

    @Test("foldIn ignores a zero vector")
    func foldInIgnoresZeroVector() {
        var profile = SpeakerProfile(name: "Alice")
        profile.foldIn([0, 0, 0], source: .autolearn)
        #expect(profile.embeddingCount == 0)
    }

    @Test("embeddings are tagged by source and counted per source")
    func sourceTagging() {
        var profile = SpeakerProfile(name: "Alice")
        profile.foldIn(TestVectors.unit(seed: 1), source: .enrollment)
        profile.foldIn(TestVectors.unit(seed: 2), source: .enrollment)
        profile.foldIn(TestVectors.unit(seed: 3), source: .upload)
        profile.foldIn(TestVectors.unit(seed: 4), source: .autolearn)

        #expect(profile.embeddingCount == 4)
        #expect(profile.embeddingCount(source: .enrollment) == 2)
        #expect(profile.embeddingCount(source: .upload) == 1)
        #expect(profile.embeddingCount(source: .autolearn) == 1)
    }

    /// Spec §4: cap stored embeddings per profile at 20, dropping the oldest.
    @Test("FIFO cap keeps the newest 20 and evicts oldest first")
    func fifoCap() throws {
        var profile = SpeakerProfile(name: "Alice")
        var evictedTotal = 0

        for seed in 0..<25 {
            let evicted = profile.foldIn(TestVectors.unit(seed: seed), source: .autolearn)
            evictedTotal += evicted.count
        }

        #expect(profile.embeddingCount == SpeakerProfile.defaultEmbeddingCap)
        #expect(profile.embeddingCount == 20)
        #expect(evictedTotal == 5)

        // The survivors are seeds 5...24 — oldest-first eviction, newest kept.
        let oldestSurvivor = try #require(profile.embeddings.first)
        #expect(isSameDirection(oldestSurvivor.vector, TestVectors.unit(seed: 5)))

        let newest = try #require(profile.embeddings.last)
        #expect(isSameDirection(newest.vector, TestVectors.unit(seed: 24)))
    }

    @Test("eviction reports exactly which embeddings were dropped")
    func evictionIsReported() throws {
        var profile = SpeakerProfile(name: "Alice")
        for seed in 0..<20 {
            profile.foldIn(TestVectors.unit(seed: seed), source: .enrollment)
        }

        let evicted = profile.foldIn(TestVectors.unit(seed: 100), source: .autolearn)
        #expect(evicted.count == 1)
        #expect(isSameDirection(try #require(evicted.first).vector, TestVectors.unit(seed: 0)))
        #expect(profile.embeddingCount == 20)
    }

    /// Enrollment vectors are not privileged by the cap: plan §3 risk 9 wants
    /// real meeting audio to dominate a profile over time.
    @Test("the cap evicts enrollment embeddings too, once they are the oldest")
    func capDoesNotPrivilegeEnrollment() {
        var profile = SpeakerProfile(name: "Alice")
        for seed in 0..<20 {
            profile.foldIn(TestVectors.unit(seed: seed), source: .enrollment)
        }
        for seed in 100..<120 {
            profile.foldIn(TestVectors.unit(seed: seed), source: .autolearn)
        }

        #expect(profile.embeddingCount == 20)
        #expect(profile.embeddingCount(source: .enrollment) == 0)
        #expect(profile.embeddingCount(source: .autolearn) == 20)
    }

    @Test("custom cap is honored")
    func customCap() {
        var profile = SpeakerProfile(name: "Alice")
        for seed in 0..<10 {
            profile.foldIn(TestVectors.unit(seed: seed), source: .autolearn, cap: 3)
        }
        #expect(profile.embeddingCount == 3)
    }

    @Test("bulk foldIn preserves order")
    func bulkFoldInPreservesOrder() {
        var profile = SpeakerProfile(name: "Alice")
        let vectors = (0..<4).map { TestVectors.unit(seed: $0) }
        profile.foldIn(contentsOf: vectors, source: .upload)

        #expect(profile.vectors.count == vectors.count)
        for (stored, original) in zip(profile.vectors, vectors) {
            #expect(isSameDirection(stored, original))
        }
    }

    @Test("resetLearnedVoice drops auto-learned embeddings and keeps the rest")
    func resetLearnedVoice() {
        var profile = SpeakerProfile(name: "Alice")
        profile.foldIn(TestVectors.unit(seed: 1), source: .enrollment)
        profile.foldIn(TestVectors.unit(seed: 2), source: .upload)
        profile.foldIn(TestVectors.unit(seed: 3), source: .autolearn)
        profile.foldIn(TestVectors.unit(seed: 4), source: .autolearn)

        let removed = profile.resetLearnedVoice()

        #expect(removed == 2)
        #expect(profile.embeddingCount == 2)
        #expect(profile.embeddingCount(source: .autolearn) == 0)
        #expect(profile.embeddingCount(source: .enrollment) == 1)
        #expect(profile.embeddingCount(source: .upload) == 1)
    }

    @Test("removeAllEmbeddings clears the profile for re-enrollment")
    func removeAll() {
        var profile = SpeakerProfile(name: "Alice")
        profile.foldIn(TestVectors.unit(seed: 1), source: .enrollment)
        profile.removeAllEmbeddings()
        #expect(profile.embeddingCount == 0)
    }
}

@Suite("Profile library")
struct ProfileLibraryTests {

    @Test("lookup is case- and whitespace-insensitive")
    func lookupIsForgiving() {
        var library = ProfileLibrary()
        _ = library.upsert(name: "Alice Smith")

        #expect(library.profile(named: "alice smith") != nil)
        #expect(library.profile(named: "  ALICE SMITH  ") != nil)
        #expect(library.profile(named: "Bob") == nil)
    }

    @Test("upsert returns the existing profile instead of duplicating")
    func upsertIsIdempotent() {
        var library = ProfileLibrary()
        let first = library.upsert(name: "Alice")
        library.profiles[first].foldIn(TestVectors.unit(seed: 1), source: .enrollment)

        let second = library.upsert(name: "alice")

        #expect(first == second)
        #expect(library.profiles.count == 1)
        #expect(library.profiles[second].embeddingCount == 1)
    }
}
