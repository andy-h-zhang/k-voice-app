import Foundation
import KVoiceCore
import Observation

/// Live transcription state, keyed by recording.
///
/// The library's status badges read from here first and fall back to the
/// persisted `RecordingStatus` on the row. That split is deliberate:
///
/// - **The database is the truth after the fact.** It survives relaunch and is
///   what a fresh list shows.
/// - **The job's event stream is the truth while it runs.** It reports
///   `Uploading → Queued → Transcribing → Matching speakers → Done / Failed`
///   as the job writes each one, without the list re-fetching on a timer.
///
/// Nothing here decides anything; it is a mailbox that
/// ``TranscriptionCoordinator`` fills and views observe.
@MainActor
@Observable
final class JobStatusStore {

    /// The most recent event per recording.
    private(set) var latest: [UUID: TranscriptionJobEvent] = [:]

    /// Recordings with a job actively running right now.
    private(set) var running: Set<UUID> = []

    /// Called when a job stops running, so the library can re-read the rows
    /// the job just rewrote (participant names, duration, status).
    @ObservationIgnored
    var onFinished: ((UUID) -> Void)?

    func markRunning(_ id: UUID) {
        running.insert(id)
    }

    func publish(_ event: TranscriptionJobEvent) {
        latest[event.recordingID] = event
    }

    func markFinished(_ id: UUID) {
        running.remove(id)
        onFinished?(id)
    }

    /// Drops everything known about a recording — used when it is deleted.
    func forget(_ id: UUID) {
        latest[id] = nil
        running.remove(id)
    }

    /// The status to display: the live one when a job has spoken, otherwise
    /// what is persisted on the row.
    func status(for id: UUID, fallback: RecordingStatus) -> RecordingStatus {
        latest[id]?.status ?? fallback
    }

    /// The job's human-readable detail for this recording, if any — the
    /// failure message, the transcript id, the number of speakers matched.
    func detail(for id: UUID) -> String? {
        latest[id]?.detail
    }
}

/// Progress of the one-time on-device speaker-model download (~100 MB).
///
/// Surfaced because the first transcription of a fresh install spends minutes
/// in "Matching speakers" while CoreML models come down from Hugging Face, and
/// an unexplained pause there looks exactly like a hang (plan §3 risk 3).
@MainActor
@Observable
final class SpeakerModelState {

    private(set) var message: String?
    private(set) var fractionCompleted: Double = 0

    var isPreparing: Bool { message != nil }

    func update(_ progress: ModelPreparationProgress) {
        message = progress.message
        fractionCompleted = progress.fractionCompleted
    }

    func finish() {
        message = nil
        fractionCompleted = 0
    }
}
