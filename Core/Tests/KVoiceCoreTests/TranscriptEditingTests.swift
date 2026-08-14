import Foundation
import SwiftData
import Testing

@testable import KVoiceCore

// MARK: - Fixture

/// A recording with slots and utterances already wired up, in one context.
///
/// Local to this file rather than added to `PersistenceTestSupport`: these are
/// the only tests that need a transcript shaped by *speaker*, and a shared
/// helper would have to grow options none of the others want.
private struct EditableTranscript {

    let container: ModelContainer
    let context: ModelContext
    let recording: Recording
    private(set) var slots: [String: SpeakerSlot] = [:]

    /// - Parameter script: `(diarized letter, text)` in transcript order.
    init(_ script: [(String, String)], embeddings: [String: [Float]] = [:]) throws {
        self.container = try TestContainer.inMemory()
        self.context = ModelContext(container)

        let recording = Recording(title: "Standup", folderName: "Standup", audioFileName: "Standup.m4a")
        context.insert(recording)
        self.recording = recording

        for letter in Set(script.map(\.0)).sorted() {
            let slot = SpeakerSlot(
                diarizedSpeaker: letter,
                clusterEmbedding: embeddings[letter] ?? TestVectors.unit(seed: Int(letter.utf8.first ?? 65))
            )
            context.insert(slot)
            recording.speakerSlots.append(slot)
            slot.recording = recording
            slots[letter] = slot
        }

        for (index, entry) in script.enumerated() {
            let utterance = Utterance(
                index: index,
                diarizedSpeaker: entry.0,
                text: entry.1,
                startMs: index * 5_000,
                endMs: index * 5_000 + 4_000
            )
            context.insert(utterance)
            recording.utterances.append(utterance)
            slots[entry.0]?.utterances.append(utterance)
        }

        recording.renumberUnknownSpeakers()
        try context.save()
    }

    func slot(_ letter: String) throws -> SpeakerSlot {
        try #require(slots[letter])
    }

    /// Adds a person to the store and returns the row.
    @discardableResult
    func person(named name: String) throws -> Person {
        let person = Person(name: name)
        context.insert(person)
        try context.save()
        return person
    }

    /// Re-reads the recording through a *fresh* context — the only honest way
    /// to assert that a mutation was persisted rather than merely performed.
    func reloaded() throws -> Recording {
        try context.save()
        return try #require(try ModelContext(container).recording(id: recording.id))
    }

    /// The transcript as the editor and the exporters see it: display names,
    /// grouped by `TranscriptDocument`.
    func turns() -> [TranscriptDocument.Turn] {
        TranscriptDocument.turns(
            from: recording.orderedUtterances.map {
                TranscriptDocument.Utterance(
                    speaker: $0.speakerSlot?.displayName ?? "",
                    startMs: $0.startMs,
                    text: $0.text
                )
            }
        )
    }
}

// MARK: - Labels

@Suite("Transcript editing — diarized labels")
struct DiarizedLabelTests {

    @Test("labels are bijective base-26, matching the provider's alphabet")
    func alphabet() {
        #expect(Recording.diarizedLabel(ordinal: 0) == "A")
        #expect(Recording.diarizedLabel(ordinal: 1) == "B")
        #expect(Recording.diarizedLabel(ordinal: 25) == "Z")
        #expect(Recording.diarizedLabel(ordinal: 26) == "AA")
        #expect(Recording.diarizedLabel(ordinal: 27) == "AB")
        #expect(Recording.diarizedLabel(ordinal: 51) == "AZ")
        #expect(Recording.diarizedLabel(ordinal: 52) == "BA")
    }

    @Test("a negative ordinal degrades to the first label rather than trapping")
    func negative() {
        #expect(Recording.diarizedLabel(ordinal: -5) == "A")
    }

    @Test("the next label skips every one already in use")
    func nextLabel() throws {
        let fixture = try EditableTranscript([("A", "one"), ("B", "two")])
        #expect(fixture.recording.nextDiarizedSpeakerLabel() == "C")

        // Gaps are filled before the alphabet is extended: the label only has
        // to be unique, and a transcript reading A, B, D is confusing.
        let sparse = try EditableTranscript([("A", "one"), ("C", "two")])
        #expect(sparse.recording.nextDiarizedSpeakerLabel() == "B")
    }
}

// MARK: - Unknown numbering

@Suite("Transcript editing — unknown speaker numbering")
struct UnknownSpeakerNumberingTests {

    @Test("unnamed slots are numbered 1…N in label order")
    func numbering() throws {
        let fixture = try EditableTranscript([("A", "one"), ("B", "two"), ("C", "three")])

        #expect(fixture.recording.renumberUnknownSpeakers() == 3)
        #expect(fixture.recording.orderedSpeakerSlots.map(\.displayName) == [
            "Unknown Speaker 1", "Unknown Speaker 2", "Unknown Speaker 3"
        ])
    }

    @Test("naming a speaker closes the gap it left behind")
    func namingRenumbers() throws {
        let fixture = try EditableTranscript([("A", "one"), ("B", "two"), ("C", "three")])
        let bob = try fixture.person(named: "Bob")

        try fixture.slot("A").assign(bob)
        #expect(fixture.recording.renumberUnknownSpeakers() == 2)

        // B and C become 1 and 2 — the same numbers a re-process would mint,
        // so the label never depends on the edit history.
        #expect(fixture.recording.orderedSpeakerSlots.map(\.displayName) == [
            "Bob", "Unknown Speaker 1", "Unknown Speaker 2"
        ])
    }

    @Test("a named slot never keeps an unknown placeholder")
    func namedSlotClearsPlaceholder() throws {
        let fixture = try EditableTranscript([("A", "one")])
        let slot = try fixture.slot("A")
        slot.unknownIndex = 7
        slot.person = try fixture.person(named: "Ann")

        fixture.recording.renumberUnknownSpeakers()
        #expect(slot.unknownIndex == nil)
        #expect(slot.displayName == "Ann")
    }
}

// MARK: - Single-utterance reassignment

@Suite("Transcript editing — reassign one utterance")
struct ReassignUtteranceTests {

    @Test("an utterance moves slot, and its diarized label moves with it")
    func moves() throws {
        let fixture = try EditableTranscript([("A", "one"), ("B", "two"), ("A", "three")])
        let target = try fixture.slot("B")
        let utterance = fixture.recording.orderedUtterances[0]

        fixture.recording.reassign(utterance, to: target)

        #expect(utterance.diarizedSpeaker == "B")
        #expect(try fixture.slot("A").utterances.map(\.index) == [2])
        #expect(target.utterances.map(\.index).sorted() == [0, 1])
    }

    @Test("the move survives a round-trip through a fresh context")
    func persists() throws {
        let fixture = try EditableTranscript([("A", "one"), ("B", "two")])
        fixture.recording.reassign(fixture.recording.orderedUtterances[0], to: try fixture.slot("B"))

        let reloaded = try fixture.reloaded()
        let slotB = try #require(reloaded.speakerSlot(labeled: "B"))
        #expect(slotB.utterances.count == 2)
        #expect(reloaded.speakerSlot(labeled: "A")?.utterances.isEmpty == true)
        #expect(reloaded.orderedUtterances.map(\.diarizedSpeaker) == ["B", "B"])
    }

    @Test("reassigning to the slot it already has changes nothing")
    func noOp() throws {
        let fixture = try EditableTranscript([("A", "one"), ("A", "two")])
        let slot = try fixture.slot("A")

        fixture.recording.reassign(fixture.recording.orderedUtterances[0], to: slot)

        // The guard matters: without it the remove-then-append would reorder
        // the array, and a duplicate append would double the paragraph.
        #expect(slot.utterances.count == 2)
        #expect(slot.utterances.map(\.index).sorted() == [0, 1])
    }

    @Test("a slot minted for a person carries no embedding, so it cannot auto-learn")
    func syntheticSlot() throws {
        let fixture = try EditableTranscript([("A", "one"), ("B", "two")])
        let carol = try fixture.person(named: "Carol")

        let slot = fixture.recording.addSpeakerSlot(for: carol, in: fixture.context)

        #expect(slot.diarizedSpeaker == "C")
        #expect(slot.displayName == "Carol")
        #expect(slot.isConfirmed)
        // Exactly one new slot, attached both ways: the inverse relationship
        // is maintained by SwiftData, not set by hand, so it neither
        // duplicates nor goes missing.
        #expect(fixture.recording.speakerSlots.count == 3)
        #expect(slot.recording?.id == fixture.recording.id)
        // Nothing was *measured* about this voice — one line of text was
        // asserted. `hasClusterEmbedding` false is what keeps a fabricated
        // vector out of Carol's profile.
        #expect(!slot.hasClusterEmbedding)
        #expect(slot.spanCount == 0)
        #expect(!slot.meetsTarget)
    }

    @Test("an utterance moved to a new person's slot renders under that name")
    func reassignToNewPerson() throws {
        let fixture = try EditableTranscript([("A", "hello"), ("A", "goodbye")])
        let dave = try fixture.person(named: "Dave")

        let slot = fixture.recording.addSpeakerSlot(for: dave, in: fixture.context)
        fixture.recording.reassign(fixture.recording.orderedUtterances[1], to: slot)

        #expect(fixture.turns().map(\.speaker) == ["Unknown Speaker 1", "Dave"])
        #expect(fixture.turns().map(\.paragraphs) == [["hello"], ["goodbye"]])
    }
}

// MARK: - Merge

@Suite("Transcript editing — merge two diarized speakers")
struct MergeSpeakerTests {

    @Test("every utterance ends up under one slot and the other is gone")
    func merges() throws {
        let fixture = try EditableTranscript([
            ("A", "one"), ("B", "two"), ("A", "three"), ("B", "four")
        ])
        let destination = try fixture.slot("A")
        let source = try fixture.slot("B")

        let outcome = fixture.recording.mergeSpeakerSlot(source, into: destination, in: fixture.context)

        #expect(outcome.movedUtteranceCount == 2)
        #expect(outcome.absorbedLabel == "B")
        #expect(outcome.survivingLabel == "A")
        #expect(fixture.recording.speakerSlots.count == 1)
        #expect(destination.utterances.count == 4)
        #expect(fixture.recording.orderedUtterances.allSatisfy { $0.diarizedSpeaker == "A" })
    }

    @Test("the merge is persisted, not merely performed")
    func persists() throws {
        let fixture = try EditableTranscript([("A", "one"), ("B", "two"), ("A", "three")])
        fixture.recording.mergeSpeakerSlot(
            try fixture.slot("B"), into: try fixture.slot("A"), in: fixture.context
        )

        let reloaded = try fixture.reloaded()
        #expect(reloaded.speakerSlots.count == 1)
        #expect(reloaded.speakerSlot(labeled: "B") == nil)
        #expect(reloaded.orderedSpeakerSlots[0].utterances.count == 3)
        // No orphans: every utterance still points at a live slot.
        #expect(reloaded.orderedUtterances.allSatisfy { $0.speakerSlot != nil })
    }

    @Test("a merged transcript collapses into one turn, 1:1 with its utterances")
    func regroups() throws {
        let fixture = try EditableTranscript([
            ("A", "one"), ("B", "two"), ("A", "three"), ("B", "four")
        ])

        // Before: diarization split one person into four alternating turns.
        #expect(fixture.turns().count == 4)

        fixture.recording.mergeSpeakerSlot(
            try fixture.slot("B"), into: try fixture.slot("A"), in: fixture.context
        )

        // After: one turn whose paragraphs are still exactly the utterances,
        // in order — the invariant the editor maps paragraphs back through.
        let turns = fixture.turns()
        #expect(turns.count == 1)
        #expect(turns[0].paragraphs == ["one", "two", "three", "four"])
        #expect(turns.reduce(0) { $0 + $1.paragraphs.count } == fixture.recording.utterances.count)
    }

    @Test("the absorbed slot's embedding comes back for auto-learn")
    func returnsEmbedding() throws {
        let voiceOfB = TestVectors.unit(seed: 42)
        let fixture = try EditableTranscript(
            [("A", "one"), ("B", "two")],
            embeddings: ["B": voiceOfB]
        )
        let bob = try fixture.person(named: "Bob")
        try fixture.slot("A").assign(bob)

        let outcome = fixture.recording.mergeSpeakerSlot(
            try fixture.slot("B"), into: try fixture.slot("A"), in: fixture.context
        )

        // The caller folds this into Bob's profile: the user has just said
        // that this second cluster is also Bob (spec §4).
        #expect(isSameDirection(outcome.absorbedClusterEmbedding, voiceOfB))
        #expect(outcome.personID == bob.id)
    }

    @Test("merging closes the unknown-speaker gap the deletion would leave")
    func renumbers() throws {
        let fixture = try EditableTranscript([("A", "one"), ("B", "two"), ("C", "three")])
        #expect(fixture.recording.orderedSpeakerSlots.map(\.unknownIndex) == [1, 2, 3])

        fixture.recording.mergeSpeakerSlot(
            try fixture.slot("B"), into: try fixture.slot("A"), in: fixture.context
        )

        // Without the renumber the survivors would read "Unknown Speaker 1"
        // and "Unknown Speaker 3".
        #expect(fixture.recording.orderedSpeakerSlots.map(\.displayName) == [
            "Unknown Speaker 1", "Unknown Speaker 2"
        ])
    }

    @Test("the surviving slot keeps its own person and embedding")
    func survivorUnchanged() throws {
        let voiceOfA = TestVectors.unit(seed: 3)
        let fixture = try EditableTranscript(
            [("A", "one"), ("B", "two")],
            embeddings: ["A": voiceOfA]
        )
        let ann = try fixture.person(named: "Ann")
        try fixture.slot("A").assign(ann)

        fixture.recording.mergeSpeakerSlot(
            try fixture.slot("B"), into: try fixture.slot("A"), in: fixture.context
        )

        let survivor = try #require(fixture.recording.speakerSlot(labeled: "A"))
        #expect(survivor.person?.id == ann.id)
        // Not averaged with B's: the durable home for a second observation is
        // the person's profile, where the matcher takes the max over vectors.
        #expect(isSameDirection(survivor.clusterEmbedding, voiceOfA))
    }

    @Test("merging a slot into itself is a no-op, not a self-destruction")
    func selfMerge() throws {
        let fixture = try EditableTranscript([("A", "one"), ("A", "two")])
        let slot = try fixture.slot("A")

        let outcome = fixture.recording.mergeSpeakerSlot(slot, into: slot, in: fixture.context)

        #expect(outcome.movedUtteranceCount == 0)
        #expect(fixture.recording.speakerSlots.count == 1)
        #expect(slot.utterances.count == 2)
    }

    @Test("a person's slot can be found by id, so a reassignment reuses it")
    func lookupByPersonID() throws {
        let fixture = try EditableTranscript([("A", "one"), ("B", "two")])
        let eve = try fixture.person(named: "Eve")
        try fixture.slot("B").assign(eve)

        #expect(fixture.recording.speakerSlot(forPersonID: eve.id)?.diarizedSpeaker == "B")
        #expect(fixture.recording.speakerSlot(forPersonID: UUID()) == nil)
    }
}

// MARK: - The invariant the editor maps through

/// The editor renders `TranscriptDocument`'s turns but has to map every
/// paragraph back to the `Utterance` row it came from, so that clicking one
/// seeks to the right offset and typing in it edits the right row. It does that
/// by walking the surviving utterances in parallel with the paragraphs — which
/// is only correct because of the positional correspondence asserted here.
///
/// These tests exist so that a future change to the grouping rules fails *here*,
/// loudly, rather than silently misaligning the editor's click targets.
@Suite("Transcript editing — paragraph/utterance correspondence")
struct ParagraphCorrespondenceTests {

    /// A mixed input: repeated speakers, alternation, blanks in three
    /// positions, and whitespace-only text.
    private static let utterances: [TranscriptDocument.Utterance] = [
        .init(speaker: "Ada", startMs: 0, text: "one"),
        .init(speaker: "Ada", startMs: 1_000, text: "   "),
        .init(speaker: "Ada", startMs: 2_000, text: "two"),
        .init(speaker: "Bob", startMs: 3_000, text: "three"),
        .init(speaker: "Bob", startMs: 4_000, text: ""),
        .init(speaker: "Ada", startMs: 5_000, text: "four"),
        .init(speaker: "Ada", startMs: 6_000, text: "  five  ")
    ]

    @Test("paragraphs total exactly the non-blank utterances")
    func totals() {
        let turns = TranscriptDocument.turns(from: Self.utterances)
        let surviving = Self.utterances.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        #expect(turns.reduce(0) { $0 + $1.paragraphs.count } == surviving.count)
    }

    @Test("the k-th paragraph is the k-th surviving utterance, in order")
    func positional() {
        let turns = TranscriptDocument.turns(from: Self.utterances)
        let surviving = Self.utterances.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let flattened = turns.flatMap(\.paragraphs)
        let expected = surviving.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(flattened == expected)

        // And the speaker of each paragraph's turn is that utterance's speaker,
        // which is what lets a turn header address the right speaker slot.
        let speakerPerParagraph = turns.flatMap { turn in
            Array(repeating: turn.speaker, count: turn.paragraphs.count)
        }
        #expect(speakerPerParagraph == surviving.map(\.speaker))
    }

    @Test("a transcript with no blanks maps one paragraph per utterance")
    func dense() {
        let dense = (0..<50).map {
            TranscriptDocument.Utterance(
                speaker: $0.isMultiple(of: 3) ? "Ada" : "Bob",
                startMs: $0 * 1_000,
                text: "line \($0)"
            )
        }
        let turns = TranscriptDocument.turns(from: dense)
        #expect(turns.flatMap(\.paragraphs) == dense.map(\.text))
    }
}

// MARK: - Export from rows

/// The claim the spec makes about exports: they carry what the user edited and
/// the names they assigned, never the provider's original response.
@Suite("Transcript editing — exporting current state")
struct EditedTranscriptExportTests {

    @Test("an export carries the edited text, not what the provider sent")
    func editedText() throws {
        let fixture = try EditableTranscript([("A", "we shipped it"), ("B", "nice")])

        // What the editor's debounced write does to a row.
        fixture.recording.orderedUtterances[0].text = "we shipped Universal-3"
        fixture.recording.orderedUtterances[0].isEdited = true

        let document = TranscriptDocument(recording: try fixture.reloaded())
        #expect(document.turns.map(\.paragraphs) == [["we shipped Universal-3"], ["nice"]])
    }

    @Test("an export carries assigned speaker names, and labels the rest")
    func speakerNames() throws {
        let fixture = try EditableTranscript([("A", "morning"), ("B", "morning")])
        try fixture.slot("A").assign(try fixture.person(named: "Ada"))
        fixture.recording.renumberUnknownSpeakers()

        let document = TranscriptDocument(recording: try fixture.reloaded())
        #expect(document.turns.map(\.speaker) == ["Ada", "Unknown Speaker 1"])
    }

    @Test("two slots named as one person collapse into a single turn")
    func namingMerges() throws {
        let fixture = try EditableTranscript([
            ("A", "one"), ("B", "two"), ("A", "three"), ("B", "four")
        ])
        let bea = try fixture.person(named: "Bea")
        try fixture.slot("A").assign(bea)
        try fixture.slot("B").assign(bea)

        // Core groups by *display name*, so naming both slots has the same
        // visible effect as merging them — worth knowing, because it is why
        // the editor addresses turn-level operations by slot and not by name.
        let document = TranscriptDocument(recording: try fixture.reloaded())
        #expect(document.turns.count == 1)
        #expect(document.turns[0].speaker == "Bea")
        #expect(document.turns[0].paragraphs == ["one", "two", "three", "four"])
    }

    @Test("all three formats render the edited transcript into a folder")
    func writesEveryFormat() throws {
        let fixture = try EditableTranscript([("A", "first line"), ("B", "second line")])
        try fixture.slot("A").assign(try fixture.person(named: "Cleo"))
        fixture.recording.renumberUnknownSpeakers()

        let folder = try TemporaryDirectory()
        defer { folder.cleanUp() }

        let document = TranscriptDocument(recording: try fixture.reloaded())
        for format in ExportFormat.allCases {
            let url = try Exporter.export(document, as: format, to: folder.url)
            #expect(url.lastPathComponent == "Standup.\(format.fileExtension)")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        let markdown = try String(
            contentsOf: folder.url.appendingPathComponent("Standup.md"), encoding: .utf8
        )
        #expect(markdown.contains("## Cleo — [00:00:00]"))
        #expect(markdown.contains("## Unknown Speaker 1 — [00:00:05]"))
        #expect(markdown.contains("first line"))
    }

    @Test("re-exporting after an edit refreshes the file instead of adding another")
    func overwrites() throws {
        let fixture = try EditableTranscript([("A", "before")])
        let folder = try TemporaryDirectory()
        defer { folder.cleanUp() }

        try Exporter.export(
            TranscriptDocument(recording: fixture.recording), as: .markdown, to: folder.url
        )

        fixture.recording.orderedUtterances[0].text = "after"
        let second = try Exporter.export(
            TranscriptDocument(recording: try fixture.reloaded()), as: .markdown, to: folder.url
        )

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(files.filter { $0.hasSuffix(".md") } == ["Standup.md"])
        #expect(try String(contentsOf: second, encoding: .utf8).contains("after"))
    }
}
