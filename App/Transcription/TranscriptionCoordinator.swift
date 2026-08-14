import Foundation
import KVoiceCore
import SwiftData

/// Decides *when* transcription jobs run, and pipes their events to the UI.
///
/// `TranscriptionJob` is the state machine; this is the thing that starts it.
/// It owns no pipeline logic of its own — it builds a job from the current
/// settings snapshot and the resolved API key, drives it, and forwards what it
/// emits to ``JobStatusStore``.
///
/// Main-actor by design, despite starting network work: every method here is
/// bookkeeping. The upload, the polling, and the embedding all happen inside
/// `TranscriptionJob` and `SpeakerModels`, which are actors — so the "UI never
/// blocks" criterion is satisfied by construction, not by moving this class
/// off the main thread.
@MainActor
final class TranscriptionCoordinator {

    private let container: ModelContainer
    private let settings: SettingsStore
    private let keychain: any APIKeyStore
    private let profiles: SwiftDataProfileSource
    private let speakerModels: SpeakerModels
    private let status: JobStatusStore

    /// One job per recording, kept alive while it runs. A job is a state
    /// machine over a row, so two for the same row would race each other.
    private var jobs: [UUID: TranscriptionJob] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(
        container: ModelContainer,
        settings: SettingsStore,
        keychain: any APIKeyStore,
        profiles: SwiftDataProfileSource,
        speakerModels: SpeakerModels,
        status: JobStatusStore
    ) {
        self.container = container
        self.settings = settings
        self.keychain = keychain
        self.profiles = profiles
        self.speakerModels = speakerModels
        self.status = status
    }

    // MARK: - Preconditions

    /// Whether a key is available at all. Without one there is nothing useful
    /// to do, and the UI says so rather than queueing a job that would fail.
    var canTranscribe: Bool {
        APIKeyResolver.resolve(keychain: keychain) != nil
    }

    func isRunning(_ recordingID: UUID) -> Bool {
        tasks[recordingID] != nil
    }

    // MARK: - Driving jobs

    /// Starts (or resumes) transcription for a recording.
    ///
    /// - Returns: `false` when there is no API key, or when a job for this
    ///   recording is already running. A missing key is **not** a failure of
    ///   the recording: the row stays `recorded` and the UI offers to add one.
    @discardableResult
    func enqueue(_ recordingID: UUID, mode: TranscriptionJob.RunMode = .run) -> Bool {
        guard tasks[recordingID] == nil else { return false }

        // Re-processing rebuilds utterances and re-runs speaker matching from
        // the saved response: it never calls the provider, so it must keep
        // working when no key is configured (or after one is removed).
        let resolvedKey = APIKeyResolver.resolve(keychain: keychain)
        guard let apiKey = resolvedKey ?? (mode == .reprocess ? "" : nil) else { return false }

        let snapshot = settings.snapshot()
        let job = TranscriptionJob(
            recordingID: recordingID,
            container: container,
            provider: AssemblyAIClient(apiKey: apiKey),
            matching: PreparingSpeakerMatcher(
                models: speakerModels,
                threshold: snapshot.similarityThreshold
            ),
            profiles: profiles,
            settings: snapshot
        )
        jobs[recordingID] = job
        status.markRunning(recordingID)

        // `start(_:)` subscribes and starts inside one actor-isolated step, so
        // this loop cannot miss the transitions of the run it just began —
        // including a retry, whose row was terminal a moment ago.
        tasks[recordingID] = Task { [weak self] in
            let events = await job.start(mode)
            for await event in events {
                self?.status.publish(event)
            }
            self?.finish(recordingID)
        }
        return true
    }

    /// Retry after a failure, from the cheapest usable entry point: re-process
    /// a saved transcript, re-poll a known id, resubmit an uploaded file, or —
    /// only if none of those apply — upload again. Never re-records.
    @discardableResult
    func retry(_ recordingID: UUID) -> Bool {
        enqueue(recordingID, mode: .retry)
    }

    /// Rebuild utterances and speaker matches from the saved response. No
    /// network at all; also the "re-run speaker ID now that a new person is
    /// enrolled" path.
    @discardableResult
    func reprocess(_ recordingID: UUID) -> Bool {
        enqueue(recordingID, mode: .reprocess)
    }

    /// Restarts whatever was mid-flight when the app last quit.
    ///
    /// The row's persisted `assemblyTranscriptId` means this usually costs one
    /// `GET`, not a re-upload — a two-hour recording that was polling when the
    /// app died resumes rather than starting over.
    func resumeInFlight() {
        guard canTranscribe else { return }
        do {
            let context = ModelContext(container)
            for id in try context.inFlightRecordings().map(\.id) {
                enqueue(id)
            }
        } catch {
            // Nothing actionable: the rows keep their persisted status and the
            // user can retry from the library.
        }
    }

    /// Stops watching a job — used when its recording is deleted.
    ///
    /// Deliberately *not* called "cancel": the job's own run loop is
    /// unstructured work inside the actor and this cannot reach into it. What
    /// it does is drop the subscription and the bookkeeping. A job whose row
    /// has been deleted then ends itself at its next persistence step, which
    /// fails with `recordingNotFound`.
    func stopObserving(_ recordingID: UUID) {
        tasks[recordingID]?.cancel()
        finish(recordingID)
    }

    private func finish(_ recordingID: UUID) {
        tasks[recordingID] = nil
        jobs[recordingID] = nil
        status.markFinished(recordingID)
    }
}
