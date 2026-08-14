import Foundation
import Testing

@testable import KVoiceCore

/// Turn grouping: the step that turns a flat utterance list into the speaker
/// turns every export renders — and, from Phase 5, what the transcript editor
/// displays. Both the documents and the UI inherit whatever this decides, so
/// the edge cases are pinned down here rather than inside a renderer.
@Suite("Export transcript document")
struct ExportTranscriptDocumentTests {

    private func turns(_ utterances: [TranscriptDocument.Utterance]) -> [TranscriptDocument.Turn] {
        TranscriptDocument.turns(from: utterances)
    }

    // MARK: - Empty and trivial input

    @Test("no utterances produce no turns")
    func emptyInput() {
        #expect(turns([]).isEmpty)
    }

    @Test("a single utterance is a single one-paragraph turn")
    func singleUtterance() {
        let result = turns([ExportFixture.utterance("Alice", 1_500, "Hello.")])

        #expect(result.count == 1)
        #expect(result.first?.speaker == "Alice")
        #expect(result.first?.startMs == 1_500)
        #expect(result.first?.paragraphs == ["Hello."])
    }

    // MARK: - Merging

    @Test("consecutive utterances by one speaker merge into a single turn")
    func singleSpeakerMerges() {
        let result = turns([
            ExportFixture.utterance("Alice", 1_000, "One."),
            ExportFixture.utterance("Alice", 2_000, "Two."),
            ExportFixture.utterance("Alice", 3_000, "Three.")
        ])

        #expect(result.count == 1)
        #expect(result.first?.paragraphs == ["One.", "Two.", "Three."])
    }

    /// The header must say when the speaker started talking, not when their
    /// last sentence did.
    @Test("a merged turn is stamped with its first utterance's start")
    func mergedTurnKeepsFirstStart() {
        let result = turns([
            ExportFixture.utterance("Alice", 1_000, "One."),
            ExportFixture.utterance("Alice", 2_000, "Two.")
        ])

        #expect(result.first?.startMs == 1_000)
    }

    @Test("alternating speakers produce one turn each, in order")
    func alternatingSpeakers() {
        let result = turns([
            ExportFixture.utterance("Alice", 0, "Hi."),
            ExportFixture.utterance("Bob", 1_000, "Hello."),
            ExportFixture.utterance("Alice", 2_000, "How are you?"),
            ExportFixture.utterance("Bob", 3_000, "Fine.")
        ])

        #expect(result.map(\.speaker) == ["Alice", "Bob", "Alice", "Bob"])
        #expect(result.map(\.startMs) == [0, 1_000, 2_000, 3_000])
        #expect(result.allSatisfy { $0.paragraphs.count == 1 })
    }

    @Test("a speaker returning later starts a new turn rather than rejoining the old one")
    func returningSpeakerStartsNewTurn() {
        let result = turns([
            ExportFixture.utterance("Alice", 0, "First."),
            ExportFixture.utterance("Bob", 1_000, "Interjection."),
            ExportFixture.utterance("Alice", 2_000, "Second.")
        ])

        #expect(result.count == 3)
        #expect(result.last?.paragraphs == ["Second."])
    }

    /// Paragraph *i* of a turn is the *i*-th surviving utterance of that run —
    /// the invariant the editor uses to map a paragraph back to its row.
    @Test("each utterance becomes exactly one paragraph, in input order")
    func oneParagraphPerUtterance() {
        let texts = (1...5).map { "Sentence \($0)." }
        let result = turns(texts.enumerated().map { ExportFixture.utterance("Alice", $0.offset * 1_000, $0.element) })

        #expect(result.count == 1)
        #expect(result.first?.paragraphs == texts)
    }

    @Test("input order is preserved even when timestamps are not ascending")
    func inputOrderWins() {
        let result = turns([
            ExportFixture.utterance("Alice", 9_000, "Later stamp, first row."),
            ExportFixture.utterance("Bob", 1_000, "Earlier stamp, second row.")
        ])

        #expect(result.map(\.startMs) == [9_000, 1_000])
    }

    // MARK: - Blank text

    @Test("an utterance edited down to nothing contributes no paragraph")
    func blankUtterancesAreDropped() {
        let result = turns([
            ExportFixture.utterance("Alice", 0, "Kept."),
            ExportFixture.utterance("Alice", 1_000, ""),
            ExportFixture.utterance("Alice", 2_000, "   \n  ")
        ])

        #expect(result.count == 1)
        #expect(result.first?.paragraphs == ["Kept."])
    }

    @Test("only blank utterances produce no turns at all")
    func allBlankInput() {
        #expect(turns([
            ExportFixture.utterance("Alice", 0, ""),
            ExportFixture.utterance("Bob", 1_000, "   ")
        ]).isEmpty)
    }

    /// Dropping the blank first means the surrounding utterances are still
    /// "consecutive", so an emptied row cannot silently split a turn in two.
    @Test("a blank utterance between two by the same speaker does not split the turn")
    func blankDoesNotSplitTurn() {
        let result = turns([
            ExportFixture.utterance("Alice", 0, "Before."),
            ExportFixture.utterance("Bob", 1_000, ""),
            ExportFixture.utterance("Alice", 2_000, "After.")
        ])

        #expect(result.count == 1)
        #expect(result.first?.paragraphs == ["Before.", "After."])
    }

    @Test("paragraph text is trimmed of surrounding whitespace")
    func textIsTrimmed() {
        let result = turns([ExportFixture.utterance("Alice", 0, "  Padded.\n")])

        #expect(result.first?.paragraphs == ["Padded."])
    }

    @Test("whitespace inside a paragraph is left alone")
    func interiorTextIsUntouched() {
        let result = turns([ExportFixture.utterance("Alice", 0, "Two  spaces and a\ttab.")])

        #expect(result.first?.paragraphs == ["Two  spaces and a\ttab."])
    }

    // MARK: - Speaker names

    @Test("a blank speaker name falls back to the unknown-speaker label")
    func blankSpeakerFallsBack() {
        let result = turns([
            ExportFixture.utterance("", 0, "Who said this?"),
            ExportFixture.utterance("   ", 1_000, "Same voice.")
        ])

        #expect(result.count == 1)
        #expect(result.first?.speaker == TranscriptDocument.defaultUnknownSpeakerLabel)
    }

    @Test("the unknown-speaker label is caller-supplied")
    func customUnknownLabel() {
        let result = TranscriptDocument.turns(
            from: [ExportFixture.utterance("", 0, "Anonymous.")],
            unknownSpeakerLabel: "Speaker A"
        )

        #expect(result.first?.speaker == "Speaker A")
    }

    /// The app numbers unknown speakers per recording ("Unknown Speaker 1",
    /// "Unknown Speaker 2"); those are different people and must not merge.
    @Test("differently numbered unknown speakers stay separate turns")
    func numberedUnknownSpeakersDoNotMerge() {
        let result = turns([
            ExportFixture.utterance("Unknown Speaker 1", 0, "First voice."),
            ExportFixture.utterance("Unknown Speaker 2", 1_000, "Second voice."),
            ExportFixture.utterance("Unknown Speaker 1", 2_000, "First again.")
        ])

        #expect(result.map(\.speaker) == ["Unknown Speaker 1", "Unknown Speaker 2", "Unknown Speaker 1"])
    }

    @Test("an unknown speaker merges with itself across consecutive utterances")
    func unknownSpeakerMergesWithItself() {
        let result = turns([
            ExportFixture.utterance("Unknown Speaker 2", 0, "One."),
            ExportFixture.utterance("Unknown Speaker 2", 1_000, "Two.")
        ])

        #expect(result.count == 1)
        #expect(result.first?.paragraphs.count == 2)
    }

    @Test("speaker names are trimmed, so spacing differences do not split a turn")
    func speakerNamesAreTrimmed() {
        let result = turns([
            ExportFixture.utterance("Alice", 0, "One."),
            ExportFixture.utterance("  Alice  ", 1_000, "Two.")
        ])

        #expect(result.count == 1)
        #expect(result.first?.speaker == "Alice")
    }

    @Test("speaker matching is case-sensitive, because names are user-entered")
    func speakerMatchingIsCaseSensitive() {
        let result = turns([
            ExportFixture.utterance("Alice", 0, "One."),
            ExportFixture.utterance("alice", 1_000, "Two.")
        ])

        #expect(result.count == 2)
    }

    // MARK: - Document

    @Test("the utterance initializer groups exactly like the standalone helper")
    func initializerMatchesHelper() {
        let utterances = [
            ExportFixture.utterance("Alice", 0, "One."),
            ExportFixture.utterance("Alice", 1_000, "Two."),
            ExportFixture.utterance("Bob", 2_000, "Three.")
        ]
        let document = TranscriptDocument(title: "T", date: .distantPast, utterances: utterances)

        #expect(document.turns == TranscriptDocument.turns(from: utterances))
        #expect(document.turns.count == 2)
    }

    @Test("an untitled recording renders the same fallback the filename uses")
    func displayTitleFallback() {
        let untitled = TranscriptDocument(title: "   ", date: .distantPast, turns: [])

        #expect(untitled.displayTitle == FilenameSanitizer.fallbackName)
    }

    @Test("a title is trimmed for display but otherwise untouched")
    func displayTitleTrims() {
        let document = TranscriptDocument(title: "  Weekly sync  ", date: .distantPast, turns: [])

        #expect(document.displayTitle == "Weekly sync")
    }
}
