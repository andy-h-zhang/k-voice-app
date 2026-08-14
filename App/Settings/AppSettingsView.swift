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
            StorageSection()
            AudioSection()
            SpeakerMatchingSection()
            KeytermsSection()
            ExportSection()
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 520)
        .onAppear { services.appSettings.refreshInputDevices() }
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
                One folder per recording, holding the audio, the raw transcript, and any \
                exports — plus the app's database, so a backup of this folder is a backup of \
                everything.

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
                    Button("Refresh") { services.appSettings.refreshInputDevices() }
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

// MARK: - Keyterms

private struct KeytermsSection: View {

    @Environment(AppServices.self) private var services

    private var model: AppSettingsModel { services.appSettings }

    var body: some View {
        @Bindable var model = services.appSettings

        Section {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $model.keytermsText)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: model.keytermsText) { _, _ in
                        services.appSettings.commitKeyterms()
                    }

                let report = model.keytermReport
                HStack(spacing: 8) {
                    Text("\(report.accepted.count) term\(report.accepted.count == 1 ? "" : "s")")
                    Text("·")
                    Text("\(report.wordsUsed) / \(KeytermReport.wordBudget) words")
                        .foregroundStyle(report.isOverBudget ? .orange : .secondary)
                        .monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if let problems = report.problemSummary {
                    Label(problems, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !report.tooLong.isEmpty {
                    Text(report.tooLong.prefix(3).map { "“\($0)”" }.joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } header: {
            Text("Keyterms")
        } footer: {
            Text(
                """
                One per line. Names, jargon, and product words the transcriber would \
                otherwise guess at — up to \(AssemblyAIConstants.maxWordsPerKeyterm) words \
                each and \(KeytermReport.wordBudget) words in total. Anything past those \
                limits is dropped by the API silently, so the count above shows what will \
                actually be sent.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Export

private struct ExportSection: View {

    @Environment(AppServices.self) private var services

    private var format: Binding<ExportFormat> {
        Binding(
            get: { services.appSettings.defaultExportFormat },
            set: { services.appSettings.setDefaultExportFormat($0) }
        )
    }

    var body: some View {
        Section {
            Picker("Default format", selection: format) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Text("\(format.displayName) (.\(format.fileExtension))")
                        .tag(format)
                }
            }
        } header: {
            Text("Export")
        } footer: {
            Text("What the one-click export button produces. Every format stays available per recording.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
