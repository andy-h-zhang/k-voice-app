import Foundation
import SwiftData
import Testing

@testable import KVoiceCore

/// The Phase-6 People UI's data layer: everything spec §Voice profiles calls a
/// "per-profile action" (rename, re-enroll, delete, reset learned voice) plus
/// the summary the list renders.
@Suite("People directory")
struct PeopleDirectoryTests {

    // MARK: - Summaries

    @Test("a summary breaks the embedding count down by source")
    func summaryCountsBySource() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let id = try await source.upsertPerson(named: "Alice")

        try await source.foldIn(
            contentsOf: [TestVectors.unit(seed: 1), TestVectors.unit(seed: 2)],
            intoPersonWithID: id,
            source: .enrollment
        )
        try await source.foldIn(
            contentsOf: [TestVectors.unit(seed: 3)],
            intoPersonWithID: id,
            source: .upload
        )
        try await source.foldIn(TestVectors.unit(seed: 4), intoPersonWithID: id, source: .autolearn)

        let summary = try #require(try await source.person(id: id))
        #expect(summary.name == "Alice")
        #expect(summary.embeddingCount == 4)
        #expect(summary.embeddingCount(source: .enrollment) == 2)
        #expect(summary.embeddingCount(source: .upload) == 1)
        #expect(summary.embeddingCount(source: .autolearn) == 1)
        #expect(summary.suppliedEmbeddingCount == 3)
        #expect(summary.learnedEmbeddingCount == 1)
        #expect(summary.hasVoice)
    }

    @Test("a person with no embeddings reads as having no voice yet")
    func emptyProfile() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let summary = try await source.createPerson(named: "Newcomer")

        #expect(summary.embeddingCount == 0)
        #expect(!summary.hasVoice)
        #expect(summary.embeddingCount(source: .enrollment) == 0)
    }

    @Test("people() lists everyone in creation order")
    func listOrder() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let epoch = Date(timeIntervalSince1970: 1_000_000)

        try await source.createPerson(named: "Carla", at: epoch)
        try await source.createPerson(named: "Ana", at: epoch.addingTimeInterval(60))
        try await source.createPerson(named: "Bo", at: epoch.addingTimeInterval(120))

        #expect(try await source.people().map(\.name) == ["Carla", "Ana", "Bo"])
    }

    // MARK: - Creating

    @Test("creating a person refuses a name already in use, whatever its case")
    func createRejectsDuplicates() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        try await source.createPerson(named: "Alice")

        await #expect(throws: ProfileSourceError.duplicateName("Alice")) {
            try await source.createPerson(named: "  alice ")
        }
        #expect(try await source.people().count == 1)
    }

    @Test("creating a person refuses a blank name")
    func createRejectsBlank() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())

        await #expect(throws: ProfileSourceError.invalidName) {
            try await source.createPerson(named: "   \n ")
        }
        #expect(try await source.people().isEmpty)
    }

    @Test("a created name is stored trimmed")
    func createTrims() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let summary = try await source.createPerson(named: "  Alice  ")
        #expect(summary.name == "Alice")
    }

    // MARK: - Renaming

    @Test("renaming keeps every embedding")
    func renameKeepsEmbeddings() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let id = try await source.upsertPerson(named: "Bob")
        try await source.foldIn(
            contentsOf: [TestVectors.unit(seed: 1), TestVectors.unit(seed: 2)],
            intoPersonWithID: id,
            source: .enrollment
        )

        let renamed = try await source.renamePerson(id: id, to: "Robert")
        #expect(renamed.name == "Robert")
        #expect(renamed.embeddingCount == 2)

        // And the matcher's view of the library agrees.
        let library = try await source.library()
        #expect(library.profile(named: "Robert")?.embeddingCount == 2)
        #expect(library.profile(named: "Bob") == nil)
    }

    @Test("renaming to a different person's name is refused")
    func renameRejectsCollision() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let bob = try await source.upsertPerson(named: "Bob")
        try await source.upsertPerson(named: "Alice")

        await #expect(throws: ProfileSourceError.duplicateName("Alice")) {
            try await source.renamePerson(id: bob, to: "alice")
        }
        #expect(try await source.person(id: bob)?.name == "Bob")
    }

    @Test("re-casing a person's own name is allowed")
    func renameOwnCase() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let id = try await source.upsertPerson(named: "bob")

        let renamed = try await source.renamePerson(id: id, to: "Bob")
        #expect(renamed.name == "Bob")
    }

    @Test("renaming a blank name, or a person who is gone, throws")
    func renameGuards() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let id = try await source.upsertPerson(named: "Bob")

        await #expect(throws: ProfileSourceError.invalidName) {
            try await source.renamePerson(id: id, to: " ")
        }

        let ghost = UUID()
        await #expect(throws: ProfileSourceError.personNotFound(id: ghost)) {
            try await source.renamePerson(id: ghost, to: "Anyone")
        }
    }

    // MARK: - Reset learned voice

    @Test("reset learned voice drops autolearn embeddings and keeps the rest")
    func resetByID() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let id = try await source.upsertPerson(named: "Alice")

        try await source.foldIn(
            contentsOf: [TestVectors.unit(seed: 1), TestVectors.unit(seed: 2)],
            intoPersonWithID: id,
            source: .enrollment
        )
        try await source.foldIn(
            contentsOf: [TestVectors.unit(seed: 3)],
            intoPersonWithID: id,
            source: .upload
        )
        try await source.foldIn(
            contentsOf: [TestVectors.unit(seed: 4), TestVectors.unit(seed: 5), TestVectors.unit(seed: 6)],
            intoPersonWithID: id,
            source: .autolearn
        )

        #expect(try await source.resetLearnedVoice(forPersonWithID: id) == 3)

        let after = try #require(try await source.person(id: id))
        #expect(after.embeddingCount == 3)
        #expect(after.embeddingCount(source: .enrollment) == 2)
        #expect(after.embeddingCount(source: .upload) == 1)
        #expect(after.embeddingCount(source: .autolearn) == 0)
    }

    @Test("reset learned voice by id matches the by-name behaviour exactly")
    func resetParity() async throws {
        func stage(_ source: SwiftDataProfileSource) async throws -> UUID {
            let id = try await source.upsertPerson(named: "Alice")
            try await source.foldIn(
                contentsOf: [TestVectors.unit(seed: 1)], intoPersonWithID: id, source: .enrollment
            )
            try await source.foldIn(
                contentsOf: [TestVectors.unit(seed: 2)], intoPersonWithID: id, source: .autolearn
            )
            return id
        }

        let byName = SwiftDataProfileSource(container: try TestContainer.inMemory())
        _ = try await stage(byName)
        let byID = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let id = try await stage(byID)

        #expect(try await byName.resetLearnedVoice(forProfileNamed: "Alice") == 1)
        #expect(try await byID.resetLearnedVoice(forPersonWithID: id) == 1)

        let left = try #require(try await byName.people().first)
        let right = try #require(try await byID.people().first)
        #expect(left.embeddingCounts == right.embeddingCounts)
    }

    @Test("reset learned voice on a person who is gone throws")
    func resetMissing() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let ghost = UUID()

        await #expect(throws: ProfileSourceError.personNotFound(id: ghost)) {
            try await source.resetLearnedVoice(forPersonWithID: ghost)
        }
    }

    // MARK: - Re-enroll

    @Test("re-enroll clears every embedding, then refills from the new read")
    func reEnroll() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let id = try await source.upsertPerson(named: "Alice")
        try await source.foldIn(
            contentsOf: [TestVectors.unit(seed: 1), TestVectors.unit(seed: 2)],
            intoPersonWithID: id,
            source: .enrollment
        )
        try await source.foldIn(
            contentsOf: [TestVectors.unit(seed: 3)], intoPersonWithID: id, source: .autolearn
        )

        #expect(try await source.removeAllEmbeddings(forPersonWithID: id) == 3)
        #expect(try await source.person(id: id)?.embeddingCount == 0)

        // The person survives the clear — same row, same name, same id.
        let cleared = try #require(try await source.person(id: id))
        #expect(cleared.name == "Alice")

        let outcome = try await source.foldIn(
            contentsOf: [TestVectors.unit(seed: 7), TestVectors.unit(seed: 8)],
            intoPersonWithID: id,
            source: .enrollment
        )
        #expect(outcome.embeddingCount == 2)
        #expect(try await source.person(id: id)?.embeddingCount(source: .enrollment) == 2)
    }

    @Test("re-enroll does not rewind the FIFO cursor")
    func reEnrollKeepsSequence() async throws {
        let container = try TestContainer.inMemory()
        let source = SwiftDataProfileSource(container: container)
        let id = try await source.upsertPerson(named: "Alice")
        try await source.foldIn(
            contentsOf: [TestVectors.unit(seed: 1), TestVectors.unit(seed: 2)],
            intoPersonWithID: id,
            source: .enrollment
        )
        try await source.removeAllEmbeddings(forPersonWithID: id)
        try await source.foldIn(
            contentsOf: [TestVectors.unit(seed: 3)], intoPersonWithID: id, source: .enrollment
        )

        let context = ModelContext(container)
        let person = try #require(try context.person(id: id))
        // Two consumed before the clear, so the survivor is the third.
        #expect(person.embeddingSequence == 3)
        #expect(person.orderedEmbeddings.map(\.sequence) == [3])
    }

    // MARK: - Deleting

    @Test("deleting a person leaves their transcripts, reverting the speaker to unknown")
    func deleteNullifiesSlots() async throws {
        let container = try TestContainer.inMemory()
        let source = SwiftDataProfileSource(container: container)
        let id = try await source.upsertPerson(named: "Alice")
        try await source.foldIn(
            contentsOf: [TestVectors.unit(seed: 1)], intoPersonWithID: id, source: .enrollment
        )

        // A recording whose Speaker A resolved to Alice.
        let recordingID: UUID = try {
            let context = ModelContext(container)
            let recording = Recording(title: "Standup", folderName: "Standup", audioFileName: "Standup.m4a")
            let slot = SpeakerSlot(diarizedSpeaker: "A", clusterEmbedding: TestVectors.unit(seed: 9))
            let utterance = Utterance(index: 0, diarizedSpeaker: "A", text: "morning", startMs: 0, endMs: 900)
            let person = try #require(try context.person(id: id))

            context.insert(recording)
            context.insert(slot)
            context.insert(utterance)
            slot.recording = recording
            slot.assign(person)
            utterance.speakerSlot = slot
            utterance.recording = recording
            try context.save()
            return recording.id
        }()

        // The summary can therefore warn about what delete will touch.
        let summary = try #require(try await source.person(id: id))
        #expect(summary.assignedSlotCount == 1)
        #expect(summary.assignedRecordingCount == 1)

        try await source.deletePerson(id: id)

        let context = ModelContext(container)
        #expect(try context.person(id: id) == nil)

        let recording = try #require(try context.recording(id: recordingID))
        #expect(recording.utterances.count == 1)

        let slot = try #require(recording.speakerSlots.first)
        #expect(slot.person == nil)
        #expect(slot.diarizedSpeaker == "A")
        // No person and no unknown index left: the diarized label is the
        // fallback the editor shows.
        #expect(slot.displayName == "Speaker A")
        // The evidence for re-naming them later survives the delete.
        #expect(slot.hasClusterEmbedding)
    }

    @Test("a person nobody is assigned to reports no transcript impact")
    func deleteImpactWhenUnused() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let summary = try await source.createPerson(named: "Alice")

        #expect(summary.assignedSlotCount == 0)
        #expect(summary.assignedRecordingCount == 0)
    }

    // MARK: - Fold-in by id

    @Test("fold-in by id tags the source and honours the FIFO cap")
    func foldInByID() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let id = try await source.upsertPerson(named: "Alice")

        let vectors = (1...5).map { TestVectors.unit(seed: $0) }
        let outcome = try await source.foldIn(
            contentsOf: vectors, intoPersonWithID: id, source: .upload, at: Date(), cap: 3
        )

        #expect(outcome.stored)
        #expect(!outcome.created)
        #expect(outcome.embeddingCount == 3)
        #expect(outcome.evictedCount == 2)
        #expect(try await source.person(id: id)?.embeddingCount(source: .upload) == 3)
    }

    @Test("fold-in by id on a person who is gone throws rather than creating one")
    func foldInByIDMissing() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let ghost = UUID()

        await #expect(throws: ProfileSourceError.personNotFound(id: ghost)) {
            try await source.foldIn(
                contentsOf: [TestVectors.unit(seed: 1)], intoPersonWithID: ghost, source: .enrollment
            )
        }
        #expect(try await source.people().isEmpty)
    }

    @Test("an unusable vector is refused, and the profile says so")
    func foldInRefusesZero() async throws {
        let source = SwiftDataProfileSource(container: try TestContainer.inMemory())
        let id = try await source.upsertPerson(named: "Alice")

        let outcome = try await source.foldIn(
            contentsOf: [[0, 0, 0]], intoPersonWithID: id, source: .enrollment
        )
        #expect(!outcome.stored)
        #expect(outcome.embeddingCount == 0)
    }
}
