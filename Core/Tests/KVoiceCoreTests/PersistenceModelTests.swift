import Foundation
import SwiftData
import Testing

@testable import KVoiceCore

@Suite("Embedding blob encoding")
struct EmbeddingBlobTests {

    @Test("a vector round-trips exactly")
    func roundTrip() {
        let vector = TestVectors.unit(seed: 7)
        let restored = EmbeddingBlob.vector(from: EmbeddingBlob.data(from: vector))
        #expect(restored == vector)
        #expect(restored.count == 256)
    }

    @Test("a 256-d vector is exactly 1024 bytes")
    func size() {
        #expect(EmbeddingBlob.data(from: TestVectors.unit(seed: 1)).count == 1_024)
    }

    @Test("an empty vector round-trips as empty")
    func empty() {
        #expect(EmbeddingBlob.data(from: []).isEmpty)
        #expect(EmbeddingBlob.vector(from: Data()).isEmpty)
    }

    @Test("bytes are little-endian, so a store is portable")
    func byteOrder() {
        // 1.0f is 0x3F800000; little-endian puts the low byte first.
        #expect(Array(EmbeddingBlob.data(from: [1.0])) == [0x00, 0x00, 0x80, 0x3F])
    }

    @Test("a truncated blob yields the whole floats it does contain")
    func truncated() {
        var data = EmbeddingBlob.data(from: [1, 2, 3])
        data.removeLast(2)
        #expect(EmbeddingBlob.vector(from: data) == [1, 2])
    }

    @Test("any dimension round-trips, so an embedding-backend switch is survivable")
    func dimensionAgnostic() {
        let ecapa = [Float](repeating: 0.5, count: 192)
        #expect(EmbeddingBlob.vector(from: EmbeddingBlob.data(from: ecapa)).count == 192)
    }
}

@Suite("Recording status")
struct RecordingStatusTests {

    @Test("every kind round-trips through the two persisted columns")
    func roundTrip() {
        for kind in RecordingStatus.Kind.allCases {
            let original = RecordingStatus(kind: kind, failureMessage: "boom")
            let restored = RecordingStatus(
                kind: original.kind,
                failureMessage: original.failureMessage
            )
            #expect(restored == original)
        }
    }

    @Test("only failure carries a message")
    func failureMessage() {
        #expect(RecordingStatus.done.failureMessage == nil)
        #expect(RecordingStatus.failed(message: "no network").failureMessage == "no network")
    }

    @Test("a failed row with no stored message still rebuilds")
    func failureWithoutMessage() {
        let status = RecordingStatus(kind: .failed, failureMessage: nil)
        #expect(status.kind == .failed)
        #expect(status.failureMessage?.isEmpty == false)
    }

    @Test("done and failed are terminal; the four working states are in flight")
    func terminality() {
        #expect(RecordingStatus.done.isTerminal)
        #expect(RecordingStatus.failed(message: "x").isTerminal)
        #expect(!RecordingStatus.recorded.isTerminal)

        let inFlight: [RecordingStatus] = [.uploading, .queued, .transcribing, .matching]
        let settled: [RecordingStatus] = [.recorded, .done, .failed(message: "x")]
        #expect(inFlight.map(\.isInFlight) == [true, true, true, true])
        #expect(settled.map(\.isInFlight) == [false, false, false])
    }

    @Test("statuses map onto the spec's progress vocabulary")
    func stages() {
        #expect(RecordingStatus.recorded.stage == nil)
        #expect(RecordingStatus.uploading.stage == .uploading)
        #expect(RecordingStatus.matching.stage == .matchingSpeakers)
        #expect(RecordingStatus.done.stage == .done)
        #expect(RecordingStatus.failed(message: "x").stage == .failed)
    }
}

@Suite("SwiftData model round-trips")
struct PersistenceModelTests {

    @Test("a recording round-trips with its state-machine columns")
    func recordingRoundTrip() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)

        let recording = Recording(
            title: "Standup",
            folderName: "2026-08-13 Standup",
            audioFileName: "2026-08-13 Standup.m4a",
            durationSec: 3_600,
            status: .recorded
        )
        recording.assemblyTranscriptId = "t-42"
        recording.uploadedAudioURLString = "https://cdn.assemblyai.com/upload/x"
        recording.rawResponseFile = "transcript.raw.json"
        context.insert(recording)
        try context.save()

        let reread = ModelContext(container)
        let loaded = try #require(try reread.recording(id: recording.id))
        #expect(loaded.title == "Standup")
        #expect(loaded.folderName == "2026-08-13 Standup")
        #expect(loaded.durationSec == 3_600)
        #expect(loaded.status == .recorded)
        #expect(loaded.assemblyTranscriptId == "t-42")
        #expect(loaded.uploadedAudioURLString == "https://cdn.assemblyai.com/upload/x")
        #expect(loaded.rawResponseFile == "transcript.raw.json")
    }

    @Test("a failure message survives a round-trip and clears on recovery")
    func failureRoundTrip() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)
        let recording = Recording(title: "R", folderName: "R", audioFileName: "R.m4a")
        context.insert(recording)
        recording.setStatus(.failed(message: "the network went away"))
        try context.save()

        let reread = ModelContext(container)
        var loaded = try #require(try reread.recording(id: recording.id))
        #expect(loaded.status == .failed(message: "the network went away"))
        #expect(loaded.statusKindRaw == "failed")

        loaded.setStatus(.done)
        try reread.save()

        loaded = try #require(try ModelContext(container).recording(id: recording.id))
        #expect(loaded.status == .done)
        #expect(loaded.failureMessage == nil)
    }

    @Test("setStatus stamps the transition time")
    func statusTimestamp() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_000)
        let recording = Recording(
            title: "R", folderName: "R", audioFileName: "R.m4a", statusChangedAt: start
        )
        context.insert(recording)
        recording.setStatus(.uploading, at: start.addingTimeInterval(30))
        try context.save()

        #expect(recording.statusChangedAt == start.addingTimeInterval(30))
    }

    @Test("utterances and speaker slots round-trip and stay ordered")
    func relationshipRoundTrip() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)

        let recording = Recording(title: "R", folderName: "R", audioFileName: "R.m4a")
        context.insert(recording)

        let slotA = SpeakerSlot(diarizedSpeaker: "A")
        let slotB = SpeakerSlot(diarizedSpeaker: "B")
        context.insert(slotA)
        context.insert(slotB)
        recording.speakerSlots.append(contentsOf: [slotB, slotA])

        // Inserted out of order on purpose: SwiftData to-many relationships
        // are not order-preserving, which is exactly why `index` exists.
        for index in [2, 0, 1] {
            let utterance = Utterance(
                index: index,
                diarizedSpeaker: index == 1 ? "B" : "A",
                text: "line \(index)",
                startMs: index * 1_000,
                endMs: index * 1_000 + 900
            )
            context.insert(utterance)
            recording.utterances.append(utterance)
            (index == 1 ? slotB : slotA).utterances.append(utterance)
        }
        try context.save()

        let loaded = try #require(try ModelContext(container).recording(id: recording.id))
        #expect(loaded.utterances.count == 3)
        #expect(loaded.orderedUtterances.map(\.index) == [0, 1, 2])
        #expect(loaded.orderedUtterances.map(\.text) == ["line 0", "line 1", "line 2"])
        #expect(loaded.orderedSpeakerSlots.map(\.diarizedSpeaker) == ["A", "B"])
        #expect(loaded.orderedSpeakerSlots[0].utterances.count == 2)
        #expect(loaded.orderedSpeakerSlots[1].utterances.count == 1)
    }

    @Test("an utterance is built from the wire DTO, and words stop at the DB")
    func utteranceFromDTO() throws {
        let dto = Fixture.utterance(speaker: "A", start: 1_000, end: 4_000, wordCount: 12)
        let utterance = Utterance(index: 3, dto: dto)

        #expect(utterance.index == 3)
        #expect(utterance.diarizedSpeaker == "A")
        #expect(utterance.text == dto.text)
        #expect(utterance.startMs == 1_000)
        #expect(utterance.endMs == 4_000)
        #expect(utterance.durationMs == 3_000)
        #expect(utterance.startSeconds == 1.0)
        // The DTO carried 12 words; the row has no place to put them, and
        // that is plan §3 decision 5 rather than an oversight.
        #expect(dto.words.count == 12)
    }

    @Test("deleting a recording cascades to its utterances and slots")
    func cascadeDelete() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)

        let recording = Recording(title: "R", folderName: "R", audioFileName: "R.m4a")
        context.insert(recording)
        let slot = SpeakerSlot(diarizedSpeaker: "A")
        context.insert(slot)
        recording.speakerSlots.append(slot)
        let utterance = Utterance(index: 0, diarizedSpeaker: "A", text: "hi", startMs: 0, endMs: 10)
        context.insert(utterance)
        recording.utterances.append(utterance)
        try context.save()

        context.delete(recording)
        try context.save()

        let reread = ModelContext(container)
        #expect(try reread.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(try reread.fetch(FetchDescriptor<Utterance>()).isEmpty)
        #expect(try reread.fetch(FetchDescriptor<SpeakerSlot>()).isEmpty)
    }

    @Test("deleting a person nullifies its slots but keeps the transcript")
    func personDeleteNullifies() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)

        let recording = Recording(title: "R", folderName: "R", audioFileName: "R.m4a")
        context.insert(recording)
        let person = Person(name: "Alice")
        context.insert(person)
        let slot = SpeakerSlot(diarizedSpeaker: "A", clusterEmbedding: TestVectors.unit(seed: 1))
        context.insert(slot)
        recording.speakerSlots.append(slot)
        slot.assign(person)
        try context.save()

        context.delete(person)
        try context.save()

        let loaded = try #require(try ModelContext(container).recording(id: recording.id))
        #expect(loaded.speakerSlots.count == 1)
        #expect(loaded.speakerSlots[0].person == nil)
        // The voice vector outlives the person — naming someone again later
        // still has something to learn from.
        #expect(loaded.speakerSlots[0].hasClusterEmbedding)
    }

    @Test("a person's embeddings cascade away with them")
    func personCascadesEmbeddings() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)
        let person = Person(name: "Alice")
        context.insert(person)
        for index in 0..<3 {
            let embedding = PersonEmbedding(
                vector: TestVectors.unit(seed: index), source: .enrollment, sequence: index
            )
            context.insert(embedding)
            person.embeddings.append(embedding)
        }
        try context.save()

        context.delete(person)
        try context.save()

        #expect(try ModelContext(container).fetch(FetchDescriptor<PersonEmbedding>()).isEmpty)
    }

    @Test("a person converts to the value type the matcher scores against")
    func personToProfile() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)
        let created = Date(timeIntervalSince1970: 500)
        let person = Person(name: "Alice", createdAt: created)
        context.insert(person)

        // Inserted out of sequence order, to prove `orderedEmbeddings` sorts.
        for sequence in [2, 0, 1] {
            let embedding = PersonEmbedding(
                vector: TestVectors.unit(seed: sequence),
                source: sequence == 0 ? .enrollment : .autolearn,
                sequence: sequence
            )
            context.insert(embedding)
            person.embeddings.append(embedding)
        }
        try context.save()

        let profile = person.profile
        #expect(profile.id == person.id)
        #expect(profile.name == "Alice")
        #expect(profile.createdAt == created)
        #expect(profile.embeddingCount == 3)
        #expect(profile.embeddings.map(\.source) == [.enrollment, .autolearn, .autolearn])
        #expect(profile.vectors[0] == TestVectors.unit(seed: 0))
        #expect(person.embeddingCount(source: .autolearn) == 2)
    }

    @Test("an unrecognized embedding source decodes as autolearn rather than crashing")
    func unknownSource() throws {
        let embedding = PersonEmbedding(vector: [1, 0], source: .enrollment)
        embedding.sourceRaw = "something-from-the-future"
        #expect(embedding.source == .autolearn)
    }
}

@Suite("SpeakerSlot: unknown speakers keep their voice")
struct SpeakerSlotTests {

    @Test("an unmatched slot still persists its cluster embedding")
    func unknownKeepsEmbedding() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)

        let recording = Recording(title: "R", folderName: "R", audioFileName: "R.m4a")
        context.insert(recording)
        let vector = TestVectors.unit(seed: 11)
        let slot = SpeakerSlot(
            diarizedSpeaker: "C",
            clusterEmbedding: vector,
            unknownIndex: 1,
            matchedName: "Alice",
            matchScore: 0.41,
            matchThreshold: 0.62,
            meetsTarget: true,
            spanCount: 4
        )
        context.insert(slot)
        recording.speakerSlots.append(slot)
        try context.save()

        let loaded = try #require(try ModelContext(container).recording(id: recording.id))
        let reloaded = try #require(loaded.speakerSlots.first)
        // This is plan §1's third deliberate choice, and the reason naming an
        // unknown speaker weeks later can still feed auto-learn.
        #expect(reloaded.clusterEmbedding == vector)
        #expect(reloaded.hasClusterEmbedding)
        #expect(reloaded.isUnknown)
        #expect(reloaded.displayName == "Unknown Speaker 1")
        // The near-miss is kept so the user sees who it nearly was.
        #expect(reloaded.matchedName == "Alice")
        #expect(reloaded.matchScore == 0.41)
        #expect(reloaded.matchThreshold == 0.62)
        #expect(reloaded.spanCount == 4)
    }

    @Test("a slot with no embeddable audio reports that honestly")
    func noEmbedding() {
        let slot = SpeakerSlot(diarizedSpeaker: "D", clusterEmbedding: [])
        #expect(!slot.hasClusterEmbedding)
        #expect(slot.clusterEmbedding.isEmpty)
    }

    @Test("assigning a person clears the unknown placeholder")
    func assign() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)
        let person = Person(name: "Bob")
        context.insert(person)
        let slot = SpeakerSlot(diarizedSpeaker: "B", clusterEmbedding: TestVectors.unit(seed: 2), unknownIndex: 2)
        context.insert(slot)

        slot.assign(person)
        try context.save()

        #expect(slot.person?.name == "Bob")
        #expect(slot.unknownIndex == nil)
        #expect(slot.isConfirmed)
        #expect(!slot.isUnknown)
        #expect(slot.displayName == "Bob")
    }

    @Test("clearing a person restores an unknown placeholder")
    func clearPerson() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)
        let person = Person(name: "Bob")
        context.insert(person)
        let slot = SpeakerSlot(diarizedSpeaker: "B")
        context.insert(slot)
        slot.assign(person)

        slot.clearPerson(unknownIndex: 3)
        try context.save()

        #expect(slot.person == nil)
        #expect(slot.unknownIndex == 3)
        #expect(!slot.isConfirmed)
        #expect(slot.displayName == "Unknown Speaker 3")
    }

    @Test("a slot with neither person nor unknown index falls back to its letter")
    func bareLetter() {
        #expect(SpeakerSlot(diarizedSpeaker: "E").displayName == "Speaker E")
    }
}

@Suite("Model container and queries")
struct ModelContainerTests {

    @Test("the in-memory container writes nothing to disk")
    func inMemoryIsIsolated() throws {
        // Through `TestContainer` rather than `KVoiceSchema` directly: every
        // container in the suite has to take the same creation lock, or the
        // serialization has a hole in it. The helper calls straight through.
        let first = try TestContainer.inMemory()
        let context = ModelContext(first)
        context.insert(Recording(title: "R", folderName: "R", audioFileName: "R.m4a"))
        try context.save()

        // A second container is a genuinely separate store.
        let second = try TestContainer.inMemory()
        #expect(try ModelContext(second).fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(try ModelContext(first).fetch(FetchDescriptor<Recording>()).count == 1)
    }

    @Test("an on-disk container persists across container instances")
    func onDiskPersists() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let id: UUID
        do {
            let container = try TestContainer.onDisk(inLibraryRoot: directory.url)
            let context = ModelContext(container)
            let recording = Recording(title: "R", folderName: "R", audioFileName: "R.m4a")
            context.insert(recording)
            try context.save()
            id = recording.id
        }

        let reopened = try TestContainer.onDisk(inLibraryRoot: directory.url)
        let loaded = try ModelContext(reopened).recording(id: id)
        #expect(loaded?.title == "R")
        #expect(
            FileManager.default.fileExists(
                atPath: directory.url.appendingPathComponent(KVoiceSchema.storeFileName).path
            )
        )
    }

    @Test("the schema lists every model")
    func schemaCoverage() {
        #expect(KVoiceSchema.models.count == 5)
    }

    @Test("looking a person up by name is case- and whitespace-insensitive")
    func personByName() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)
        context.insert(Person(name: "Alice Example"))
        try context.save()

        #expect(try context.person(named: "alice example")?.name == "Alice Example")
        #expect(try context.person(named: "  ALICE EXAMPLE  ")?.name == "Alice Example")
        #expect(try context.person(named: "Bob") == nil)
        #expect(try context.person(named: "   ") == nil)
    }

    @Test("in-flight recordings are exactly the ones a relaunch must resume")
    func inFlightQuery() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)

        let statuses: [RecordingStatus] = [
            .recorded, .uploading, .queued, .transcribing, .matching, .done, .failed(message: "x")
        ]
        for (index, status) in statuses.enumerated() {
            let recording = Recording(
                title: "R\(index)",
                folderName: "R\(index)",
                audioFileName: "R\(index).m4a",
                status: status,
                statusChangedAt: Date(timeIntervalSince1970: Double(index))
            )
            context.insert(recording)
        }
        try context.save()

        let inFlight = try context.inFlightRecordings()
        #expect(inFlight.map(\.title) == ["R1", "R2", "R3", "R4"])
    }

    @Test("a recording resolves its files against the configurable library root")
    func fileLayout() {
        let recording = Recording(
            title: "Standup",
            folderName: "2026-08-13 Standup",
            audioFileName: "2026-08-13 Standup.m4a"
        )
        recording.rawResponseFile = "transcript.raw.json"
        let root = URL(fileURLWithPath: "/tmp/Library")

        #expect(recording.audioURL(inRoot: root).path == "/tmp/Library/2026-08-13 Standup/2026-08-13 Standup.m4a")
        #expect(recording.rawResponseURL(inRoot: root)?.lastPathComponent == "transcript.raw.json")

        let folder = recording.folder(inRoot: root)
        #expect(folder.baseName == "2026-08-13 Standup")
        #expect(folder.audioFileExtension == "m4a")
        #expect(folder.audioURL == recording.audioURL(inRoot: root))
    }

    @Test("no raw response file means no raw response URL")
    func noRawResponse() {
        let recording = Recording(title: "R", folderName: "R", audioFileName: "R.m4a")
        #expect(recording.rawResponseURL(inRoot: URL(fileURLWithPath: "/tmp")) == nil)
    }

    @Test("participant names come from resolved slots only")
    func participants() throws {
        let container = try TestContainer.inMemory()
        let context = ModelContext(container)
        let recording = Recording(title: "R", folderName: "R", audioFileName: "R.m4a")
        context.insert(recording)

        let alice = Person(name: "Alice")
        context.insert(alice)
        let known = SpeakerSlot(diarizedSpeaker: "A")
        context.insert(known)
        recording.speakerSlots.append(known)
        known.assign(alice)

        let unknown = SpeakerSlot(diarizedSpeaker: "B", unknownIndex: 1)
        context.insert(unknown)
        recording.speakerSlots.append(unknown)
        try context.save()

        #expect(recording.participantNames == ["Alice"])
    }
}
