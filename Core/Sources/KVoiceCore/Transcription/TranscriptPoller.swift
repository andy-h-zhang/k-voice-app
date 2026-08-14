import Foundation

/// Drives a transcript job to a terminal state using the backoff schedule
/// from `docs/api-notes.md` decision 2.
///
/// Deliberately decoupled from `AssemblyAIClient`: it polls through a closure,
/// so the whole retry/backoff policy is exercised in tests against a mocked
/// `TranscriptionProvider` with a fake clock and **no network, no sleeping**.
/// `AssemblyAIClient.waitForCompletion` is a thin wrapper over this type.
public struct TranscriptPoller: Sendable {

    public typealias PollFunction = @Sendable (String) async throws -> TranscriptResponse
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    public typealias Clock = @Sendable () -> Date

    /// Progress callback: the freshly polled response and the 0-based poll index.
    public typealias UpdateHandler = @Sendable (TranscriptResponse, Int) -> Void

    public var backoff: PollBackoff

    /// Hard cap on total wall-clock time spent polling one job.
    public var maxDuration: TimeInterval

    /// How many *consecutive* retryable failures (429/5xx/transport) are
    /// tolerated before giving up. A blip mid-poll must not kill a 40-minute
    /// job, but a persistent outage must not spin forever.
    public var maxConsecutiveFailures: Int

    private let sleep: Sleeper
    private let now: Clock

    public init(
        backoff: PollBackoff = PollBackoff(),
        maxDuration: TimeInterval = AssemblyAIConstants.maxPollDuration,
        maxConsecutiveFailures: Int = AssemblyAIConstants.maxRequestAttempts,
        sleep: @escaping Sleeper = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
        now: @escaping Clock = { Date() }
    ) {
        self.backoff = backoff
        self.maxDuration = maxDuration
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.sleep = sleep
        self.now = now
    }

    /// Polls `id` until the job reports `completed` or `error`.
    ///
    /// - Throws: `TranscriptionError.transcriptFailed` when the job ends in
    ///   `error`; `.pollingTimedOut` when `maxDuration` elapses; the last
    ///   underlying error when retryable failures exhaust
    ///   `maxConsecutiveFailures`; any non-retryable error immediately.
    @discardableResult
    public func waitForCompletion(
        id: String,
        audioDurationSeconds: TimeInterval? = nil,
        poll: PollFunction,
        onUpdate: UpdateHandler? = nil
    ) async throws -> TranscriptResponse {
        let started = now()
        var attempt = 0
        var consecutiveFailures = 0
        var duration = audioDurationSeconds

        while true {
            try Task.checkCancellation()

            guard now().timeIntervalSince(started) < maxDuration else {
                throw TranscriptionError.pollingTimedOut(transcriptID: id)
            }

            try await sleep(backoff.delay(forAttempt: attempt, audioDurationSeconds: duration))

            let response: TranscriptResponse
            do {
                response = try await poll(id)
                consecutiveFailures = 0
            } catch let error as TranscriptionError where error.isRetryable {
                consecutiveFailures += 1
                guard consecutiveFailures < maxConsecutiveFailures else { throw error }
                var retryAfter: TimeInterval?
                if case .rateLimited(let after) = error { retryAfter = after }
                try await sleep(
                    PollBackoff.retryDelay(forAttempt: consecutiveFailures - 1, retryAfter: retryAfter)
                )
                continue
            }

            onUpdate?(response, attempt)

            // The first response usually carries `audio_duration`, which makes
            // every subsequent delay duration-aware even when the caller
            // didn't know the length up front.
            if duration == nil, let reported = response.audioDuration, reported > 0 {
                duration = reported
            }

            switch response.status {
            case .completed:
                return response
            case .error:
                throw TranscriptionError.transcriptFailed(message: response.error)
            case .queued, .processing:
                attempt += 1
            }
        }
    }

    /// Convenience overload that polls through a `TranscriptionProvider`.
    @discardableResult
    public func waitForCompletion(
        provider: some TranscriptionProvider,
        id: String,
        audioDurationSeconds: TimeInterval? = nil,
        onUpdate: UpdateHandler? = nil
    ) async throws -> TranscriptResponse {
        try await waitForCompletion(
            id: id,
            audioDurationSeconds: audioDurationSeconds,
            poll: { try await provider.poll(id: $0) },
            onUpdate: onUpdate
        )
    }
}

/// Client-side pipeline stage, surfaced as progress. Mirrors the states the
/// spec asks the UI to show: Uploading → Queued → Transcribing → Matching
/// speakers → Done / Failed. The API itself has no "uploading" state
/// (api-notes §3) — that one is ours.
public enum TranscriptionStage: String, Sendable, Equatable {
    case uploading
    case queued
    case transcribing
    case matchingSpeakers
    case done
    case failed

    /// Maps a server-reported status onto our stage vocabulary.
    public init(status: TranscriptResponse.Status) {
        switch status {
        case .queued: self = .queued
        case .processing: self = .transcribing
        case .completed: self = .done
        case .error: self = .failed
        }
    }

    public var displayName: String {
        switch self {
        case .uploading: return "Uploading"
        case .queued: return "Queued"
        case .transcribing: return "Transcribing"
        case .matchingSpeakers: return "Matching speakers"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}
