import Foundation

/// Error taxonomy for the transcription provider.
///
/// Implements decision 3 of `docs/api-notes.md`: **429 and 5xx are retryable
/// with backoff; other 4xx are terminal for the current attempt** (though the
/// job as a whole always stays user-retryable — the audio file and, once
/// written, the raw JSON are the recovery points, per plan §2 Phase 3).
///
/// `isRetryable` is the single place that policy is encoded, so the request
/// retry loop and the higher-level `TranscriptionJob` (Phase 3) agree.
public enum TranscriptionError: Error, Sendable, Equatable {

    /// No API key was supplied. The CLI reads `ASSEMBLYAI_API_KEY`; the app
    /// will read the Keychain (Phase 3).
    case missingAPIKey

    /// 401 — key rejected.
    case unauthorized(message: String?)

    /// 403 — commonly "Cannot access uploaded file", which means the upload
    /// and the transcript request used keys from *different* projects
    /// (api-notes §Auth).
    case forbidden(message: String?)

    /// 404 — unknown transcript id (or a wrong path).
    case notFound(message: String?)

    /// 400/422 and friends. Note api-notes §1: the upload endpoint's 422 body
    /// is **plain text, not JSON**, so `message` here may be a raw string.
    case invalidRequest(status: Int, message: String?)

    /// 429 — rate limited. `retryAfter` comes from the `Retry-After` header
    /// when present. Retryable.
    case rateLimited(retryAfter: TimeInterval?)

    /// 5xx. Retryable.
    case serverError(status: Int, message: String?)

    /// Any other unexpected status code.
    case unexpectedStatus(status: Int, message: String?)

    /// URLSession-level failure (offline, DNS, TLS, timeout). Retryable.
    case transport(description: String)

    /// The response body did not match the documented shape. The raw body is
    /// still persisted verbatim (decision 1), so this is recoverable by hand.
    case decoding(description: String)

    /// The response was 200 but did not contain the field we need
    /// (e.g. `upload_url` missing from an upload response).
    case malformedResponse(description: String)

    /// The job reached `status: "error"`. Terminal — retrying the *same*
    /// transcript id will keep returning this. The user can resubmit.
    case transcriptFailed(message: String?)

    /// Polling exceeded `AssemblyAIConstants.maxPollDuration`.
    case pollingTimedOut(transcriptID: String)

    /// Whether re-issuing the identical request could plausibly succeed.
    /// api-notes decision 3.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError, .transport:
            return true
        case .missingAPIKey, .unauthorized, .forbidden, .notFound, .invalidRequest,
            .unexpectedStatus, .decoding, .malformedResponse, .transcriptFailed,
            .pollingTimedOut:
            return false
        }
    }

    /// Maps an HTTP status code to the right case. Centralized so the upload,
    /// create, and poll paths cannot drift apart.
    public static func from(status: Int, message: String?, retryAfter: TimeInterval? = nil) -> TranscriptionError {
        switch status {
        case 401:
            return .unauthorized(message: message)
        case 403:
            return .forbidden(message: message)
        case 404:
            return .notFound(message: message)
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 400, 402, 405...428, 430...499:
            return .invalidRequest(status: status, message: message)
        case 500...599:
            return .serverError(status: status, message: message)
        default:
            return .unexpectedStatus(status: status, message: message)
        }
    }
}

extension TranscriptionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No AssemblyAI API key.\n\(APIKeyResolver.guidance)"
        case .unauthorized(let message):
            // A key *was* found — so the fix is replacing it, not supplying
            // one. Naming both sources tells the user which one to go edit.
            return """
                AssemblyAI rejected the API key (401).\(Self.suffix(message)) \
                Replace the key in \(APIKeyResolver.environmentVariable) or in the \
                app's Settings (Keychain), whichever supplied it — \
                \(APIKeyResolver.environmentVariable) takes precedence when both are set.
                """
        case .forbidden(let message):
            return """
                AssemblyAI returned 403.\(Self.suffix(message)) \
                If this says "Cannot access uploaded file", the upload and the \
                transcript request used API keys from different projects.
                """
        case .notFound(let message):
            return "AssemblyAI returned 404 — unknown transcript id.\(Self.suffix(message))"
        case .invalidRequest(let status, let message):
            return "AssemblyAI rejected the request (\(status)).\(Self.suffix(message))"
        case .rateLimited(let retryAfter):
            let when = retryAfter.map { " Retry after \(Int($0))s." } ?? ""
            return "AssemblyAI rate limit reached (429).\(when)"
        case .serverError(let status, let message):
            return "AssemblyAI server error (\(status)).\(Self.suffix(message))"
        case .unexpectedStatus(let status, let message):
            return "AssemblyAI returned an unexpected status (\(status)).\(Self.suffix(message))"
        case .transport(let description):
            return "Network request failed: \(description)"
        case .decoding(let description):
            return "Could not decode the AssemblyAI response: \(description)"
        case .malformedResponse(let description):
            return "Unexpected AssemblyAI response: \(description)"
        case .transcriptFailed(let message):
            return "Transcription failed.\(Self.suffix(message))"
        case .pollingTimedOut(let id):
            return "Timed out waiting for transcript \(id) to complete."
        }
    }

    private static func suffix(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "" }
        return " \(message)"
    }
}
