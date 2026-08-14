import Foundation

/// Request body for `POST /v2/transcript` (AssemblyAI async transcription).
///
/// Shape verified 2026-08-13 — see `docs/api-notes.md` §2:
///
/// ```json
/// {
///   "audio_url": "<upload_url>",
///   "speech_models": ["universal-3-5-pro", "universal-2"],
///   "speaker_labels": true,
///   "keyterms_prompt": ["..."]
/// }
/// ```
///
/// Two encoding rules are enforced here rather than at call sites:
///
/// 1. `keyterms_prompt` is **omitted entirely when empty** — the API treats a
///    present-but-empty array differently from an absent field.
/// 2. `speaker_labels: true` requires `punctuate: true`. `punctuate` defaults
///    to true server-side and we never send `false`, so the constraint holds
///    by construction; see `sanitizedKeyterms` for the other client-side
///    validation we owe the API.
public struct TranscriptRequest: Codable, Sendable, Equatable {
    /// URL of the uploaded audio, as returned by `POST /v2/upload`.
    public var audioURL: String

    /// Model identifiers in priority-fallback order, e.g. `["universal-3-5-pro"]`.
    public var speechModels: [String]

    /// Enables diarization (`utterances[]` with per-speaker attribution).
    public var speakerLabels: Bool

    /// Domain vocabulary terms to boost. Subject to the limits in
    /// `AssemblyAIConstants`; run through `sanitizedKeyterms(_:)` first.
    public var keytermsPrompt: [String]?

    public init(
        audioURL: String,
        speechModels: [String] = AssemblyAIConstants.defaultSpeechModels,
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

    /// Custom encoding so an empty (or all-whitespace) keyterms list drops the
    /// field instead of sending `"keyterms_prompt": []` (api-notes §2).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(audioURL, forKey: .audioURL)
        try container.encode(speechModels, forKey: .speechModels)
        try container.encode(speakerLabels, forKey: .speakerLabels)

        if let keytermsPrompt, !keytermsPrompt.isEmpty {
            try container.encode(keytermsPrompt, forKey: .keytermsPrompt)
        }
    }

    // MARK: - Keyterm sanitation (api-notes §2)

    /// Trims a user-supplied keyterm list to what the API accepts, so a bad
    /// settings value costs a dropped term rather than a rejected request.
    ///
    /// Rules, in order:
    /// - whitespace-trimmed; empties dropped; duplicates dropped (first wins)
    /// - phrases longer than `maxWordsPerKeyterm` (6 words) dropped
    /// - accumulated **word** count capped at the model's budget (~1,000 words
    ///   for `universal-3-5-pro`, 200 for `universal-2`); terms past the budget
    ///   are dropped
    ///
    /// - Parameter wordBudget: Total word capacity. Defaults to the
    ///   `universal-3-5-pro` budget; pass the `universal-2` value when that is
    ///   the only model in `speech_models`.
    public static func sanitizedKeyterms(
        _ terms: [String],
        wordBudget: Int = AssemblyAIConstants.maxKeytermWordsUniversal3
    ) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        var wordsUsed = 0

        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let words = trimmed.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty, words.count <= AssemblyAIConstants.maxWordsPerKeyterm else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            guard wordsUsed + words.count <= wordBudget else { continue }

            wordsUsed += words.count
            kept.append(trimmed)
        }

        return kept
    }

    /// The word budget implied by a `speech_models` list: the *lowest* budget
    /// among the models, since any of them may end up serving the request.
    public static func keytermWordBudget(for speechModels: [String]) -> Int {
        speechModels.contains("universal-2")
            ? AssemblyAIConstants.maxKeytermWordsUniversal2
            : AssemblyAIConstants.maxKeytermWordsUniversal3
    }
}
