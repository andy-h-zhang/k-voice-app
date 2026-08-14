import Foundation
import KVoiceCore
import Observation
import SwiftData

/// The app's composition root: every long-lived object, built once at launch
/// and handed to the views through the SwiftUI environment.
///
/// Views own no services and no logic. They read `@Observable` state from the
/// models hanging off this object and call methods on them; everything that
/// could be tested lives in `KVoiceCore` (plan §1: "the app layer holds
/// `@Observable` view models").
///
/// ## Why the store and the database live together
///
/// `KVoiceSchema.onDisk(inLibraryRoot:)` puts `KVoice.store` inside the
/// user-visible library folder (default `~/Documents/KVoice`), so moving or
/// backing up that folder takes the database with it.
@MainActor
@Observable
final class AppServices {

    // MARK: - Core

    let settings: SettingsStore
    let keychain: any APIKeyStore
    let container: ModelContainer
    let recordingStore: RecordingStore
    let profiles: SwiftDataProfileSource

    // MARK: - App models

    let jobStatus: JobStatusStore
    let speakerModelState: SpeakerModelState
    let library: LibraryModel
    let transcription: TranscriptionCoordinator
    let recorder: RecordingSessionModel
    let navigation = NavigationModel()

    /// The one on-device embedder, shared by transcription *and* enrollment.
    ///
    /// Phase 6 needs a handle on it: enrolling a voice runs the same CoreML
    /// models a transcription's speaker-matching stage does, and a second
    /// instance would mean a second ~100 MB download and a second copy of the
    /// models in memory.
    let speakerModels: SpeakerModels

    /// The People section (spec §Voice profiles).
    let people: PeopleModel

    /// Settings state that has to outlive the Settings window — chiefly a
    /// storage-folder move that is waiting on a relaunch.
    let appSettings: AppSettingsModel

    /// Whether an AssemblyAI key can be resolved right now — the environment
    /// variable or the Keychain (``APIKeyResolver``).
    ///
    /// Observable rather than computed on demand so that saving a key in
    /// Settings immediately lights up every "Transcribe" affordance in the
    /// library without a relaunch.
    private(set) var hasAPIKey: Bool

    /// Where the recording library lives.
    var libraryRoot: URL { settings.storageFolderURL }

    init(
        settings: SettingsStore = SettingsStore(),
        keychain: any APIKeyStore = KeychainAPIKeyStore()
    ) throws {
        self.settings = settings
        self.keychain = keychain

        // The library root has to exist before the store file goes inside it.
        let root = settings.storageFolderURL
        let recordingStore = RecordingStore(rootURL: root)
        try recordingStore.createRootIfNeeded()
        self.recordingStore = recordingStore

        let container = try KVoiceSchema.onDisk(inLibraryRoot: root)
        self.container = container

        let profiles = SwiftDataProfileSource(container: container)
        self.profiles = profiles

        let jobStatus = JobStatusStore()
        self.jobStatus = jobStatus

        let speakerModelState = SpeakerModelState()
        self.speakerModelState = speakerModelState

        let library = LibraryModel(container: container, store: recordingStore)
        self.library = library

        let speakerModels = SpeakerModels(state: speakerModelState)
        self.speakerModels = speakerModels

        let transcription = TranscriptionCoordinator(
            container: container,
            settings: settings,
            keychain: keychain,
            profiles: profiles,
            speakerModels: speakerModels,
            status: jobStatus
        )
        self.transcription = transcription

        let recorder = RecordingSessionModel(
            settings: settings,
            store: recordingStore,
            library: library,
            transcription: transcription
        )
        self.recorder = recorder

        let people = PeopleModel(
            profiles: profiles,
            speakerModels: speakerModels,
            speakerModelState: speakerModelState,
            settings: settings
        )
        self.people = people

        self.appSettings = AppSettingsModel(
            settings: settings,
            store: recordingStore
        )

        self.hasAPIKey = APIKeyResolver.resolve(keychain: keychain) != nil

        // Wiring, once every stored property exists.

        // A job that reaches a terminal state has written participant names
        // and a duration the list is showing — so the list re-reads itself.
        // It may also have *auto-learned* a voice, which changes embedding
        // counts (and can add a whole person) in the People section.
        jobStatus.onFinished = { [weak library, weak people] _ in
            library?.reload()
            Task { await people?.reload() }
        }

        // Deleting or renaming a person changes the participant names the
        // library list is showing, so it re-reads itself for the same reason.
        people.onProfilesChanged = { [weak library] in library?.reload() }

        // Moving the library folder moves files out from under anything
        // writing into them, so Settings asks first whether that is safe.
        appSettings.busyReason = { [weak recorder, weak jobStatus] in
            if recorder?.isActive == true {
                return "a recording is in progress"
            }
            let running = jobStatus?.running.count ?? 0
            if running > 0 {
                return running == 1
                    ? "a transcription is still running"
                    : "\(running) transcriptions are still running"
            }
            return nil
        }

        // The quit guard runs from `NSApplicationDelegate`, which SwiftUI
        // instantiates outside this object graph, so it needs a way back in.
        AppQuitGuard.recorder = recorder

        library.reload()
        transcription.resumeInFlight()
    }

    // MARK: - API key

    /// Re-reads the key sources. Cheap; called after any Settings edit.
    func refreshAPIKeyState() {
        hasAPIKey = APIKeyResolver.resolve(keychain: keychain) != nil
    }

    /// Saves a key to the login Keychain and refreshes dependent UI.
    func saveAPIKey(_ key: String) throws {
        try keychain.setAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
        refreshAPIKeyState()
    }

    /// Removes the stored key.
    func removeAPIKey() throws {
        try keychain.deleteAPIKey()
        refreshAPIKeyState()
    }

    /// Whether the resolved key came from the environment, in which case
    /// Settings can only explain, not change, what is in force.
    var apiKeyComesFromEnvironment: Bool {
        let value = ProcessInfo.processInfo.environment[APIKeyResolver.environmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(value?.isEmpty ?? true)
    }
}

// MARK: - Bootstrap

/// The result of building ``AppServices``.
///
/// Launch can genuinely fail — an unwritable library folder, a store file from
/// an incompatible schema — and a meeting recorder that dies on launch with no
/// explanation is worse than one that says which folder it could not open.
enum AppBootstrap {
    case ready(AppServices)
    case failed(message: String, path: String)

    /// Built at most once per process.
    ///
    /// The result is stored in the `App`'s `@State`, and a second evaluation of
    /// that initial value would open a *second* `ModelContainer` on the same
    /// store file — two SQLite writers on one database, for a value that would
    /// then be thrown away.
    @MainActor private static var cached: AppBootstrap?

    @MainActor
    static func make() -> AppBootstrap {
        if let cached { return cached }

        let settings = SettingsStore()
        let result: AppBootstrap
        do {
            result = .ready(try AppServices(settings: settings))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            result = .failed(message: message, path: settings.storageFolderURL.path)
        }
        cached = result
        return result
    }
}
