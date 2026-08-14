import Foundation
import Testing

@testable import KVoiceCore

/// api-notes decision 2: start ~3 s, grow geometrically, cap at 30 s, with an
/// optional `audio_duration`-aware first delay.
@Suite("Poll backoff schedule")
struct PollBackoffTests {

    @Test("defaults match the documented policy")
    func defaults() {
        let backoff = PollBackoff()
        #expect(backoff.initialDelay == 3)
        #expect(backoff.maxDelay == 30)
        #expect(backoff.multiplier == 1.5)
    }

    @Test("delays grow geometrically from the initial delay")
    func geometricGrowth() {
        let backoff = PollBackoff()
        #expect(backoff.delay(forAttempt: 0) == 3)
        #expect(abs(backoff.delay(forAttempt: 1) - 4.5) < 1e-9)
        #expect(abs(backoff.delay(forAttempt: 2) - 6.75) < 1e-9)
        #expect(abs(backoff.delay(forAttempt: 3) - 10.125) < 1e-9)
    }

    @Test("delays are capped and stay capped")
    func capped() {
        let backoff = PollBackoff()
        #expect(backoff.delay(forAttempt: 10) == 30)
        #expect(backoff.delay(forAttempt: 100) == 30)
        // pow() overflows to infinity long before this; the cap must still hold.
        #expect(backoff.delay(forAttempt: 10_000) == 30)
    }

    @Test("delays never decrease")
    func monotonic() {
        let backoff = PollBackoff()
        var previous = 0.0
        for attempt in 0..<20 {
            let delay = backoff.delay(forAttempt: attempt)
            #expect(delay >= previous)
            previous = delay
        }
    }

    /// A 60-minute meeting shouldn't burn ~20 pointless requests in its first
    /// minute — but a 10-second clip shouldn't idle either.
    @Test("a known audio duration scales the first delay, within the bounds")
    func durationAwareFirstDelay() {
        let backoff = PollBackoff()

        // 10% of 40 s = 4 s, inside 3...30.
        #expect(abs(backoff.delay(forAttempt: 0, audioDurationSeconds: 40) - 4) < 1e-9)
        // 10% of a 60-minute meeting is 360 s → clamped down to the 30 s cap.
        #expect(backoff.delay(forAttempt: 0, audioDurationSeconds: 3_600) == 30)
        // 10% of a 10 s clip is 1 s → floored at the 3 s initial delay.
        #expect(backoff.delay(forAttempt: 0, audioDurationSeconds: 10) == 3)
        // Nonsense durations fall back to the default schedule.
        #expect(backoff.delay(forAttempt: 0, audioDurationSeconds: 0) == 3)
        #expect(backoff.delay(forAttempt: 0, audioDurationSeconds: -5) == 3)
    }

    @Test("duration-aware delays also grow and cap")
    func durationAwareGrowth() {
        let backoff = PollBackoff()
        #expect(abs(backoff.delay(forAttempt: 1, audioDurationSeconds: 40) - 6) < 1e-9)
        #expect(backoff.delay(forAttempt: 5, audioDurationSeconds: 40) == 30)
    }

    // MARK: - HTTP retry delays (decision 3)

    @Test("retry delays double from 2 s and cap at 30 s")
    func retryDelays() {
        #expect(PollBackoff.retryDelay(forAttempt: 0) == 2)
        #expect(PollBackoff.retryDelay(forAttempt: 1) == 4)
        #expect(PollBackoff.retryDelay(forAttempt: 2) == 8)
        #expect(PollBackoff.retryDelay(forAttempt: 3) == 16)
        #expect(PollBackoff.retryDelay(forAttempt: 4) == 30)
        #expect(PollBackoff.retryDelay(forAttempt: 99) == 30)
    }

    @Test("a server-supplied Retry-After wins, but is still capped")
    func retryAfterHonored() {
        #expect(PollBackoff.retryDelay(forAttempt: 0, retryAfter: 7) == 7)
        #expect(PollBackoff.retryDelay(forAttempt: 3, retryAfter: 1) == 1)
        #expect(PollBackoff.retryDelay(forAttempt: 0, retryAfter: 600) == 30)
        // A nonsensical value falls back to the schedule.
        #expect(PollBackoff.retryDelay(forAttempt: 1, retryAfter: 0) == 4)
    }
}
