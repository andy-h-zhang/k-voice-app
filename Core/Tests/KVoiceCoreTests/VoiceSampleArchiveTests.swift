import Foundation
import SwiftData
import Testing

@testable import KVoiceCore

/// Exporting voice samples from one KVoice and importing them into another:
/// the second install must end up recognizing the same people with the same
/// vectors.
@Suite("Voice-sample files")
struct VoiceSampleArchiveTests {

    // MARK: - Round trip

    @Test("export then import into an empty library reproduces every vector")
    func roundTrip() async throws {
        let mine = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let alice = try await mine.upsertPerson(named: "Alice")
        try await mine.foldIn(
            contentsOf: [TestVectors.unit(seed: 1), TestVectors.unit(seed: 2)],
            intoPersonWithID: alice,
            source: .enrollment
        )
        try await mine.foldIn(TestVectors.unit(seed: 3), intoPersonWithID: alice, source: .autolearn)
        let bob = try await mine.upsertPerson(named: "Bob")
        try await mine.foldIn(contentsOf: [TestVectors.unit(seed: 4)], intoPersonWithID: bob, source: .upload)

        let data = try await mine.exportVoiceSamples().encoded()
        let archive = try VoiceSampleArchive.decode(data)
        #expect(archive.sampleCount == 4)

        let theirs = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let summary = try await theirs.importVoiceSamples(archive)
        #expect(summary.added == ["Alice", "Bob"])
        #expect(summary.replaced.isEmpty)
        #expect(summary.sampleCount == 4)

        let original = try await mine.library()
        let copy = try await theirs.library()
        #expect(copy.profiles.map(\.name) == original.profiles.map(\.name))
        for (a, b) in zip(original.profiles, copy.profiles) {
            // Same vectors, same order, same sources: the matcher cannot tell
            // the two libraries apart.
            #expect(a.embeddings.map(\.vector) == b.embeddings.map(\.vector))
            #expect(a.embeddings.map(\.source) == b.embeddings.map(\.source))
        }
    }

    @Test("people without voice samples are left out of an export")
    func skipsEmptyPeople() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        try await source.createPerson(named: "Name Only")
        let voiced = try await source.upsertPerson(named: "Voiced")
        try await source.foldIn(TestVectors.unit(seed: 1), intoPersonWithID: voiced, source: .enrollment)

        let archive = try await source.exportVoiceSamples()
        #expect(archive.people.map(\.name) == ["Voiced"])
    }

    @Test("exporting with nobody voiced is an error, not an empty file")
    func nothingToExport() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        try await source.createPerson(named: "Name Only")
        await #expect(throws: VoiceSampleArchiveError.nothingToExport) {
            try await source.exportVoiceSamples()
        }
    }

    @Test("an export can be limited to chosen people")
    func exportSubset() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let alice = try await source.upsertPerson(named: "Alice")
        let bob = try await source.upsertPerson(named: "Bob")
        try await source.foldIn(TestVectors.unit(seed: 1), intoPersonWithID: alice, source: .enrollment)
        try await source.foldIn(TestVectors.unit(seed: 2), intoPersonWithID: bob, source: .enrollment)

        let archive = try await source.exportVoiceSamples(personIDs: [bob])
        #expect(archive.people.map(\.name) == ["Bob"])
    }

    // MARK: - Importing over existing people

    @Test("an existing person keeps their row but their samples are replaced")
    func replacesExisting() async throws {
        let exporter = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let exported = try await exporter.upsertPerson(named: "Alice")
        try await exporter.foldIn(
            contentsOf: [TestVectors.unit(seed: 10), TestVectors.unit(seed: 11)],
            intoPersonWithID: exported,
            source: .enrollment
        )
        let archive = try await exporter.exportVoiceSamples()

        let importer = SwiftDataProfileSource(container: try TestContainer.inMemory())
        // Different case, different samples, its own id.
        let existing = try await importer.upsertPerson(named: "alice")
        try await importer.foldIn(
            contentsOf: [TestVectors.unit(seed: 20), TestVectors.unit(seed: 21), TestVectors.unit(seed: 22)],
            intoPersonWithID: existing,
            source: .autolearn
        )

        let preview = try await importer.previewImport(archive)
        #expect(preview.replaced == ["alice"])
        #expect(preview.added.isEmpty)
        // A preview changes nothing.
        #expect(try await importer.person(id: existing)?.embeddingCount == 3)

        try await importer.importVoiceSamples(archive)

        let library = try await importer.library()
        #expect(library.profiles.count == 1)
        let alice = try #require(library.profiles.first)
        #expect(alice.id == existing)
        // Exactly the exporter's samples; the three learned ones are gone.
        let exportedVectors = try await exporter.library().profiles.first?.embeddings.map(\.vector)
        #expect(alice.embeddings.map(\.vector) == exportedVectors)

        // And it keeps learning in order afterwards: a new sample lands last.
        try await importer.foldIn(TestVectors.unit(seed: 30), intoPersonWithID: existing, source: .autolearn)
        let after = try #require(try await importer.library().profiles.first)
        #expect(after.embeddingCount == 3)
        #expect(after.embeddings.last?.source == .autolearn)
        let similarity = VectorMath.cosineSimilarity(after.embeddings.last?.vector ?? [], TestVectors.unit(seed: 30))
        #expect(similarity > 0.9999)
    }

    @Test("importing the same file twice leaves the same result")
    func idempotent() async throws {
        let exporter = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let id = try await exporter.upsertPerson(named: "Alice")
        try await exporter.foldIn(TestVectors.unit(seed: 1), intoPersonWithID: id, source: .enrollment)
        let archive = try await exporter.exportVoiceSamples()

        let importer = SwiftDataProfileSource(container: try TestContainer.inMemory())
        try await importer.importVoiceSamples(archive)
        let second = try await importer.importVoiceSamples(archive)
        #expect(second.replaced == ["Alice"])

        let library = try await importer.library()
        #expect(library.profiles.count == 1)
        #expect(library.profiles.first?.embeddingCount == 1)
    }

    // MARK: - Rejecting bad files

    @Test("a file that is not a voice-sample file is refused")
    func rejectsForeignFile() {
        let data = Data(#"{"version":1,"profiles":[]}"#.utf8)
        #expect(throws: VoiceSampleArchiveError.notAVoiceSampleFile) {
            try VoiceSampleArchive.decode(data)
        }
    }

    @Test("a file from a newer format is refused with a version message")
    func rejectsNewerVersion() throws {
        var archive = VoiceSampleArchive(people: [])
        archive.version = VoiceSampleArchive.currentVersion + 1
        let data = try archive.encoded()
        #expect(throws: VoiceSampleArchiveError.unsupportedVersion(archive.version)) {
            try VoiceSampleArchive.decode(data)
        }
    }

    @Test("samples from a different voice model are refused")
    func rejectsOtherModel() throws {
        let profile = SpeakerProfile(
            name: "Alice",
            embeddings: [ProfileEmbedding(vector: TestVectors.unit(seed: 1, dimension: 192), source: .enrollment)]
        )
        let archive = VoiceSampleArchive(people: [profile], embeddingModel: "ecapa", embeddingDimension: 192)
        let data = try archive.encoded()
        #expect(throws: VoiceSampleArchiveError.incompatibleModel(model: "ecapa", dimension: 192)) {
            try VoiceSampleArchive.decode(data)
        }
    }

    @Test("a vector of the wrong length is refused even under the right header")
    func rejectsMislabeledVectors() throws {
        let profile = SpeakerProfile(
            name: "Alice",
            embeddings: [ProfileEmbedding(vector: TestVectors.unit(seed: 1, dimension: 192), source: .enrollment)]
        )
        let data = try VoiceSampleArchive(people: [profile]).encoded()
        #expect(throws: VoiceSampleArchiveError.self) {
            try VoiceSampleArchive.decode(data)
        }
    }

    @Test("a file with nobody voiced imports nothing")
    func nothingToImport() async throws {
        let archive = VoiceSampleArchive(people: [SpeakerProfile(name: "Empty")])
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        await #expect(throws: VoiceSampleArchiveError.nothingToImport) {
            try await source.importVoiceSamples(archive)
        }
    }
}
