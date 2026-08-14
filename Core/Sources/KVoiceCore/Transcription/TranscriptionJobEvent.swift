import Foundation

/// One observable step of a `TranscriptionJob`.
///
/// The UI-independent progress surface plan §2 Phase 3 asks for: the job
/// publishes these on an `AsyncStream` and the app layer renders them. Core
/// stays free of any UI framework, and the CLI (or a test) can consume the
/// identical stream.
public struct TranscriptionJobEvent: Sendable, Equatable {

    /// Which recording this is about.
    public var recordingID: UUID

    /// The state machine's position, exactly as persisted on the row.
    public var status: RecordingStatus

    /// Human-readable detail: the failure message, the transcript id, the
    /// number of speakers matched. Nil when the status says it all.
    public var detail: String?

    /// 0-based poll index while `status` is `.queued` / `.transcribing`.
    public var pollAttempt: Int?

    public var at: Date

    public init(
        recordingID: UUID,
        status: RecordingStatus,
        detail: String? = nil,
        pollAttempt: Int? = nil,
        at: Date = Date()
    ) {
        self.recordingID = recordingID
        self.status = status
        self.detail = detail
        self.pollAttempt = pollAttempt
        self.at = at
    }

    /// The spec's progress vocabulary (Uploading → Queued → Transcribing →
    /// Matching speakers → Done / Failed), or nil before anything has started.
    public var stage: TranscriptionStage? { status.stage }
}

/// Where a `TranscriptionJob` will pick up when it runs.
///
/// Computed from the persisted row plus what is on disk, and exposed so the
/// app can say "Resume" vs. "Retry" vs. "Re-process" honestly — and so tests
/// can assert the choice without running the pipeline.
///
/// Ordered cheapest-first, which is also the order the job prefers them:
/// re-processing costs nothing, polling costs one request, submitting costs a
/// request, uploading costs the whole file.
public enum TranscriptionResumePlan: Sendable, Equatable {

    /// Already `done`. Running is a no-op; `reprocess()` is the way to redo it.
    case alreadyDone

    /// A finished transcript is on disk. Rebuild utterances and re-match with
    /// **no network at all** — this is what makes a retry after a failed
    /// speaker-match step free, and what the spec means by retaining the raw
    /// response for re-processing.
    case reprocess

    /// A transcript id was persisted before we stopped. Resume by polling it
    /// rather than re-uploading — the relaunch path.
    case poll(transcriptID: String)

    /// The audio is already on the provider's side but no transcript was
    /// created (or the one created ended in a terminal server error). Submit
    /// again without re-uploading the file.
    case submit(uploadURL: String)

    /// Start from the beginning. Still never re-records: the `.m4a` on disk is
    /// the input.
    case upload

    /// Whether following this plan will touch the network.
    public var usesNetwork: Bool {
        switch self {
        case .alreadyDone, .reprocess: return false
        case .poll, .submit, .upload: return true
        }
    }
}
