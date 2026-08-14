import Foundation

/// The lifecycle of one recording, and the state machine `TranscriptionJob`
/// drives (plan §2 Phase 3):
///
/// ```
/// recorded → uploading → queued → transcribing → matching → done
///                 ↘          ↘          ↘           ↘
///                          failed(message)  ──retry──→ (cheapest resume point)
/// ```
///
/// Persisted on the `Recording` row as two columns — `statusKindRaw` plus
/// `failureMessage` — rather than as one archived enum, because SwiftData
/// `#Predicate` cannot see through a computed property and the app needs to
/// query "what was still in flight when we quit?" on relaunch.
public enum RecordingStatus: Sendable, Equatable, Hashable {

    /// Audio exists on disk; nothing has been sent anywhere yet.
    case recorded
    /// The audio file is being uploaded to the provider.
    case uploading
    /// The provider accepted the job and has not started it.
    case queued
    /// The provider is transcribing.
    case transcribing
    /// The transcript is back; speaker embeddings are being matched locally.
    case matching
    /// Utterances and speaker slots are persisted. Terminal.
    case done
    /// Something failed. Terminal *until* the user retries, which never
    /// re-records: the audio file and, once written, the raw JSON are the
    /// recovery points.
    case failed(message: String)

    /// The storable discriminant. Kept separate from the associated value so
    /// the failure message does not have to be part of every comparison.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case recorded
        case uploading
        case queued
        case transcribing
        case matching
        case done
        case failed
    }

    public var kind: Kind {
        switch self {
        case .recorded: return .recorded
        case .uploading: return .uploading
        case .queued: return .queued
        case .transcribing: return .transcribing
        case .matching: return .matching
        case .done: return .done
        case .failed: return .failed
        }
    }

    /// Non-nil only for `.failed`.
    public var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    /// Rebuilds a status from the two persisted columns.
    public init(kind: Kind, failureMessage: String?) {
        switch kind {
        case .recorded: self = .recorded
        case .uploading: self = .uploading
        case .queued: self = .queued
        case .transcribing: self = .transcribing
        case .matching: self = .matching
        case .done: self = .done
        case .failed: self = .failed(message: failureMessage ?? "Transcription failed.")
        }
    }

    /// Whether the job has stopped moving on its own. `.failed` counts: it
    /// only advances again when the user asks.
    public var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        case .recorded, .uploading, .queued, .transcribing, .matching: return false
        }
    }

    /// Whether a job was mid-flight — the states a relaunch must resume from
    /// rather than restart (plan §2 Phase 3, Phase 8 edge sweep).
    public var isInFlight: Bool {
        switch self {
        case .uploading, .queued, .transcribing, .matching: return true
        case .recorded, .done, .failed: return false
        }
    }

    /// The progress vocabulary the spec asks the UI to show. `.recorded` has no
    /// stage — nothing is happening yet.
    public var stage: TranscriptionStage? {
        switch self {
        case .recorded: return nil
        case .uploading: return .uploading
        case .queued: return .queued
        case .transcribing: return .transcribing
        case .matching: return .matchingSpeakers
        case .done: return .done
        case .failed: return .failed
        }
    }

    public var displayName: String {
        switch self {
        case .recorded: return "Recorded"
        case .failed: return "Failed"
        default: return stage?.displayName ?? kind.rawValue.capitalized
        }
    }
}
