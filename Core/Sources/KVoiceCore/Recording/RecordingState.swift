import Foundation

/// Lifecycle state of an ``AudioSource``.
///
/// Kept as a standalone value type with an explicit transition table so the
/// engine's control flow is unit-testable without touching audio hardware —
/// `MicSource` guards every control call through
/// ``RecordingState/canTransition(to:)``.
public enum RecordingState: String, Sendable, Equatable, CaseIterable {
    /// Created but not started.
    case idle
    /// Capturing and writing frames.
    case recording
    /// Capturing but dropping frames; the file is open.
    case paused
    /// `stop()` is in flight; frames are dropped.
    case stopping
    /// Terminal. The file is finalized.
    case stopped

    /// Whether frames arriving from the tap should be written to disk.
    public var writesFrames: Bool { self == .recording }

    /// Whether the source holds an open file (so a `stop()` has work to do).
    public var holdsOpenFile: Bool { self == .recording || self == .paused }

    /// Whether the state can still be acted on by control calls.
    public var isTerminal: Bool { self == .stopped }

    /// Legal transitions.
    ///
    /// ```
    /// idle ──start──▶ recording ⇄ paused ──stop──▶ stopping ──▶ stopped
    /// ```
    ///
    /// `idle → stopping` covers `stop()` on a source that never started, and
    /// `recording → recording` / `paused → paused` make repeated `pause()` or
    /// device-loss notifications idempotent rather than fatal.
    public func canTransition(to next: RecordingState) -> Bool {
        switch (self, next) {
        case (.idle, .recording), (.idle, .stopping):
            return true
        case (.recording, .paused), (.recording, .stopping), (.recording, .recording):
            return true
        case (.paused, .recording), (.paused, .stopping), (.paused, .paused):
            return true
        case (.stopping, .stopped):
            return true
        default:
            return false
        }
    }
}
