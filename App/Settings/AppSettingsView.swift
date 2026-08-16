import KVoiceCore
import SwiftUI

/// The Settings scene — every value in spec §Settings, editable, and in force
/// without a relaunch.
///
/// The one exception is the storage folder, and it says so where it happens:
/// the library's database is opened once at launch, so moving the folder needs
/// the app to reopen it.
struct AppSettingsView: View {

    @Environment(AppServices.self) private var services

    private var model: AppSettingsModel { services.appSettings }

    var body: some View {
        Form {
            if let path = model.pendingRelaunchPath {
                Section {
                    relaunchBanner(path: path)
                }
            }

            APIKeySection()
            SpeechModelSection()
            StorageSection()
            AudioSection()
            SpeakerMatchingSection()
        }
        .formStyle(.grouped)
        // A reading column, not a fixed panel. Both of the frames that used to
        // be here were written for a standalone Settings window and are actively
        // harmful now that this is the detail column:
        //
        // - `.frame(width: 560)` sets min = ideal = max, so this form would
        //   report a 560-point *minimum*. At the window's 720-point floor that
        //   leaves the sidebar 160 — exactly its own floor, with the toolbar
        //   still pushing — which is the sidebar-collapse failure `RootView`
        //   documents, arriving through a different door.
        // - `.frame(minHeight: 520)` would raise the *window's* minimum height
        //   from 480 to 520 under `.windowResizability(.contentMinSize)`, so the
        //   window would grow the moment you clicked this tab.
        //
        // `maxWidth` centred inside an infinite frame gives the same comfortable
        // measure in a wide window and compresses cleanly in a narrow one, and
        // the form scrolls for its own height.
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            services.appSettings.syncInputChoiceFromSettings()
            await services.appSettings.refreshInputDevices()
        }
        .alert(
            "Settings",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { services.appSettings.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func relaunchBanner(path: String) -> some View {
        NoticeBanner(
            icon: "arrow.triangle.2.circlepath",
            tint: .orange,
            title: "Relaunch to finish moving the library",
            message: """
                Everything has been moved to \(path). This copy of KVoice still has the \
                database open at the old location, so don't record until it has restarted.
                """
        ) {
            Button("Relaunch") { services.appSettings.relaunch() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - API key

/// Unchanged in substance from Phase 4: the key lives in the login Keychain,
/// and an environment variable overrides anything stored there.
private struct APIKeySection: View {

    @Environment(AppServices.self) private var services

    @State private var draftKey = ""
    @State private var saveError: String?
    @State private var didSave = false

    var body: some View {
        Section {
            if services.apiKeyComesFromEnvironment {
                LabeledContent("API key") {
                    Text("Supplied by \(APIKeyResolver.environmentVariable)")
                        .foregroundStyle(.secondary)
                }
            } else if services.hasAPIKey {
                LabeledContent("API key") {
                    HStack(spacing: 8) {
                        Label("Saved in your login Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Remove") { remove() }
                    }
                }
            } else {
                keyEntry
            }

            if let saveError {
                Text(saveError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("AssemblyAI")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    services.apiKeyComesFromEnvironment
                        ? "The environment variable wins over anything saved here. Unset it to use a stored key."
                        : "Stored in the login Keychain, never in a preferences file."
                )
                Link(
                    "Get a key at assemblyai.com/dashboard",
                    destination: URL(string: "https://www.assemblyai.com/dashboard")!
                )
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("API key") {
                HStack(spacing: 8) {
                    SecureField("Paste your key", text: $draftKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if didSave {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
    }

    private func save() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try services.saveAPIKey(key)
            draftKey = ""
            saveError = nil
            didSave = true
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func remove() {
        do {
            try services.removeAPIKey()
            saveError = nil
            didSave = false
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Speech model

/// Which model AssemblyAI is asked for, and whether a fallback is allowed.
///
/// `speech_models` is a priority-ordered array, so the server serves the first
/// model it can and reports which in `speech_model_used`. Naming a fallback is
/// therefore not free: the keyterm budget drops to the lowest among the models
/// named, on every request, used or not. The picker states that consequence
/// rather than leaving it to be discovered.
private struct SpeechModelSection: View {

    @Environment(AppServices.self) private var services

    private var model: AppSettingsModel { services.appSettings }

    private var preference: Binding<SpeechModelPreference> {
        Binding(
            get: { services.appSettings.speechModelPreference },
            set: { services.appSettings.setSpeechModelPreference($0) }
        )
    }

    var body: some View {
        Section {
            Picker("Speech model", selection: preference) {
                ForEach(SpeechModelPreference.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }

            Text(model.speechModelPreference.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Transcription model")
        } footer: {
            Text(
                """
                Applies to the next transcription — a job takes its settings when it is \
                submitted, so anything already running finishes on the model it started \
                with. Recordings remember which model actually transcribed them.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Storage

private struct StorageSection: View {

    @Environment(AppServices.self) private var services

    private var model: AppSettingsModel { services.appSettings }

    var body: some View {
        Section {
            LabeledContent("Library folder") {
                HStack(spacing: 8) {
                    Text(model.libraryRoot.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(model.libraryRoot.path)
                    Button("Show in Finder") { services.appSettings.revealLibrary() }
                    Button("Move…") { services.appSettings.chooseStorageFolder() }
                }
            }

            if let summary = model.moveSummary {
                HStack(alignment: .top, spacing: 8) {
                    Label(summary, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Dismiss") { services.appSettings.dismissMoveSummary() }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text(
                """
                One folder per recording, holding the audio and the raw transcript, plus a \
                shared Transcripts folder holding every exported .md, .txt and .docx — and \
                the app's database, so a backup of this folder is a backup of everything.

                Moving needs an empty or brand-new destination: KVoice moves the whole \
                library in one go and won't merge it with another. Nothing may be recording \
                or transcribing at the time, the old folder is left behind empty, and the \
                app has to relaunch afterwards to reopen its database.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Audio

private struct AudioSection: View {

    @Environment(AppServices.self) private var services

    private var model: AppSettingsModel { services.appSettings }

    private var choice: Binding<AppSettingsModel.InputChoice> {
        Binding(
            get: { services.appSettings.inputChoice },
            set: { services.appSettings.setInputChoice($0) }
        )
    }

    var body: some View {
        Section {
            Picker("Input device", selection: choice) {
                Text("System default").tag(AppSettingsModel.InputChoice.systemDefault)

                if !model.inputDevices.isEmpty {
                    Divider()
                    ForEach(model.inputDevices) { device in
                        Text(label(for: device))
                            .tag(AppSettingsModel.InputChoice.device(uid: device.uid))
                    }
                }

                // A chosen device that is not plugged in stays selectable, so
                // the choice survives unplugging it rather than silently
                // reverting to the built-in microphone.
                if let missing = model.missingDeviceUID {
                    Divider()
                    Text("Not connected — \(missing)")
                        .tag(AppSettingsModel.InputChoice.device(uid: missing))
                }
            }

            LabeledContent("Recording will use") {
                HStack(spacing: 8) {
                    Text(model.effectiveDeviceName)
                        .foregroundStyle(.secondary)
                    Button("Refresh") {
                        Task { await services.appSettings.refreshInputDevices() }
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let deviceError = model.deviceError {
                Text(deviceError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Audio input")
        } footer: {
            Text(
                """
                Used by the next recording and by voice enrollment; a recording already \
                running keeps the device it started on. The choice is stored by the device's \
                stable identifier, so it survives reboots and reconnecting the same interface.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func label(for device: AudioInputDevice) -> String {
        var text = device.name
        if device.isDefault { text += " (system default)" }
        if device.inputChannelCount > 1 { text += " — \(device.inputChannelCount) ch" }
        return text
    }
}

// MARK: - Speaker matching

private struct SpeakerMatchingSection: View {

    @Environment(AppServices.self) private var services

    private var model: AppSettingsModel { services.appSettings }

    private var threshold: Binding<Float> {
        Binding(
            get: { services.appSettings.similarityThreshold },
            set: { services.appSettings.setSimilarityThreshold($0) }
        )
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Similarity threshold") {
                    HStack(spacing: 8) {
                        Text(String(format: "%.2f", model.similarityThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if !model.isThresholdDefault {
                            Button("Reset") { services.appSettings.resetThreshold() }
                                .buttonStyle(.borderless)
                        }
                    }
                }

                Slider(
                    value: threshold,
                    in: SettingsStore.thresholdRange,
                    step: 0.01
                ) {
                    Text("Similarity threshold")
                } minimumValueLabel: {
                    Text("Lenient").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Strict").font(.caption).foregroundStyle(.secondary)
                }
                .labelsHidden()

                Text(model.thresholdExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Speaker matching")
        } footer: {
            Text(
                """
                How close a voice has to be to an enrolled profile before KVoice puts a name \
                to it. Applies to the next transcription — speakers already matched keep the \
                threshold they were judged against, so a change here is never retroactive.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
