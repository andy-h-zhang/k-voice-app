import Testing
import Foundation
@testable import KVoiceCore

@Suite("TranscriptResponse decoding")
struct TranscriptResponseTests {
    /// Hand-written fixture modeled on AssemblyAI's async transcript
    /// response shape (docs/implementation-plan.md §0): a completed
    /// transcript with two diarized utterances, each carrying word-level
    /// timestamps, confidence, and speaker attribution.
    private let completedFixture = """
    {
      "id": "transcript-abc123",
      "status": "completed",
      "error": null,
      "utterances": [
        {
          "speaker": "A",
          "text": "Hello there, how are you doing today?",
          "start": 0,
          "end": 2400,
          "words": [
            { "text": "Hello", "start": 0, "end": 300, "confidence": 0.98, "speaker": "A" },
            { "text": "there,", "start": 320, "end": 600, "confidence": 0.95, "speaker": "A" },
            { "text": "how", "start": 650, "end": 800, "confidence": 0.97, "speaker": "A" },
            { "text": "are", "start": 820, "end": 950, "confidence": 0.96, "speaker": "A" },
            { "text": "you", "start": 970, "end": 1100, "confidence": 0.99, "speaker": "A" },
            { "text": "doing", "start": 1120, "end": 1400, "confidence": 0.94, "speaker": "A" },
            { "text": "today?", "start": 1420, "end": 2400, "confidence": 0.93, "speaker": "A" }
          ]
        },
        {
          "speaker": "B",
          "text": "I'm doing well, thanks for asking.",
          "start": 2500,
          "end": 4800,
          "words": [
            { "text": "I'm", "start": 2500, "end": 2700, "confidence": 0.97, "speaker": "B" },
            { "text": "doing", "start": 2720, "end": 2950, "confidence": 0.96, "speaker": "B" },
            { "text": "well,", "start": 2970, "end": 3200, "confidence": 0.95, "speaker": "B" },
            { "text": "thanks", "start": 3300, "end": 3600, "confidence": 0.98, "speaker": "B" },
            { "text": "for", "start": 3620, "end": 3750, "confidence": 0.99, "speaker": "B" },
            { "text": "asking.", "start": 3770, "end": 4800, "confidence": 0.94, "speaker": "B" }
          ]
        }
      ],
      "words": [
        { "text": "Hello", "start": 0, "end": 300, "confidence": 0.98, "speaker": "A" },
        { "text": "there,", "start": 320, "end": 600, "confidence": 0.95, "speaker": "A" }
      ]
    }
    """

    @Test("decodes a completed response with utterances and words")
    func decodesCompletedResponseWithUtterancesAndWords() throws {
        let response = try JSONDecoder().decode(
            TranscriptResponse.self,
            from: Data(completedFixture.utf8)
        )

        #expect(response.id == "transcript-abc123")
        #expect(response.status == .completed)
        #expect(response.error == nil)

        #expect(response.utterances?.count == 2)

        let first = try #require(response.utterances?.first)
        #expect(first.speaker == "A")
        #expect(first.text == "Hello there, how are you doing today?")
        #expect(first.start == 0)
        #expect(first.end == 2400)
        #expect(first.words.count == 7)
        #expect(first.words.first?.text == "Hello")
        #expect(first.words.first?.confidence == 0.98)
        #expect(first.words.first?.speaker == "A")

        let second = try #require(response.utterances?.last)
        #expect(second.speaker == "B")
        #expect(second.text == "I'm doing well, thanks for asking.")
        #expect(second.words.count == 6)
        #expect(second.words.last?.text == "asking.")

        #expect(response.words?.count == 2)
    }

    /// Optional fields (error, utterances, words) should decode to nil
    /// rather than fail when the API hasn't produced them yet (e.g. a
    /// still-queued transcript) or when the job failed outright.
    @Test("decodes an error-status response without utterances or words")
    func decodesErrorStatusWithoutUtterancesOrWords() throws {
        let json = """
        { "id": "transcript-failed", "status": "error", "error": "invalid audio file" }
        """

        let response = try JSONDecoder().decode(TranscriptResponse.self, from: Data(json.utf8))

        #expect(response.id == "transcript-failed")
        #expect(response.status == .error)
        #expect(response.error == "invalid audio file")
        #expect(response.utterances == nil)
        #expect(response.words == nil)
    }
}
