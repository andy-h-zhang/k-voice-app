import Foundation

/// Exponential backoff schedule for polling a transcript job.
///
/// Implements decision 2 of `docs/api-notes.md`: start at ~3 s, grow
/// geometrically, cap at 30 s, with an optional `audio_duration`-aware first
/// delay. Pure value type with no clock of its own so the schedule is unit
/// testable without sleeping (see `PollBackoffTests`).
public struct PollBackoff: Sendable, Equatable {

    /// Delay before the very first poll when the audio duration is unknown.
    public var initialDelay: TimeInterval

    /// Upper bound on any single delay.
    public var maxDelay: TimeInterval

    /// Factor applied to each successive delay.
    public var multiplier: Double

    public init(
        initialDelay: TimeInterval = AssemblyAIConstants.initialPollDelay,
        maxDelay: TimeInterval = AssemblyAIConstants.maxPollDelay,
        multiplier: Double = AssemblyAIConstants.pollBackoffMultiplier
    ) {
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
    }

    /// Delay to wait *before* poll number `attempt` (0-based: attempt 0 is the
    /// first poll after the job is created).
    ///
    /// - Parameter audioDurationSeconds: When known, the first delay is
    ///   `audioDurationPollFraction * duration`, clamped to
    ///   `initialDelay ... maxDelay`. Transcription is much faster than real
    ///   time, so this avoids hammering the API for the first minute of a
    ///   long meeting without risking a long idle wait on a short clip.
    public func delay(forAttempt attempt: Int, audioDurationSeconds: TimeInterval? = nil) -> TimeInterval {
        precondition(attempt >= 0, "attempt must be non-negative")

        let base: TimeInterval
        if let audioDurationSeconds, audioDurationSeconds > 0 {
            let scaled = audioDurationSeconds * AssemblyAIConstants.audioDurationPollFraction
            base = min(max(scaled, initialDelay), maxDelay)
        } else {
            base = initialDelay
        }

        guard attempt > 0 else { return min(base, maxDelay) }

        let grown = base * pow(multiplier, Double(attempt))
        // `pow` can overflow to .infinity for large attempt counts; min() with
        // a finite maxDelay handles that, but guard against NaN explicitly.
        guard grown.isFinite else { return maxDelay }
        return min(grown, maxDelay)
    }

    /// Delay before retry number `attempt` (0-based) of a *failed but
    /// retryable* HTTP request. Honors a server-supplied `Retry-After`.
    public static func retryDelay(forAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter, retryAfter > 0 {
            return min(retryAfter, AssemblyAIConstants.maxPollDelay)
        }
        let grown = AssemblyAIConstants.retryBaseDelay * pow(2, Double(max(attempt, 0)))
        guard grown.isFinite else { return AssemblyAIConstants.maxPollDelay }
        return min(grown, AssemblyAIConstants.maxPollDelay)
    }
}
