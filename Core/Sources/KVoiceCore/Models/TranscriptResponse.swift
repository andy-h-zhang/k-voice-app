/// Response body from `GET /v2/transcript/{id}` (AssemblyAI async
/// transcription). Only the fields KVoice consumes are modeled; the full
/// raw JSON is retained separately on disk per recording (plan §1) so
/// nothing is lost by this DTO being partial.
///
/// `Utterance` and `Word` are nested here (rather than top-level types) so
/// they don't collide with the SwiftData `Utterance` domain model Phase 3
/// introduces in `Models/` — this DTO is the API wire shape, not the
/// persisted shape.
public struct TranscriptResponse: Codable, Sendable, Equatable {
    public var id: String
    public var status: Status
    public var error: String?
    public var utterances: [Utterance]?
    public var words: [Word]?

    public enum Status: String, Codable, Sendable {
        case queued
        case processing
        case completed
        case error
    }

    /// A diarized speaker turn: contiguous words attributed to one speaker.
    public struct Utterance: Codable, Sendable, Equatable {
        public var speaker: String
        public var text: String
        public var start: Int
        public var end: Int
        public var words: [Word]

        public init(speaker: String, text: String, start: Int, end: Int, words: [Word]) {
            self.speaker = speaker
            self.text = text
            self.start = start
            self.end = end
            self.words = words
        }
    }

    /// A single recognized word with timing, confidence, and speaker attribution.
    public struct Word: Codable, Sendable, Equatable {
        public var text: String
        public var start: Int
        public var end: Int
        public var confidence: Double
        public var speaker: String?

        public init(text: String, start: Int, end: Int, confidence: Double, speaker: String? = nil) {
            self.text = text
            self.start = start
            self.end = end
            self.confidence = confidence
            self.speaker = speaker
        }
    }

    public init(
        id: String,
        status: Status,
        error: String? = nil,
        utterances: [Utterance]? = nil,
        words: [Word]? = nil
    ) {
        self.id = id
        self.status = status
        self.error = error
        self.utterances = utterances
        self.words = words
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, error, utterances, words
    }
}
