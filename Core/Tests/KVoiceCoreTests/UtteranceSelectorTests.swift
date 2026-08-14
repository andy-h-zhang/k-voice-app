import Foundation
import Testing

@testable import KVoiceCore

@Suite("Utterance selector")
struct UtteranceSelectorTests {

    // MARK: - Ranking

    @Test("picks a speaker's longest utterances first")
    func picksLongestFirst() throws {
        let transcript = Fixture.transcript(utterances: [
            Fixture.utterance(speaker: "A", start: 0, end: 6_000),
            Fixture.utterance(speaker: "A", start: 10_000, end: 22_000),
            Fixture.utterance(speaker: "A", start: 30_000, end: 38_000)
        ])

        let selection = try #require(UtteranceSelector().select(from: transcript).first)

        #expect(selection.speaker == "A")
        #expect(selection.spans.count == 3)
        // 12 s utterance, then 8 s, then 6 s.
        #expect(selection.spans[0].startMs == 10_000)
        #expect(selection.spans[1].startMs == 30_000)
        #expect(selection.spans[2].startMs == 0)
    }

    @Test("caps at five spans per speaker")
    func capsAtFiveSpans() throws {
        let utterances = (0..<8).map { index in
            Fixture.utterance(speaker: "A", start: index * 20_000, end: index * 20_000 + 8_000)
        }
        let selection = try #require(UtteranceSelector().select(from: Fixture.transcript(utterances: utterances)).first)

        #expect(selection.spans.count == 5)
        #expect(selection.meetsTarget)
    }

    @Test("returns one entry per diarized speaker, ordered by label")
    func oneEntryPerSpeaker() {
        let transcript = Fixture.transcript(utterances: [
            Fixture.utterance(speaker: "C", start: 0, end: 8_000),
            Fixture.utterance(speaker: "A", start: 10_000, end: 18_000),
            Fixture.utterance(speaker: "B", start: 20_000, end: 28_000)
        ])

        #expect(UtteranceSelector().select(from: transcript).map(\.speaker) == ["A", "B", "C"])
    }

    // MARK: - Span shape

    @Test("spans never exceed the maximum length")
    func respectsMaxSpan() throws {
        // A single 40-second monologue.
        let transcript = Fixture.transcript(utterances: [
            Fixture.utterance(speaker: "A", start: 0, end: 40_000, wordCount: 40)
        ])

        let selection = try #require(UtteranceSelector().select(from: transcript).first)
        let span = try #require(selection.spans.first)

        #expect(span.durationMs <= 15_000)
        #expect(span.durationMs >= 5_000)
    }

    @Test("spans start and end exactly on word boundaries")
    func trimsToWordBoundaries() throws {
        let utterance = Fixture.utterance(speaker: "A", start: 1_234, end: 13_678, wordCount: 12)
        let transcript = Fixture.transcript(utterances: [utterance])

        let selection = try #require(UtteranceSelector().select(from: transcript).first)
        let span = try #require(selection.spans.first)

        #expect(utterance.words.contains { $0.start == span.startMs })
        #expect(utterance.words.contains { $0.end == span.endMs })
    }

    @Test("voiced time excludes the silence between words")
    func voicedTimeExcludesGaps() throws {
        // 10 words tiling 0–10 s with a 20 ms gap after each.
        let transcript = Fixture.transcript(utterances: [
            Fixture.utterance(speaker: "A", start: 0, end: 10_000, wordCount: 10, gapMs: 20)
        ])

        let span = try #require(UtteranceSelector().select(from: transcript).first?.spans.first)

        #expect(span.durationMs == 10_000)
        #expect(span.voicedMs < span.durationMs)
        #expect(span.voicedMs > 9_000)
    }

    @Test("an utterance with no word detail degrades to its own boundaries")
    func utteranceWithoutWords() throws {
        let utterance = TranscriptResponse.Utterance(
            speaker: "A",
            text: "no word timings here",
            start: 2_000,
            end: 9_000,
            words: []
        )
        let response = TranscriptResponse(id: "t", status: .completed, utterances: [utterance], words: [])

        let span = try #require(UtteranceSelector().select(from: response).first?.spans.first)
        #expect(span.startMs == 2_000)
        #expect(span.endMs == 9_000)
    }

    // MARK: - Cross-talk

    /// The whole point of "clean": another speaker talking over the span is
    /// exactly what poisons an embedding.
    @Test("a span is trimmed away from another speaker's words")
    func skipsOverlappingAudio() throws {
        // A speaks 0–10 s (words every 1 s); B interjects at 4.0–4.5 s.
        let a = Fixture.utterance(speaker: "A", start: 0, end: 10_000, wordCount: 10, gapMs: 20)
        let b = TranscriptResponse.Utterance(
            speaker: "B",
            text: "mm-hmm",
            start: 4_000,
            end: 4_500,
            words: [Fixture.word("mm-hmm", 4_000, 4_500, speaker: "B")]
        )
        let transcript = Fixture.transcript(utterances: [a, b])

        let selections = UtteranceSelector().select(from: transcript)
        let spanForA = try #require(selections.first { $0.speaker == "A" }?.spans.first)

        // The only clean run of A's words that reaches 5 s starts after B stops.
        #expect(spanForA.startMs == 5_000)
        #expect(spanForA.endMs == 10_000)
    }

    @Test("a speaker whose audio is entirely overlapped yields no spans")
    func fullyOverlappedSpeakerYieldsNothing() throws {
        let a = Fixture.utterance(speaker: "A", start: 0, end: 9_000, wordCount: 9)
        let b = TranscriptResponse.Utterance(
            speaker: "B",
            text: "constant cross-talk",
            start: 0,
            end: 9_000,
            words: [Fixture.word("cross-talk", 0, 9_000, speaker: "B")]
        )

        let selections = UtteranceSelector().select(from: Fixture.transcript(utterances: [a, b]))
        let selectionForA = try #require(selections.first { $0.speaker == "A" })

        #expect(selectionForA.spans.isEmpty)
        #expect(!selectionForA.meetsTarget)
    }

    @Test("the overlap guard widens the exclusion around foreign words")
    func overlapGuardWidensExclusion() throws {
        let a = Fixture.utterance(speaker: "A", start: 0, end: 12_000, wordCount: 12, gapMs: 20)
        let b = TranscriptResponse.Utterance(
            speaker: "B",
            text: "hm",
            start: 5_100,
            end: 5_200,
            words: [Fixture.word("hm", 5_100, 5_200, speaker: "B")]
        )
        let transcript = Fixture.transcript(utterances: [a, b])

        let tight = try #require(UtteranceSelector().select(from: transcript).first?.spans.first)
        let guarded = try #require(
            UtteranceSelector(configuration: .init(overlapGuardMs: 1_000))
                .select(from: transcript).first?.spans.first
        )

        // A wider guard can only shrink or move the usable window.
        #expect(guarded.durationMs <= tight.durationMs)
        #expect(guarded.startMs >= 6_000 || guarded.endMs <= 5_100)
    }

    @Test("words with no speaker attribution are not treated as cross-talk")
    func unattributedWordsAreIgnored() throws {
        let a = Fixture.utterance(speaker: "A", start: 0, end: 10_000, wordCount: 10)
        var response = Fixture.transcript(utterances: [a])
        response.words?.append(Fixture.word("noise", 4_000, 4_500, speaker: nil))

        let span = try #require(UtteranceSelector().select(from: response).first?.spans.first)
        #expect(span.durationMs == 10_000)
    }

    // MARK: - Fallback and sufficiency

    @Test("a speaker with only short turns falls back to a lower floor and is flagged thin")
    func fallbackForShortTurns() throws {
        let transcript = Fixture.transcript(utterances: [
            Fixture.utterance(speaker: "A", start: 0, end: 20_000, wordCount: 20),
            Fixture.utterance(speaker: "B", start: 30_000, end: 32_500, wordCount: 3)
        ])

        let selections = UtteranceSelector().select(from: transcript)
        let b = try #require(selections.first { $0.speaker == "B" })

        #expect(b.spans.count == 1)
        #expect(try #require(b.spans.first).durationMs == 2_500)
        // Below the 5 s target band → thin evidence.
        #expect(!b.meetsTarget)
    }

    @Test("turns shorter than the fallback floor are dropped entirely")
    func turnsBelowFallbackFloorAreDropped() throws {
        let transcript = Fixture.transcript(utterances: [
            Fixture.utterance(speaker: "A", start: 0, end: 20_000, wordCount: 20),
            Fixture.utterance(speaker: "B", start: 30_000, end: 30_800, wordCount: 2)
        ])

        let b = try #require(UtteranceSelector().select(from: transcript).first { $0.speaker == "B" })
        #expect(b.spans.isEmpty)
    }

    @Test("meetsTarget requires three spans in the primary band")
    func meetsTargetNeedsThreeSpans() throws {
        let two = Fixture.transcript(utterances: [
            Fixture.utterance(speaker: "A", start: 0, end: 8_000),
            Fixture.utterance(speaker: "A", start: 10_000, end: 18_000)
        ])
        let three = Fixture.transcript(utterances: [
            Fixture.utterance(speaker: "A", start: 0, end: 8_000),
            Fixture.utterance(speaker: "A", start: 10_000, end: 18_000),
            Fixture.utterance(speaker: "A", start: 20_000, end: 28_000)
        ])

        #expect(try #require(UtteranceSelector().select(from: two).first).meetsTarget == false)
        #expect(try #require(UtteranceSelector().select(from: three).first).meetsTarget == true)
    }

    @Test("an empty transcript selects nothing")
    func emptyTranscript() {
        let response = TranscriptResponse(id: "t", status: .completed)
        #expect(UtteranceSelector().select(from: response).isEmpty)
    }

    // MARK: - Determinism

    @Test("selection is deterministic")
    func deterministic() {
        let transcript = Fixture.transcript(utterances: [
            Fixture.utterance(speaker: "A", start: 0, end: 9_000),
            Fixture.utterance(speaker: "B", start: 9_500, end: 18_000),
            Fixture.utterance(speaker: "A", start: 19_000, end: 28_000),
            Fixture.utterance(speaker: "B", start: 29_000, end: 36_000)
        ])

        let selector = UtteranceSelector()
        #expect(selector.select(from: transcript) == selector.select(from: transcript))
    }

    @Test("equal-length candidates break ties on the earlier start")
    func tiesBreakOnEarlierStart() throws {
        let transcript = Fixture.transcript(utterances: [
            Fixture.utterance(speaker: "A", start: 40_000, end: 48_000, wordCount: 8),
            Fixture.utterance(speaker: "A", start: 0, end: 8_000, wordCount: 8)
        ])

        let spans = try #require(UtteranceSelector().select(from: transcript).first).spans
        #expect(spans[0].voicedMs == spans[1].voicedMs)
        #expect(spans[0].startMs == 0)
    }

    // MARK: - Range helpers

    @Test("merged ranges collapse overlapping and touching words")
    func mergedRangesCollapse() {
        let words = [
            Fixture.word("a", 0, 100, speaker: "B"),
            Fixture.word("b", 90, 200, speaker: "B"),
            Fixture.word("c", 200, 300, speaker: "B"),
            Fixture.word("d", 500, 600, speaker: "B")
        ]

        let merged = UtteranceSelector.mergedRanges(of: words, guardMs: 0)
        #expect(merged.count == 2)
        #expect(merged[0] == .init(start: 0, end: 300))
        #expect(merged[1] == .init(start: 500, end: 600))
    }

    @Test("intersection test handles touching boundaries as non-overlapping")
    func intersectionBoundaries() {
        let ranges = [
            UtteranceSelector.ClosedTimeRange(start: 100, end: 200),
            UtteranceSelector.ClosedTimeRange(start: 400, end: 500)
        ]

        #expect(!UtteranceSelector.intersects(ranges: ranges, start: 0, end: 100))
        #expect(!UtteranceSelector.intersects(ranges: ranges, start: 200, end: 400))
        #expect(UtteranceSelector.intersects(ranges: ranges, start: 150, end: 160))
        #expect(UtteranceSelector.intersects(ranges: ranges, start: 0, end: 101))
        #expect(UtteranceSelector.intersects(ranges: ranges, start: 199, end: 450))
        #expect(!UtteranceSelector.intersects(ranges: ranges, start: 600, end: 700))
        #expect(!UtteranceSelector.intersects(ranges: [], start: 0, end: 1_000))
    }
}
