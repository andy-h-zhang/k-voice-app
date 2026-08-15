import KVoiceCore
import SwiftUI

/// The record scene: one prominent control, an honest clock, and a level meter.
///
/// Everything it shows comes from ``RecordingSessionModel``, which mirrors
/// `MicSource`. In particular the elapsed time is the source's
/// `recordedDuration` — audio actually written — so a paused recording's clock
/// stops, and the number on screen is the number of seconds in the file.
struct RecordView: View {

    @Environment(AppServices.self) private var services

    private var session: RecordingSessionModel { services.recorder }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 28) {
                clock
                meter
                transport
                deviceRow
            }
            .frame(maxWidth: 420)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 12) {
                if let notice = session.notice {
                    NoticeBanner(
                        icon: "exclamationmark.triangle.fill",
                        tint: .orange,
                        title: "Recording paused",
                        message: notice
                    )
                }
                if session.permission == .denied {
                    microphoneDeniedBanner
                }
                if let saved = session.lastSaved {
                    savedBanner(saved)
                }
                if !services.hasAPIKey {
                    APIKeyBanner()
                }
            }
            .frame(maxWidth: 560)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .navigationTitle("Record")
        .onAppear { session.refresh() }
        .alert(
            "Recording problem",
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            ),
            presenting: session.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Pieces

    private var clock: some View {
        VStack(spacing: 6) {
            // Deliberately no `.contentTransition(.numericText())`. This text
            // is rewritten ten times a second, and a numeric-text transition
            // takes longer than 100 ms to play — so each one was interrupted by
            // the next and the window never reached a still frame. A monospaced
            // digit clock does not need the digits to slide; it needs the main
            // thread free.
            Text(Display.elapsed(session.elapsed))
                .font(.system(size: 60, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(session.isActive ? .primary : .secondary)

            Text(statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var statusLine: String {
        switch session.phase {
        case .idle: return "Ready to record"
        case .starting: return "Starting…"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .saving: return "Saving…"
        }
    }

    private var meter: some View {
        LevelMeter(level: session.level, isActive: session.phase == .recording)
            .padding(.horizontal, 24)
    }

    private var transport: some View {
        HStack(spacing: 16) {
            if session.isActive {
                Button {
                    Task { await session.togglePause() }
                } label: {
                    Label(
                        session.phase == .paused ? "Resume" : "Pause",
                        systemImage: session.phase == .paused ? "play.fill" : "pause.fill"
                    )
                    .frame(minWidth: 84)
                }
                .controlSize(.large)
                .keyboardShortcut(" ", modifiers: [])
            }

            Button {
                Task {
                    if session.isActive {
                        await session.stop()
                    } else {
                        // Anything playing from the library is coming out of
                        // the speakers and would be recorded back in.
                        services.libraryPlayback.stop()
                        await session.start()
                    }
                }
            } label: {
                Label(
                    session.isActive ? "Stop" : "Record",
                    systemImage: session.isActive ? "stop.fill" : "record.circle"
                )
                .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(session.isActive ? .secondary : .red)
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(session.phase == .starting || session.phase == .saving)
        }
    }

    /// The input picker, directly under the transport.
    ///
    /// "Which microphone is this using?" is a question people ask *at* the
    /// record button, a moment before they start talking — so the answer, and
    /// the way to change it, belong here rather than only behind ⌘,. The
    /// setting is the same one Settings writes (`SettingsStore.inputDeviceUID`,
    /// stored by the device's stable UID), so the two screens cannot disagree.
    private var deviceRow: some View {
        Menu {
            Picker("Input device", selection: inputSelection) {
                Text("System default").tag(nil as String?)

                ForEach(session.inputDevices) { device in
                    Text(title(for: device)).tag(device.uid as String?)
                }

                // A chosen device that has been unplugged stays in the menu and
                // stays selected: silently falling back to the built-in
                // microphone is how a meeting gets recorded on the wrong input.
                if let missing = session.missingDeviceUID {
                    Text("Not connected — \(missing)").tag(missing as String?)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button("Refresh Device List") {
                Task { await session.refreshInputDevices() }
            }
        } label: {
            Label {
                Text(session.deviceName ?? "No input device")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: session.deviceName == nil ? "mic.slash" : "mic")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(session.isActive)
        .font(.callout)
        .foregroundStyle(.secondary)
        .help(
            session.isActive
                ? "A recording keeps the device it started on. Stop it to switch inputs."
                : "Choose which microphone the next recording uses."
        )
        .task { await session.refreshInputDevices() }
    }

    private var inputSelection: Binding<String?> {
        Binding(
            get: { services.recorder.selectedDeviceUID },
            set: { services.recorder.selectInputDevice(uid: $0) }
        )
    }

    private func title(for device: AudioInputDevice) -> String {
        var text = device.name
        if device.isDefault { text += " (system default)" }
        if device.inputChannelCount > 1 { text += " — \(device.inputChannelCount) ch" }
        return text
    }

    private var microphoneDeniedBanner: some View {
        NoticeBanner(
            icon: "mic.slash.fill",
            tint: .red,
            title: "Microphone access is off",
            message: """
                KVoice cannot record until macOS grants it microphone access. Turn it on in \
                System Settings ▸ Privacy & Security ▸ Microphone, then come back.
                """
        ) {
            Button("Open System Settings") {
                FinderIntegration.openMicrophoneSettings()
            }
        }
    }

    private func savedBanner(_ saved: RecordingSessionModel.SavedRecording) -> some View {
        NoticeBanner(
            icon: "checkmark.circle.fill",
            tint: .green,
            title: "Saved “\(saved.title)”",
            message: saved.enqueued
                ? "Transcription has started. Watch its progress in Recordings."
                : "It is in your library, ready to transcribe once an API key is set."
        ) {
            HStack(spacing: 8) {
                Button("Dismiss") { session.dismissSavedConfirmation() }
                Button("Show in Library") {
                    services.navigation.section = .recordings
                    services.library.selection = saved.id
                    session.dismissSavedConfirmation()
                }
            }
        }
    }
}

// MARK: - Banner

/// A one-line-plus-detail notice, used for every non-modal message in the app
/// so they all read the same way.
struct NoticeBanner<Accessory: View>: View {

    let icon: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder var accessory: () -> Accessory

    init(
        icon: String,
        tint: Color,
        title: String,
        message: String,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.message = message
        self.accessory = accessory
    }

    /// Beside the text when there is room, underneath it when there is not.
    ///
    /// Every banner in the app carries a paragraph and one or two buttons, and
    /// the narrowest column they appear in — the person detail next to the
    /// people list — is around 300 points. Side by side at that width, the
    /// paragraph is squeezed into a ten-character ribbon and the buttons
    /// truncate to "Re…". Stacking is the layout that survives.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                symbol
                text
                Spacer(minLength: 8)
                accessory()
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    symbol
                    text
                    Spacer(minLength: 0)
                }
                accessory()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var symbol: some View {
        Image(systemName: icon)
            .foregroundStyle(tint)
            .font(.title3)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Without a stated ideal, the paragraph's ideal width is the whole
        // string on one line, `ViewThatFits` never judges the side-by-side
        // arrangement to fit, and every banner stacks even in a wide window.
        .frame(idealWidth: 300, alignment: .leading)
    }
}

/// The default experience today: no key anywhere, so nothing can be
/// transcribed. It says so once, in the same words everywhere, and points at
/// the one place that fixes it.
struct APIKeyBanner: View {

    var body: some View {
        NoticeBanner(
            icon: "key.horizontal.fill",
            tint: .orange,
            title: "Transcription is off",
            message: "Add your AssemblyAI key in Settings to transcribe. Recordings are saved either way."
        ) {
            SettingsLink {
                Text("Open Settings…")
            }
        }
    }
}
