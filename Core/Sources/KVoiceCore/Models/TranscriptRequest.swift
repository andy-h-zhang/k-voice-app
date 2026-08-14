/// Request body for `POST /v2/transcript` (AssemblyAI async transcription).
///
/// See `docs/implementation-plan.md` §0: `speech_models` is an array in
/// priority order (e.g. `["universal-3-5-pro", "universal-2"]`); `prompt`
/// and `keyterms_prompt` are mutually exclusive and only `keyterms_prompt`
/// is modeled here.
public struct TranscriptRequest: Codable, Sendable, Equatable {
    /// URL of the uploaded audio, as returned by `POST /v2/upload`.
    public var audioURL: String

    /// Model identifiers in priority-fallback order, e.g. `["universal-3-5-pro"]`.
    public var speechModels: [String]

    /// Enables diarization (`utterances[]` with per-speaker attribution).
    public var speakerLabels: Bool

    /// Up to ~1,000 domain vocabulary terms to boost recognition of.
    public var keytermsPrompt: [String]?

    public init(
        audioURL: String,
        speechModels: [String],
        speakerLabels: Bool = true,
        keytermsPrompt: [String]? = nil
    ) {
        self.audioURL = audioURL
        self.speechModels = speechModels
        self.speakerLabels = speakerLabels
        self.keytermsPrompt = keytermsPrompt
    }

    private enum CodingKeys: String, CodingKey {
        case audioURL = "audio_url"
        case speechModels = "speech_models"
        case speakerLabels = "speaker_labels"
        case keytermsPrompt = "keyterms_prompt"
    }
}
