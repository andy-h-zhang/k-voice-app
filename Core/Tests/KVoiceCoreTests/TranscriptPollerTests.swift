import Foundation
import Testing

@testable import KVoiceCore

/// Exercises the polling/retry policy end to end against a **mocked**
/// `TranscriptionProvider` and a virtual clock: no network, no API key, and
/// no real sleeping.
@Suite("Transcript poller")
struct TranscriptPollerTests {

    private func response(_ status: TranscriptResponse.Status, audioDuration: Double? = nil) -> TranscriptResponse {
        TranscriptResponse(id: "t-mock", status: status, audioDuration: audioDuration)
    }

    private func poller(clock: VirtualClock, maxDuration: TimeInterval = 6 * 60 * 60) -> TranscriptPoller {
        TranscriptPoller(
            maxDuration: maxDuration,
            sleep: { try await clock.sleep($0) },
            now: { clock.now() }
        )
    }

    @Test("polls until completed, backing off between attempts")
    func pollsUntilCompleted() async throws {
        let clock = VirtualClock()
        let provider = MockTranscriptionProvider(steps: [
            .response(response(.queued)),
            .response(response(.processing)),
            .response(response(.completed))
        ])

        let result = try await poller(clock: clock).waitForCompletion(provider: provider, id: "t-mock")

        #expect(result.status == .completed)
        #expect(provider.polls == 3)
        #expect(clock.delays.count == 3)
        #expect(clock.delays[0] == 3)
        #expect(abs(clock.delays[1] - 4.5) < 1e-9)
        #expect(abs(clock.delays[2] - 6.75) < 1e-9)
    }

    @Test("reports every intermediate status to the progress handler")
    func reportsProgress() async throws {
        let clock = VirtualClock()
        let provider = MockTranscriptionProvider(steps: [
            .response(response(.queued)),
            .response(response(.processing)),
            .response(response(.completed))
        ])

        let observed = ObservedStatuses()
        _ = try await poller(clock: clock).waitForCompletion(
            provider: provider,
            id: "t-mock",
            onUpdate: { response, attempt in observed.record(response.status, attempt) }
        )

        #expect(observed.statuses == [.queued, .processing, .completed])
        #expect(observed.attempts == [0, 1, 2])
    }

    @Test("a job that ends in error throws, carrying the server's message")
    func errorStatusThrows() async throws {
        let clock = VirtualClock()
        let provider = MockTranscriptionProvider(steps: [
            .response(TranscriptResponse(id: "t-mock", status: .error, error: "invalid audio file"))
        ])

        await #expect(throws: TranscriptionError.transcriptFailed(message: "invalid audio file")) {
            try await poller(clock: clock).waitForCompletion(provider: provider, id: "t-mock")
        }
    }

    /// A network blip 40 minutes into a meeting transcript must not kill the job.
    @Test("a retryable failure is retried without losing the poll sequence")
    func retryableFailureIsRetried() async throws {
        let clock = VirtualClock()
        let provider = MockTranscriptionProvider(steps: [
            .failure(.serverError(status: 503, message: "upstream")),
            .response(response(.completed))
        ])

        let result = try await poller(clock: clock).waitForCompletion(provider: provider, id: "t-mock")

        #expect(result.status == .completed)
        #expect(provider.polls == 2)
        // Backoff delay, then the retry delay, then the backoff delay again.
        #expect(clock.delays == [3, 2, 3])
    }

    @Test("a 429 honors Retry-After")
    func rateLimitHonorsRetryAfter() async throws {
        let clock = VirtualClock()
        let provider = MockTranscriptionProvider(steps: [
            .failure(.rateLimited(retryAfter: 12)),
            .response(response(.completed))
        ])

        _ = try await poller(clock: clock).waitForCompletion(provider: provider, id: "t-mock")
        #expect(clock.delays == [3, 12, 3])
    }

    @Test("a non-retryable failure propagates immediately")
    func nonRetryableFailurePropagates() async throws {
        let clock = VirtualClock()
        let provider = MockTranscriptionProvider(steps: [
            .failure(.unauthorized(message: "bad key")),
            .response(response(.completed))
        ])

        await #expect(throws: TranscriptionError.unauthorized(message: "bad key")) {
            try await poller(clock: clock).waitForCompletion(provider: provider, id: "t-mock")
        }
        #expect(provider.polls == 1)
    }

    @Test("consecutive retryable failures eventually give up")
    func givesUpAfterRepeatedFailures() async throws {
        let clock = VirtualClock()
        let provider = MockTranscriptionProvider(steps: Array(
            repeating: .failure(.transport(description: "offline")),
            count: 10
        ))

        await #expect(throws: TranscriptionError.transport(description: "offline")) {
            try await poller(clock: clock).waitForCompletion(provider: provider, id: "t-mock")
        }
        #expect(provider.polls == AssemblyAIConstants.maxRequestAttempts)
    }

    @Test("a successful poll resets the consecutive-failure count")
    func successResetsFailureCount() async throws {
        let clock = VirtualClock()
        var steps: [MockTranscriptionProvider.Step] = []
        // Three failures, a success, then three more failures — never four in a row.
        for _ in 0..<3 { steps.append(.failure(.serverError(status: 500, message: nil))) }
        steps.append(.response(response(.queued)))
        for _ in 0..<3 { steps.append(.failure(.serverError(status: 500, message: nil))) }
        steps.append(.response(response(.completed)))

        let provider = MockTranscriptionProvider(steps: steps)
        let result = try await poller(clock: clock).waitForCompletion(provider: provider, id: "t-mock")

        #expect(result.status == .completed)
        #expect(provider.polls == 8)
    }

    @Test("polling stops at the maximum duration")
    func timesOut() async throws {
        let clock = VirtualClock()
        let provider = MockTranscriptionProvider(steps: Array(
            repeating: .response(response(.processing)),
            count: 50
        ))

        await #expect(throws: TranscriptionError.pollingTimedOut(transcriptID: "t-mock")) {
            try await poller(clock: clock, maxDuration: 10).waitForCompletion(provider: provider, id: "t-mock")
        }
    }

    /// The first response usually carries `audio_duration`, which should make
    /// every later delay duration-aware even when the caller didn't know it.
    @Test("audio_duration from the first response feeds later delays")
    func learnsAudioDurationFromResponse() async throws {
        let clock = VirtualClock()
        let provider = MockTranscriptionProvider(steps: [
            .response(response(.queued, audioDuration: 3_600)),
            .response(response(.completed))
        ])

        _ = try await poller(clock: clock).waitForCompletion(provider: provider, id: "t-mock")

        #expect(clock.delays[0] == 3)
        // 10% of an hour, clamped to the 30 s cap.
        #expect(clock.delays[1] == 30)
    }

    @Test("a caller-supplied duration applies from the very first delay")
    func callerSuppliedDuration() async throws {
        let clock = VirtualClock()
        let provider = MockTranscriptionProvider(steps: [.response(response(.completed))])

        _ = try await poller(clock: clock).waitForCompletion(
            provider: provider,
            id: "t-mock",
            audioDurationSeconds: 40
        )
        #expect(abs(clock.delays[0] - 4) < 1e-9)
    }
}

/// Collects poller progress callbacks from the concurrency domain they arrive in.
private final class ObservedStatuses: @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [TranscriptResponse.Status] = []
    private var _attempts: [Int] = []

    var statuses: [TranscriptResponse.Status] { lock.withLock { _statuses } }
    var attempts: [Int] { lock.withLock { _attempts } }

    func record(_ status: TranscriptResponse.Status, _ attempt: Int) {
        lock.withLock {
            _statuses.append(status)
            _attempts.append(attempt)
        }
    }
}
