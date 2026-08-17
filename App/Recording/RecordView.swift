import KVoiceCore
import SwiftUI
import UniformTypeIdentifiers

/// The record scene: one prominent control, an honest clock, and a level meter.
///
/// Everything it shows comes from ``RecordingSessionModel``, which mirrors
/// `MicSource`. In particular the elapsed time is the source's
/// `recordedDuration` — audio actually written — so a paused recording's clock
/// stops, and the number on screen is the number of seconds in the file.
struct RecordView: View {

    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    private var session: RecordingSessionModel { services.recorder }

    @State private var isChoosingFiles = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 28) {
                clock
                meter
                transport
                VStack(spacing: 14) {
                    deviceRow
                    uploadButton
                }
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
                if let pending = session.pendingName {
                    NameRecordingBanner(pending: pending) { typed in
                        session.commitName(typed)
                    }
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
                // Rounded is the clock's native personality; a theme with a
                // display face of its own (Nocturne's serif, Graphite's mono)
                // takes over here, the one display moment in the app.
                .font(.system(
                    size: 60,
                    weight: .light,
                    design: theme.spec.displayDesign == .standard ? .rounded : theme.displayDesign
                ))
                .monospacedDigit()
                .foregroundStyle(session.isActive ? .primary : .secondary)

            HStack(spacing: 6) {
                // The tally light. "Recording" is a word among other words —
                // "Paused", "Saving…", "Ready to record" all render the same
                // way, so telling them apart means reading. A red dot is the
                // one signal that reads at a glance from across a desk, and it
                // pulses so a glance also confirms the app is still live rather
                // than frozen on a stale frame.
                //
                // Only during `.recording`: a dot that stayed put while paused
                // would be a tally light that lies, which is worse than none.
                if session.phase == .recording {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                        .accessibilityHidden(true)
                }

                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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
                        // Nothing to silence first: selecting the Record tab
                        // tore down whichever recording was open, and the
                        // editor releases the audio device on the way out.
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
            // ⌘R lives in the Go menu, not here. A shortcut on this button only
            // fires while this button is on screen, so it could not stop a
            // recording from the transcript you wandered off to read — and two
            // views claiming one key equivalent is how you get a dead shortcut.
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

    /// Bring audio in that was recorded somewhere else.
    ///
    /// Under the transport rather than in a menu, because "I already have the
    /// file" is a first-class way to start: a call recorded in Zoom, a voice
    /// memo from a phone, an interview someone sent you. What comes out the
    /// other side is a recording like any other — same folder, same library
    /// row, same automatic transcription.
    private var uploadButton: some View {
        Button {
            isChoosingFiles = true
        } label: {
            if session.isImporting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Importing…")
                }
                .frame(minWidth: 96)
            } else {
                Label("Upload", systemImage: "square.and.arrow.down")
                    .frame(minWidth: 96)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(session.isActive || session.isImporting)
        .help(
            session.isActive
                ? "Finish the current recording first."
                : "Add audio files you already have — they land in your library like a recording."
        )
        .fileImporter(
            isPresented: $isChoosingFiles,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task {
                if let id = await session.importAudio(from: urls) {
                    // One file: go straight to it, which is where the user was
                    // heading anyway. Several: stay put, because jumping to an
                    // arbitrary one of them would hide the rest.
                    if urls.count == 1 { services.navigation.openRecording(id) }
                }
            }
        }
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
                Button("Open Recording") {
                    services.navigation.openRecording(saved.id)
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

    @Environment(\.theme) private var theme

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
        .background {
            // Glass themes wash their material with the palette's tint — the
            // wash goes *under* the content, over the material.
            let shape = RoundedRectangle(cornerRadius: theme.isSystem ? 8 : theme.radius.medium)
            shape
                .fill(theme.surface)
                .overlay { shape.fill(theme.surfaceTint ?? .clear) }
        }
        .overlay {
            // The minimal themes draw a hairline instead of casting a shadow.
            if let border = theme.surfaceBorder {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .strokeBorder(border)
                    .allowsHitTesting(false)
            }
        }
        .themeShadow(theme)
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

    @Environment(AppServices.self) private var services

    var body: some View {
        NoticeBanner(
            icon: "key.horizontal.fill",
            tint: .orange,
            title: "Transcription is off",
            message: "Add your AssemblyAI key in Settings to transcribe. Recordings are saved either way."
        ) {
            // Was a `SettingsLink`, which opened the separate Settings window.
            // Settings is a tab now, so this is a plain navigation — and the
            // window stays where it is.
            Button("Open Settings…") { services.navigation.select(.settings) }
        }
    }
}
