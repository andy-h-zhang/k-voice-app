import Foundation
import Testing

@testable import KVoiceCore

@Suite("Transcript request encoding")
struct TranscriptRequestTests {

    private func encodedJSON(_ request: TranscriptRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("encodes the snake_case keys the API documents")
    func snakeCaseKeys() throws {
        let json = try encodedJSON(
            TranscriptRequest(audioURL: "https://cdn/1", keytermsPrompt: ["alpha"])
        )
        #expect(json.keys.sorted() == ["audio_url", "keyterms_prompt", "speaker_labels", "speech_models"])
    }

    @Test("defaults to the pinned model priority list with diarization on")
    func defaults() throws {
        let json = try encodedJSON(TranscriptRequest(audioURL: "https://cdn/1"))
        #expect(json["speech_models"] as? [String] == ["universal-3-5-pro", "universal-2"])
        #expect(json["speaker_labels"] as? Bool == true)
    }

    /// api-notes §2: an absent field is not the same as an empty array.
    @Test("keyterms_prompt is omitted when nil or empty")
    func omitsEmptyKeyterms() throws {
        #expect(try encodedJSON(TranscriptRequest(audioURL: "u"))["keyterms_prompt"] == nil)
        #expect(try encodedJSON(TranscriptRequest(audioURL: "u", keytermsPrompt: []))["keyterms_prompt"] == nil)
        #expect(try encodedJSON(TranscriptRequest(audioURL: "u", keytermsPrompt: ["x"]))["keyterms_prompt"] != nil)
    }

    @Test("round-trips through Codable")
    func roundTrip() throws {
        let original = TranscriptRequest(
            audioURL: "https://cdn.assemblyai.com/upload/abc",
            speechModels: ["universal-3-5-pro"],
            speakerLabels: true,
            keytermsPrompt: ["KVoice", "speaker diarization"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptRequest.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Keyterm sanitation

    @Test("trims whitespace and drops empties and duplicates")
    func sanitizesBasics() {
        let result = TranscriptRequest.sanitizedKeyterms(
            ["  KVoice  ", "", "   ", "kvoice", "AssemblyAI"]
        )
        #expect(result == ["KVoice", "AssemblyAI"])
    }

    @Test("drops phrases longer than six words")
    func dropsOverlongPhrases() {
        let sixWords = "one two three four five six"
        let sevenWords = "one two three four five six seven"
        let result = TranscriptRequest.sanitizedKeyterms([sixWords, sevenWords])
        #expect(result == [sixWords])
    }

    @Test("respects the total word budget, counting every word of a phrase")
    func respectsWordBudget() {
        let result = TranscriptRequest.sanitizedKeyterms(
            ["alpha beta", "gamma delta", "epsilon"],
            wordBudget: 3
        )
        // "alpha beta" (2) fits; "gamma delta" (2) would exceed 3; "epsilon" (1) fits.
        #expect(result == ["alpha beta", "epsilon"])
    }

    /// universal-2 caps far lower than universal-3-5-pro, and a fallback list
    /// may end up served by either — so the lower budget governs.
    @Test("the word budget follows the most restrictive model in the list")
    func budgetFollowsMostRestrictiveModel() {
        #expect(TranscriptRequest.keytermWordBudget(for: ["universal-3-5-pro"]) == 1_000)
        #expect(TranscriptRequest.keytermWordBudget(for: ["universal-3-5-pro", "universal-2"]) == 200)
        #expect(TranscriptRequest.keytermWordBudget(for: ["universal-2"]) == 200)
    }

    @Test("sanitation is a no-op on an already-valid list")
    func noOpOnValidList() {
        let terms = ["KVoice", "AssemblyAI", "speaker diarization"]
        #expect(TranscriptRequest.sanitizedKeyterms(terms) == terms)
    }
}

@Suite("Transcript response extras")
struct TranscriptResponseExtraTests {

    @Test("decodes the metadata fields api-notes §3 lists")
    func decodesMetadata() throws {
        let json = """
            {
              "id": "t-1", "status": "completed", "text": "hello there",
              "audio_duration": 3612, "confidence": 0.94, "language_code": "en_us",
              "speech_model_used": "universal-3-5-pro"
            }
            """

        let response = try JSONDecoder().decode(TranscriptResponse.self, from: Data(json.utf8))

        #expect(response.text == "hello there")
        #expect(response.audioDuration == 3_612)
        #expect(response.confidence == 0.94)
        #expect(response.languageCode == "en_us")
        #expect(response.speechModelUsed == "universal-3-5-pro")
    }

    @Test("unknown fields are ignored, so a server-side addition can't break decoding")
    func ignoresUnknownFields() throws {
        let json = """
            {"id":"t-1","status":"queued","brand_new_field":{"nested":true},"another":[1,2,3]}
            """
        let response = try JSONDecoder().decode(TranscriptResponse.self, from: Data(json.utf8))
        #expect(response.id == "t-1")
        #expect(response.status == .queued)
    }

    @Test("round-trips through Codable")
    func roundTrip() throws {
        let original = TranscriptResponse(
            id: "t-1",
            status: .completed,
            text: "hi",
            audioDuration: 12.5,
            confidence: 0.9,
            languageCode: "en_us",
            speechModelUsed: "universal-3-5-pro",
            utterances: [
                TranscriptResponse.Utterance(
                    speaker: "A",
                    text: "hi",
                    start: 0,
                    end: 500,
                    confidence: 0.9,
                    words: [TranscriptResponse.Word(text: "hi", start: 0, end: 500, confidence: 0.9, speaker: "A")]
                )
            ],
            words: [TranscriptResponse.Word(text: "hi", start: 0, end: 500, confidence: 0.9, speaker: "A")]
        )

        let decoded = try JSONDecoder().decode(
            TranscriptResponse.self,
            from: try JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    @Test("status terminality drives when polling stops")
    func statusTerminality() {
        #expect(TranscriptResponse.Status.completed.isTerminal)
        #expect(TranscriptResponse.Status.error.isTerminal)
        #expect(!TranscriptResponse.Status.queued.isTerminal)
        #expect(!TranscriptResponse.Status.processing.isTerminal)
    }

    @Test("allWords prefers the flat array and returns it sorted")
    func allWordsPrefersFlatArray() {
        let response = TranscriptResponse(
            id: "t",
            status: .completed,
            utterances: [
                TranscriptResponse.Utterance(
                    speaker: "A", text: "x", start: 0, end: 10,
                    words: [TranscriptResponse.Word(text: "x", start: 0, end: 10, confidence: 1, speaker: "A")]
                )
            ],
            words: [
                TranscriptResponse.Word(text: "late", start: 900, end: 1_000, confidence: 1, speaker: "B"),
                TranscriptResponse.Word(text: "early", start: 0, end: 100, confidence: 1, speaker: "A")
            ]
        )

        #expect(response.allWords.map(\.text) == ["early", "late"])
    }

    @Test("allWords falls back to the words nested in utterances")
    func allWordsFallsBackToUtterances() {
        let response = TranscriptResponse(
            id: "t",
            status: .completed,
            utterances: [
                TranscriptResponse.Utterance(
                    speaker: "A", text: "a b", start: 0, end: 200,
                    words: [
                        TranscriptResponse.Word(text: "b", start: 100, end: 200, confidence: 1, speaker: "A"),
                        TranscriptResponse.Word(text: "a", start: 0, end: 100, confidence: 1, speaker: "A")
                    ]
                )
            ],
            words: []
        )

        #expect(response.allWords.map(\.text) == ["a", "b"])
    }

    @Test("speakerLabels lists distinct speakers in sorted order")
    func speakerLabels() {
        let response = Fixture.transcript(utterances: [
            Fixture.utterance(speaker: "B", start: 0, end: 5_000),
            Fixture.utterance(speaker: "A", start: 6_000, end: 11_000),
            Fixture.utterance(speaker: "B", start: 12_000, end: 17_000)
        ])
        #expect(response.speakerLabels == ["A", "B"])
    }
}

@Suite("Upload response")
struct UploadResponseTests {

    @Test("decodes the documented upload_url shape")
    func decodes() throws {
        let json = #"{"upload_url":"https://cdn.assemblyai.com/upload/abc"}"#
        let response = try JSONDecoder().decode(UploadResponse.self, from: Data(json.utf8))
        #expect(response.uploadURL == "https://cdn.assemblyai.com/upload/abc")
    }

    @Test("round-trips through Codable")
    func roundTrip() throws {
        let original = UploadResponse(uploadURL: "https://cdn.assemblyai.com/upload/abc")
        let decoded = try JSONDecoder().decode(
            UploadResponse.self,
            from: try JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }
}
