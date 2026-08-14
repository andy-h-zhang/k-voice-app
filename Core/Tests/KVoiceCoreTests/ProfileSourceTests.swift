import Foundation
import SwiftData
import Testing

@testable import KVoiceCore

@Suite("Profile fold-in policy")
struct ProfileFoldPolicyTests {

    @Test("a storable vector comes back unit-length")
    func normalizes() throws {
        let stored = try #require(ProfileFoldPolicy.storableVector([3, 4]))
        #expect(abs(VectorMath.l2Norm(stored) - 1) < 1e-6)
        #expect(abs(stored[0] - 0.6) < 1e-6)
    }

    @Test("a zero or empty vector is refused, not stored as zeros")
    func refusesZero() {
        #expect(ProfileFoldPolicy.storableVector([0, 0, 0]) == nil)
        #expect(ProfileFoldPolicy.storableVector([]) == nil)
    }

    @Test("eviction count is the overflow past the cap")
    func eviction() {
        #expect(ProfileFoldPolicy.evictionCount(currentCount: 19, cap: 20) == 0)
        #expect(ProfileFoldPolicy.evictionCount(currentCount: 20, cap: 20) == 0)
        #expect(ProfileFoldPolicy.evictionCount(currentCount: 21, cap: 20) == 1)
        #expect(ProfileFoldPolicy.evictionCount(currentCount: 25, cap: 20) == 5)
    }

    @Test("a non-positive cap evicts everything")
    func zeroCap() {
        #expect(ProfileFoldPolicy.evictionCount(currentCount: 5, cap: 0) == 5)
        #expect(ProfileFoldPolicy.evictionCount(currentCount: 5, cap: -1) == 5)
    }

    @Test("the default cap is the spec's 20")
    func defaultCap() {
        #expect(ProfileFoldPolicy.defaultCap == 20)
        #expect(ProfileFoldPolicy.defaultCap == SpeakerProfile.defaultEmbeddingCap)
    }
}

@Suite("Profile sources")
struct ProfileSourceTests {

    // MARK: Static

    @Test("a static source hands back exactly what it was given")
    func staticSource() async throws {
        var library = ProfileLibrary()
        let index = library.upsert(name: "Alice")
        library.profiles[index].foldIn(TestVectors.unit(seed: 1), source: .enrollment)

        let source = StaticProfileSource(library)
        #expect(try await source.library() == library)
    }

    // MARK: JSON

    @Test("the JSON source reads the CLI's file")
    func jsonReads() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let store = ProfileStore(url: directory.file("profiles.json"))
        var library = ProfileLibrary()
        let index = library.upsert(name: "Alice")
        library.profiles[index].foldIn(TestVectors.unit(seed: 1), source: .enrollment)
        try store.save(library)

        let source = JSONProfileSource(store: store)
        let loaded = try await source.library()
        #expect(loaded.profiles.map(\.name) == ["Alice"])
        #expect(loaded.profiles[0].embeddingCount == 1)
    }

    @Test("the JSON source is empty, not broken, before the file exists")
    func jsonFirstRun() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let source = JSONProfileSource(url: directory.file("nothing-here.json"))
        #expect(try await source.library().profiles.isEmpty)
    }

    @Test("folding into the JSON source creates the profile and persists it")
    func jsonFoldIn() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let store = ProfileStore(url: directory.file("profiles.json"))
        let source = JSONProfileSource(store: store)

        let created = try await source.foldIn(
            TestVectors.unit(seed: 1), intoProfileNamed: "Alice", source: .autolearn
        )
        #expect(created.created)
        #expect(created.stored)
        #expect(created.embeddingCount == 1)
        #expect(created.evictedCount == 0)

        let again = try await source.foldIn(
            TestVectors.unit(seed: 2), intoProfileNamed: "alice", source: .autolearn
        )
        #expect(!again.created)
        #expect(again.profileID == created.profileID)
        #expect(again.embeddingCount == 2)

        // Straight off the disk, not out of a cache.
        #expect(try store.load().profiles[0].embeddingCount == 2)
    }

    // MARK: SwiftData

    @Test("the SwiftData source reads Person rows as profiles")
    func swiftDataReads() async throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)
        let alice = Person(name: "Alice", createdAt: Date(timeIntervalSince1970: 1))
        context.insert(alice)
        let embedding = PersonEmbedding(vector: TestVectors.unit(seed: 1), source: .enrollment, sequence: 1)
        context.insert(embedding)
        alice.embeddings.append(embedding)
        context.insert(Person(name: "Bob", createdAt: Date(timeIntervalSince1970: 2)))
        try context.save()

        let source = SwiftDataProfileSource(container: container)
        let library = try await source.library()
        #expect(library.profiles.map(\.name) == ["Alice", "Bob"])
        #expect(library.profiles[0].vectors == [TestVectors.unit(seed: 1)])
        #expect(library.profiles[1].embeddingCount == 0)
    }

    @Test("folding into the SwiftData source creates the person and the row")
    func swiftDataFoldIn() async throws {
        let container = try TestContainer.inMemory()
        let source = SwiftDataProfileSource(container: container)

        let created = try await source.foldIn(
            TestVectors.unit(seed: 1), intoProfileNamed: "Alice", source: .autolearn
        )
        #expect(created.created)
        #expect(created.stored)
        #expect(created.embeddingCount == 1)

        let again = try await source.foldIn(
            TestVectors.unit(seed: 2), intoProfileNamed: "  ALICE  ", source: .autolearn
        )
        #expect(!again.created)
        #expect(again.profileID == created.profileID)
        #expect(again.embeddingCount == 2)

        // One person, two embeddings, actually in the store.
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<Person>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<PersonEmbedding>()).count == 2)
    }

    @Test("a zero vector is refused by the SwiftData source too")
    func swiftDataRefusesZero() async throws {
        let container = try TestContainer.inMemory()
        let source = SwiftDataProfileSource(container: container)

        let outcome = try await source.foldIn(
            [0, 0, 0], intoProfileNamed: "Alice", source: .autolearn
        )
        // The person is created — the user named someone — but nothing was
        // learned, and the caller can tell the difference.
        #expect(outcome.created)
        #expect(!outcome.stored)
        #expect(outcome.embeddingCount == 0)
    }

    @Test("the FIFO cap of 20 holds, evicting oldest-first")
    func swiftDataFIFOCap() async throws {
        let container = try TestContainer.inMemory()
        let source = SwiftDataProfileSource(container: container)

        for seed in 0..<25 {
            _ = try await source.foldIn(
                TestVectors.unit(seed: seed), intoProfileNamed: "Alice", source: .autolearn
            )
        }

        let library = try await source.library()
        let profile = try #require(library.profiles.first)
        #expect(profile.embeddingCount == 20)
        // Seeds 0–4 were evicted; 5–24 survive, in order.
        #expect(isSameDirection(profile.vectors[0], TestVectors.unit(seed: 5)))
        #expect(isSameDirection(profile.vectors[19], TestVectors.unit(seed: 24)))
        #expect(haveSameDirections(profile.vectors, (5..<25).map { TestVectors.unit(seed: $0) }))
    }

    @Test("the outcome reports evictions once the cap bites")
    func evictionReported() async throws {
        let container = try TestContainer.inMemory()
        let source = SwiftDataProfileSource(container: container)

        var lastOutcome: ProfileFoldOutcome?
        for seed in 0..<21 {
            lastOutcome = try await source.foldIn(
                TestVectors.unit(seed: seed), intoProfileNamed: "Alice", source: .autolearn
            )
        }
        let outcome = try #require(lastOutcome)
        #expect(outcome.embeddingCount == 20)
        #expect(outcome.evictedCount == 1)
    }

    @Test("a bulk fold-in sharing one timestamp still evicts in insertion order")
    func bulkFoldInOrdering() async throws {
        // The reason `PersonEmbedding.sequence` exists: enrollment folds every
        // window of a clip in under one `Date`, so ordering by `addedAt` alone
        // would be ambiguous exactly when the cap starts evicting.
        let container = try TestContainer.inMemory()
        let source = SwiftDataProfileSource(container: container)
        let instant = Date(timeIntervalSince1970: 1_000)

        _ = try await source.foldIn(
            contentsOf: (0..<25).map { TestVectors.unit(seed: $0) },
            intoProfileNamed: "Alice",
            source: .enrollment,
            at: instant
        )

        let profile = try #require(try await source.library().profiles.first)
        #expect(profile.embeddingCount == 20)
        #expect(haveSameDirections(profile.vectors, (5..<25).map { TestVectors.unit(seed: $0) }))
        #expect(profile.embeddings.map(\.addedAt) == Array(repeating: instant, count: 20))
    }

    @Test("reset learned voice drops autolearn rows and keeps the rest")
    func swiftDataResetLearned() async throws {
        let container = try TestContainer.inMemory()
        let source = SwiftDataProfileSource(container: container)

        _ = try await source.foldIn(TestVectors.unit(seed: 1), intoProfileNamed: "Alice", source: .enrollment)
        _ = try await source.foldIn(TestVectors.unit(seed: 2), intoProfileNamed: "Alice", source: .upload)
        _ = try await source.foldIn(TestVectors.unit(seed: 3), intoProfileNamed: "Alice", source: .autolearn)
        _ = try await source.foldIn(TestVectors.unit(seed: 4), intoProfileNamed: "Alice", source: .autolearn)

        let removed = try await source.resetLearnedVoice(forProfileNamed: "Alice")
        #expect(removed == 2)

        let profile = try #require(try await source.library().profiles.first)
        #expect(profile.embeddingCount == 2)
        #expect(profile.embeddings.map(\.source) == [.enrollment, .upload])
    }

    @Test("resetting an unknown profile is a no-op, not an error")
    func resetUnknownProfile() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        #expect(try await source.resetLearnedVoice(forProfileNamed: "Nobody") == 0)
    }

    @Test("folding by person id addresses the row directly")
    func foldByID() async throws {
        let container = try TestContainer.inMemory()
        let source = SwiftDataProfileSource(container: container)
        let personID = try await source.upsertPerson(named: "Alice")

        let outcome = try await source.foldIn(
            TestVectors.unit(seed: 1), intoPersonWithID: personID, source: .autolearn
        )
        #expect(outcome.profileID == personID)
        #expect(outcome.embeddingCount == 1)
    }

    @Test("folding into a person who is gone fails loudly")
    func foldByMissingID() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let missing = UUID()
        await #expect(throws: ProfileSourceError.personNotFound(id: missing)) {
            _ = try await source.foldIn(
                TestVectors.unit(seed: 1), intoPersonWithID: missing, source: .autolearn
            )
        }
    }

    @Test("upserting an existing name returns the same row")
    func upsertIsIdempotent() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let first = try await source.upsertPerson(named: "Alice")
        let second = try await source.upsertPerson(named: "alice")
        #expect(first == second)
        #expect(try await source.library().profiles.count == 1)
    }

    @Test("deleting a person removes their profile from the library")
    func deletePerson() async throws {
        let container = try TestContainer.inMemory()
        let source = SwiftDataProfileSource(container: container)
        let id = try await source.upsertPerson(named: "Alice")
        _ = try await source.foldIn(TestVectors.unit(seed: 1), intoProfileNamed: "Alice", source: .autolearn)

        try await source.deletePerson(id: id)
        #expect(try await source.library().profiles.isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<PersonEmbedding>()).isEmpty)
    }

    @Test("a JSON library imports into SwiftData unchanged")
    func replaceAll() async throws {
        let container = try TestContainer.inMemory()
        let source = SwiftDataProfileSource(container: container)

        var library = ProfileLibrary()
        let alice = library.upsert(name: "Alice")
        library.profiles[alice].foldIn(TestVectors.unit(seed: 1), source: .enrollment)
        library.profiles[alice].foldIn(TestVectors.unit(seed: 2), source: .autolearn)
        let bob = library.upsert(name: "Bob")
        library.profiles[bob].foldIn(TestVectors.unit(seed: 3), source: .upload)

        try await source.replaceAll(with: library)

        let imported = try await source.library()
        #expect(imported.profiles.map(\.name) == ["Alice", "Bob"])
        #expect(imported.profiles.map(\.id) == library.profiles.map(\.id))
        #expect(imported.profiles.map(\.vectors) == library.profiles.map(\.vectors))
        #expect(imported.profiles[0].embeddings.map(\.source) == [.enrollment, .autolearn])

        // Re-importing replaces rather than accumulates.
        try await source.replaceAll(with: library)
        #expect(try await source.library().profiles.count == 2)
    }
}

@Suite("Profile source parity: JSON and SwiftData agree")
struct ProfileSourceParityTests {

    /// The same script of fold-ins, run against both backings.
    private func runScript(on source: some ProfileLearningSource) async throws -> ProfileLibrary {
        let instant = Date(timeIntervalSince1970: 1_000)
        _ = try await source.foldIn(
            TestVectors.unit(seed: 1), intoProfileNamed: "Alice",
            source: .enrollment, at: instant, cap: 3
        )
        _ = try await source.foldIn(
            TestVectors.unit(seed: 2), intoProfileNamed: "alice",
            source: .upload, at: instant, cap: 3
        )
        _ = try await source.foldIn(
            [0, 0, 0], intoProfileNamed: "Alice",
            source: .autolearn, at: instant, cap: 3
        )
        _ = try await source.foldIn(
            TestVectors.unit(seed: 3), intoProfileNamed: "Alice",
            source: .autolearn, at: instant, cap: 3
        )
        // Trips the cap: seed 1 should fall out of both.
        _ = try await source.foldIn(
            TestVectors.unit(seed: 4), intoProfileNamed: "Alice",
            source: .autolearn, at: instant, cap: 3
        )
        _ = try await source.foldIn(
            TestVectors.unit(seed: 9), intoProfileNamed: "Bob",
            source: .enrollment, at: instant, cap: 3
        )
        return try await source.library()
    }

    @Test("identical fold-in scripts produce identical libraries")
    func parity() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let json = try await runScript(
            on: JSONProfileSource(store: ProfileStore(url: directory.file("profiles.json")))
        )
        let swiftData = try await runScript(
            on: SwiftDataProfileSource(container: try TestContainer.inMemory())
        )

        #expect(json.profiles.map(\.name) == swiftData.profiles.map(\.name))
        // The payload: same vectors, same order, same eviction decision.
        #expect(json.profiles.map(\.vectors) == swiftData.profiles.map(\.vectors))
        #expect(
            json.profiles.map { $0.embeddings.map(\.source) }
                == swiftData.profiles.map { $0.embeddings.map(\.source) }
        )
        #expect(json.profiles[0].embeddingCount == 3)
        // Seed 1 fell out at the cap; seed 2 is now the oldest survivor.
        #expect(isSameDirection(json.profiles[0].vectors[0], TestVectors.unit(seed: 2)))
    }

    @Test("the matcher reaches the same verdict through either source")
    func matcherParity() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let jsonSource = JSONProfileSource(store: ProfileStore(url: directory.file("profiles.json")))
        let swiftSource = SwiftDataProfileSource(container: try TestContainer.inMemory())

        let alice = TestVectors.unit(seed: 42)
        for source in [AnyLearningSource(jsonSource), AnyLearningSource(swiftSource)] {
            _ = try await source.foldIn(alice, intoProfileNamed: "Alice", source: .enrollment)
            _ = try await source.foldIn(TestVectors.unit(seed: 77), intoProfileNamed: "Bob", source: .enrollment)
        }

        let matcher = ClusterMatcher()
        // A voice very close to Alice's enrollment, and one that is nobody's.
        let nearAlice = TestVectors.neighbor(of: alice, similarity: 0.80, seed: 5)
        let stranger = TestVectors.neighbor(of: alice, similarity: 0.10, seed: 6)

        let jsonLibrary = try await jsonSource.library()
        let swiftLibrary = try await swiftSource.library()

        let jsonHit = matcher.match(cluster: nearAlice, in: jsonLibrary)
        let swiftHit = matcher.match(cluster: nearAlice, in: swiftLibrary)
        #expect(jsonHit.verdict == .matched)
        #expect(swiftHit.verdict == .matched)
        #expect(jsonHit.name == "Alice")
        #expect(swiftHit.name == "Alice")
        #expect(abs(jsonHit.score - swiftHit.score) < 1e-6)

        #expect(matcher.match(cluster: stranger, in: jsonLibrary).verdict == .unknown)
        #expect(matcher.match(cluster: stranger, in: swiftLibrary).verdict == .unknown)
    }
}

/// Type-erases a learning source so one loop can drive both backings.
struct AnyLearningSource: ProfileLearningSource {
    private let _library: @Sendable () async throws -> ProfileLibrary
    private let _foldIn: @Sendable ([Float], String, EmbeddingSource, Date, Int) async throws -> ProfileFoldOutcome
    private let _reset: @Sendable (String) async throws -> Int

    init(_ source: some ProfileLearningSource) {
        _library = { try await source.library() }
        _foldIn = { try await source.foldIn($0, intoProfileNamed: $1, source: $2, at: $3, cap: $4) }
        _reset = { try await source.resetLearnedVoice(forProfileNamed: $0) }
    }

    func library() async throws -> ProfileLibrary { try await _library() }

    @discardableResult
    func foldIn(
        _ vector: [Float],
        intoProfileNamed name: String,
        source: EmbeddingSource,
        at date: Date,
        cap: Int
    ) async throws -> ProfileFoldOutcome {
        try await _foldIn(vector, name, source, date, cap)
    }

    @discardableResult
    func resetLearnedVoice(forProfileNamed name: String) async throws -> Int {
        try await _reset(name)
    }
}
