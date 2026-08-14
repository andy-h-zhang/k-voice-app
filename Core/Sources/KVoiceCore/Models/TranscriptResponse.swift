/// Response body from `GET /v2/transcript/{id}` (AssemblyAI async
/// transcription). Only the fields KVoice consumes are modeled; the full
/// raw JSON is retained separately on disk per recording (plan §1, api-notes
/// decision 1) so nothing is lost by this DTO being partial. Unknown fields
/// are ignored by `Codable`, which is what makes that split safe.
///
/// `Utterance` and `Word` are nested here (rather than top-level types) so
/// they don't collide with the SwiftData `Utterance` domain model Phase 3
/// introduces in `Models/` — this DTO is the API wire shape, not the
/// persisted shape.
///
/// Field set verified 2026-08-13 against `docs/api-notes.md` §3.
public struct TranscriptResponse: Codable, Sendable, Equatable {
    public var id: String
    public var status: Status
    public var error: String?

    /// Full transcript text (present once `completed`).
    public var text: String?

    /// Length of the submitted audio in **seconds**. Drives the
    /// duration-aware first poll delay (api-notes decision 2).
    public var audioDuration: Double?

    /// Overall recognition confidence in `0...1`.
    public var confidence: Double?

    /// Detected (or requested) language, e.g. `"en_us"`.
    public var languageCode: String?

    /// Which model actually served the request — the API echoes this back for
    /// the `speech_models` priority array we send.
    public var speechModelUsed: String?

    /// Diarized speaker turns. Present because we always send
    /// `speaker_labels: true`.
    public var utterances: [Utterance]?

    /// Flat word list with per-word speaker attribution.
    public var words: [Word]?

    /// api-notes §3: `queued` → `processing` → `completed` | `error`. There is
    /// no server-side "uploading" state — that is a client-side state.
    public enum Status: String, Codable, Sendable {
        case queued
        case processing
        case completed
        case error

        /// Whether polling should stop.
        public var isTerminal: Bool {
            self == .completed || self == .error
        }
    }

    /// A diarized speaker turn: contiguous words attributed to one speaker.
    /// `start`/`end` are **milliseconds**.
    public struct Utterance: Codable, Sendable, Equatable {
        public var speaker: String
        public var text: String
        public var start: Int
        public var end: Int
        public var confidence: Double?
        public var words: [Word]

        public var durationMs: Int { max(0, end - start) }

        public init(
            speaker: String,
            text: String,
            start: Int,
            end: Int,
            confidence: Double? = nil,
            words: [Word]
        ) {
            self.speaker = speaker
            self.text = text
            self.start = start
            self.end = end
            self.confidence = confidence
            self.words = words
        }
    }

    /// A single recognized word with timing, confidence, and speaker
    /// attribution. `start`/`end` are **milliseconds**.
    public struct Word: Codable, Sendable, Equatable {
        public var text: String
        public var start: Int
        public var end: Int
        public var confidence: Double
        public var speaker: String?

        public var durationMs: Int { max(0, end - start) }

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
        text: String? = nil,
        audioDuration: Double? = nil,
        confidence: Double? = nil,
        languageCode: String? = nil,
        speechModelUsed: String? = nil,
        utterances: [Utterance]? = nil,
        words: [Word]? = nil
    ) {
        self.id = id
        self.status = status
        self.error = error
        self.text = text
        self.audioDuration = audioDuration
        self.confidence = confidence
        self.languageCode = languageCode
        self.speechModelUsed = speechModelUsed
        self.utterances = utterances
        self.words = words
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, error, text, confidence, utterances, words
        case audioDuration = "audio_duration"
        case languageCode = "language_code"
        case speechModelUsed = "speech_model_used"
    }

    // MARK: - Derived views

    /// Every word in the transcript, preferring the flat `words[]` array and
    /// falling back to the words nested inside `utterances[]`.
    ///
    /// Speaker ID needs a complete, speaker-attributed word list to detect
    /// cross-talk; both arrays carry that, but the flat one is authoritative.
    /// Always returned sorted by start time.
    public var allWords: [Word] {
        let flat = words ?? []
        let source = flat.isEmpty ? (utterances ?? []).flatMap(\.words) : flat
        return source.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Distinct diarized speaker labels ("A", "B", …) in stable sorted order.
    public var speakerLabels: [String] {
        Set((utterances ?? []).map(\.speaker)).sorted()
    }
}
