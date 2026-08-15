import Foundation

/// Every AssemblyAI identifier, endpoint, and documented limit lives here.
///
/// This is decision 4 of `docs/api-notes.md` ("Decisions locked for the
/// code"): the next model bump or endpoint change is a one-line edit in this
/// file, not a grep across the codebase. Values were verified against the
/// live API reference on 2026-08-13 — see `docs/api-notes.md` for the source
/// links and the reasoning behind each choice.
public enum AssemblyAIConstants {

    // MARK: - Endpoints

    /// Base URL for the US region. An EU region exists (`api.eu.assemblyai.com`)
    /// but v1 does not use it (api-notes §Auth).
    public static let baseURL = URL(string: "https://api.assemblyai.com")!

    /// `POST` raw file bytes here; responds with `{ "upload_url": ... }`.
    public static let uploadPath = "/v2/upload"

    /// `POST` a `TranscriptRequest` here to create a transcript job.
    public static let transcriptPath = "/v2/transcript"

    /// `GET {transcriptPath}/{id}` to poll a job.
    public static func transcriptPath(id: String) -> String {
        "\(transcriptPath)/\(id)"
    }

    // MARK: - Headers

    public static let authorizationHeader = "Authorization"
    public static let contentTypeHeader = "Content-Type"

    /// The **raw key**, with no `Bearer ` prefix.
    ///
    /// AssemblyAI is one of the APIs that does not use a scheme here. Its docs
    /// say so twice over: the pre-recorded guide shows
    /// `-H "authorization: $ASSEMBLYAI_API_KEY"` and states "no `Bearer`
    /// prefix", and its OpenAPI spec declares the scheme as
    /// `type: apiKey, in: header, name: Authorization` — which by definition
    /// carries no prefix, where a bearer token would be `type: http,
    /// scheme: bearer`.
    ///
    /// This shipped as `"Bearer \(apiKey)"` and was wrong from the first
    /// commit, which nothing caught because the value was only ever asserted
    /// against itself in tests and no real key had been used against the live
    /// API. The server reads `Bearer sk_…` as the entire key and answers
    /// `401 Invalid API key`, so transcription failed for every user with a
    /// perfectly good key.
    public static func authorizationValue(apiKey: String) -> String {
        apiKey
    }

    /// api-notes §1: the upload endpoint takes raw binary — not multipart.
    public static let octetStreamContentType = "application/octet-stream"
    public static let jsonContentType = "application/json"

    // MARK: - Models

    /// `speech_models` is a **priority-ordered array**, not a scalar
    /// (api-notes §2). Sent explicitly to pin behavior across server-side
    /// default changes.
    ///
    /// One model, no fallback. `universal-2` used to be listed behind
    /// `universal-3-5-pro` as insurance, which cost every request four fifths of
    /// its keyterm budget — see ``SpeechModelPreference`` for the arithmetic.
    /// Users who want the fallback can choose it in Settings.
    public static let defaultSpeechModels = SpeechModelPreference.default.speechModels

    /// The full set of values the API accepts today. Used to validate
    /// `--model` overrides in the CLI before spending an upload on a typo.
    public static let allowedSpeechModels: Set<String> = ["universal-3-5-pro", "universal-2"]

    // MARK: - Keyterm prompting limits (api-notes §2)

    /// Maximum words in a single keyterm phrase.
    public static let maxWordsPerKeyterm = 6

    /// Approximate total word budget across all keyterms on
    /// `universal-3-5-pro`. Each word of a multi-word phrase counts.
    public static let maxKeytermWordsUniversal3 = 1_000

    /// The same budget on `universal-2`, which caps far lower.
    public static let maxKeytermWordsUniversal2 = 200

    // MARK: - Polling (api-notes decision 2)

    /// First poll delay, used when the audio duration is unknown.
    public static let initialPollDelay: TimeInterval = 3

    /// Ceiling for the exponential backoff.
    public static let maxPollDelay: TimeInterval = 30

    /// Growth factor applied to each successive poll delay.
    public static let pollBackoffMultiplier: Double = 1.5

    /// Transcription typically completes in a fraction of real time. When we
    /// know `audio_duration`, the first poll is deferred by this fraction of
    /// it (still clamped to `initialPollDelay ... maxPollDelay`) so a 60-minute
    /// meeting doesn't burn ~20 pointless requests in its first minute.
    public static let audioDurationPollFraction: Double = 0.10

    /// Safety valve so a stuck job can't poll forever. 6 hours comfortably
    /// covers the spec's ~2-hour worst-case recording.
    public static let maxPollDuration: TimeInterval = 6 * 60 * 60

    // MARK: - HTTP retry policy (api-notes decision 3)

    /// Attempts (including the first) for requests that fail retryably.
    public static let maxRequestAttempts = 4

    /// Base delay for retrying a retryable HTTP failure.
    public static let retryBaseDelay: TimeInterval = 2
}
