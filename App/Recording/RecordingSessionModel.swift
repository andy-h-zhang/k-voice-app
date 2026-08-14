import AVFoundation
import Foundation
import KVoiceCore
import Observation

/// The record view's state: one `MicSource`, its file, and what to do with the
/// result.
///
/// Everything hard about capture lives in `MicSource` (Phase 2). This model
/// starts it, mirrors its streams into observable properties, and on stop hands
/// the finished folder to the library and the new row to the transcription
/// coordinator — the "one action" of the acceptance criteria.
@MainActor
@Observable
final class RecordingSessionModel {

    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case paused
        /// `stop()` is finalizing the file and writing the row.
        case saving
    }

    /// Microphone authorization, as the UI needs to talk about it.
    enum Permission: Equatable {
        case unknown
        case notDetermined
        case granted
        case denied
    }

    // MARK: - Observable state

    private(set) var phase: Phase = .idle

    /// Seconds of audio actually written — from the source, not a wall clock,
    /// so paused time is excluded and the display matches the file.
    ///
    /// Updated ~10 times a second, so **only the record screen should read
    /// it**: under Observation, every reader of this property is invalidated on
    /// every tick, and a reader that is always on screen (the sidebar) would
    /// re-render the whole window ten times a second for a clock that shows
    /// seconds. Anything outside the record screen wants ``elapsedSeconds``.
    private(set) var elapsed: TimeInterval = 0

    /// The same clock, rounded down to whole seconds and written only when the
    /// value actually changes — so a view reading it re-renders at 1 Hz.
    ///
    /// This exists for the sidebar's recording indicator, which is on screen in
    /// every section and must cost the window nothing to keep there.
    private(set) var elapsedSeconds: Int = 0

    /// Normalized input level (0…1) for the meter.
    private(set) var level: Float = 0

    /// Name of the input device being captured. Selection ships in Settings.
    private(set) var deviceName: String?

    /// A recoverable condition the user should know about (device changed,
    /// disk write failed) — the recording is paused but intact.
    private(set) var notice: String?

    /// A failure that stopped something happening.
    var errorMessage: String?

    private(set) var permission: Permission = .unknown

    /// The row written by the last completed recording, for the "saved"
    /// confirmation and to steer the window to the library.
    private(set) var lastSaved: SavedRecording?

    struct SavedRecording: Equatable {
        let id: UUID
        let title: String
        /// Whether a transcription job was started. False means no API key.
        let enqueued: Bool
    }

    var isActive: Bool { phase == .recording || phase == .paused }
    var canRecord: Bool { phase == .idle }

    // MARK: - Dependencies

    private let settings: SettingsStore
    private let store: RecordingStore
    private let library: LibraryModel
    private let transcription: TranscriptionCoordinator

    // MARK: - Session state

    private var source: MicSource?
    private var folder: RecordingFolder?
    private var startedAt: Date?
    private var levelTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    init(
        settings: SettingsStore,
        store: RecordingStore,
        library: LibraryModel,
        transcription: TranscriptionCoordinator
    ) {
        self.settings = settings
        self.store = store
        self.library = library
        self.transcription = transcription
    }

    // MARK: - Environment

    /// Refreshes the microphone permission state, and starts a refresh of the
    /// input-device name.
    ///
    /// Called whenever the record view appears. Only the permission half is
    /// synchronous — it is a local TCC lookup. The device name is not.
    func refresh() {
        refreshPermission()
        Task { await refreshInputDevice() }
    }

    private func refreshPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = .granted
        case .notDetermined: permission = .notDetermined
        case .denied, .restricted: permission = .denied
        @unknown default: permission = .unknown
        }
    }

    /// Looks the input device's name up **off the main actor**.
    ///
    /// This was the single worst thing the app did on the main thread, and it
    /// did it at the worst possible moment. `AudioDeviceManager` answers by
    /// walking the CoreAudio HAL — `AudioObjectGetPropertyData` for the device
    /// list, then four more per device for UID, name, channel count and sample
    /// rate. Every one of those is a synchronous IPC round trip to `coreaudiod`
    /// that takes the HAL's global lock.
    ///
    /// `start()` called it *immediately after* `MicSource.start()` returned —
    /// i.e. while the HAL was still mid-bring-up of the very device being
    /// opened, with that lock heavily contended. The main thread blocked there
    /// for as long as the HAL wanted, which is why the window stopped redrawing
    /// the instant recording began and the sidebar came back blank. Nothing
    /// hid the sidebar; the main thread was simply not running.
    ///
    /// `Task.detached` rather than a plain `Task`: a plain one inherits the
    /// main actor and would put the HAL walk straight back where it came from.
    /// `AudioInputDevice` is `Sendable`, so only the finished name crosses back.
    private func refreshInputDevice() async {
        let uid = settings.inputDeviceUID
        let name = await Task.detached(priority: .utility) { () -> String? in
            do {
                if let uid {
                    return try AudioDeviceManager.inputDevice(withUID: uid).name
                }
                return try AudioDeviceManager.defaultInputDevice()?.name
            } catch {
                return nil
            }
        }.value
        deviceName = name
    }

    // MARK: - Transport

    func start() async {
        guard phase == .idle else { return }

        errorMessage = nil
        notice = nil
        lastSaved = nil
        elapsed = 0
        elapsedSeconds = 0
        level = 0
        phase = .starting

        let folder: RecordingFolder
        do {
            folder = try store.createRecording(title: Self.defaultTitle(for: Date()))
        } catch {
            phase = .idle
            errorMessage = "Could not create the recording folder: \(Self.describe(error))"
            return
        }

        let source = MicSource(inputDeviceUID: settings.inputDeviceUID)
        do {
            // Asks for microphone access if it has not been asked before.
            try await source.start(writingTo: folder.audioURL)
        } catch {
            // Nothing was written, so leave no empty folder behind.
            try? FileManager.default.removeItem(at: folder.folderURL)
            phase = .idle
            refreshPermission()
            // A denial gets the persistent banner with its "Open System
            // Settings" button, not a modal that says the same thing and then
            // disappears.
            if (error as? RecordingError) != .microphonePermissionDenied {
                errorMessage = Self.describe(error)
            }
            return
        }

        self.source = source
        self.folder = folder
        self.startedAt = Date()
        self.permission = .granted
        phase = .recording
        // Observers first, then the device name. The order is the point: the
        // meter and the clock start moving immediately, and the name — which
        // has to ask the HAL, mid-bring-up, on a background thread — arrives
        // whenever it arrives without holding up a single frame of UI.
        observe(source)
        await refreshInputDevice()
    }

    func pause() async {
        guard phase == .recording, let source else { return }
        await source.pause()
        phase = .paused
    }

    func resume() async {
        guard phase == .paused, let source else { return }
        do {
            try await source.resume()
            phase = .recording
            notice = nil
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func togglePause() async {
        switch phase {
        case .recording: await pause()
        case .paused: await resume()
        default: break
        }
    }

    /// Stops capture, finalizes the `.m4a`, writes the library row, and starts
    /// transcription when a key is available.
    ///
    /// - Returns: The new recording's id, or nil if nothing was captured.
    @discardableResult
    func stop() async -> UUID? {
        guard isActive, let source, let folder else { return nil }
        phase = .saving

        let summary = await source.stop()
        cancelObservers()
        self.source = nil
        self.folder = nil
        level = 0

        let duration = summary?.duration ?? elapsed
        elapsed = duration
        elapsedSeconds = Int(duration)

        guard let summary, summary.frameCount > 0 else {
            // A source that captured nothing (no signal path at all) would
            // otherwise leave an empty folder and a 0-second row in the library.
            try? FileManager.default.removeItem(at: folder.folderURL)
            phase = .idle
            errorMessage = """
                Nothing was recorded — no audio arrived from \
                \(deviceName ?? "the input device"). Check the input device and try again.
                """
            return nil
        }

        do {
            let id = try library.insert(
                folder: folder,
                duration: summary.duration,
                createdAt: startedAt ?? Date()
            )
            // No key is not a failure: the row stays `recorded` and the UI
            // offers to add one.
            let enqueued = transcription.enqueue(id)
            lastSaved = SavedRecording(id: id, title: folder.baseName, enqueued: enqueued)
            phase = .idle
            return id
        } catch {
            phase = .idle
            errorMessage = """
                The audio was saved to \(folder.folderURL.path), but it could not be added \
                to the library: \(Self.describe(error))
                """
            return nil
        }
    }

    /// Stops for an app quit — the file must be finalized or the `.m4a` has no
    /// `moov` atom and will not play.
    func stopForQuit() async {
        guard isActive else { return }
        await stop()
    }

    func dismissSavedConfirmation() {
        lastSaved = nil
    }

    // MARK: - Observing the source

    private func observe(_ source: MicSource) {
        levelTask = Task { [weak self] in
            for await value in source.levelStream {
                self?.level = value
            }
            self?.level = 0
        }

        eventTask = Task { [weak self] in
            for await event in source.events {
                self?.handle(event)
            }
        }

        // The elapsed display is polled from the source rather than counted
        // here: `recordedDuration` is frames actually written, so it stops
        // during a pause and matches the finished file exactly.
        //
        // `weak source` so that this loop is never what holds the last
        // reference to a `MicSource`. It sleeps between polls, so cancellation
        // is not instant, and a strong capture meant a source could outlive
        // `stop()` and then deallocate *here* — on the main actor, which is
        // where this task runs.
        tickTask = Task { [weak self, weak source] in
            while !Task.isCancelled {
                guard let source else { return }
                let seconds = source.recordedDuration
                self?.elapsed = seconds
                // Written only on change: see `elapsedSeconds`.
                let whole = Int(seconds)
                if self?.elapsedSeconds != whole { self?.elapsedSeconds = whole }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func handle(_ event: RecordingEvent) {
        switch event {
        case .started:
            notice = nil

        case .paused(let reason):
            if phase == .recording { phase = .paused }
            switch reason {
            case .user:
                break
            case .deviceLost:
                notice = """
                    The audio input device changed. Recording is paused and everything \
                    captured so far is safe — resume to continue on the current device.
                    """
                Task { await refreshInputDevice() }
            case .interrupted:
                notice = "The system interrupted recording. Resume to continue."
            case .writeFailure:
                notice = """
                    Writing to disk failed. Recording is paused and the file is intact up \
                    to the last frame — free some space, then resume.
                    """
            }

        case .resumed:
            phase = .recording
            notice = nil

        case .stopped:
            break

        case .failed(let error):
            // Device loss and interruptions already produced a pause notice
            // that says the same thing in the user's terms; don't stack a
            // second message on top of it.
            if notice == nil {
                errorMessage = Self.describe(error)
            }
        }
    }

    private func cancelObservers() {
        levelTask?.cancel()
        eventTask?.cancel()
        tickTask?.cancel()
        levelTask = nil
        eventTask = nil
        tickTask = nil
    }

    // MARK: - Helpers

    /// Default title for a new recording: date first, so the library folder
    /// sorts chronologically in Finder, and a time so two meetings on one day
    /// do not become "… 2".
    static func defaultTitle(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d.%02d Recording",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0
        )
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
