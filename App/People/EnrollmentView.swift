import KVoiceCore
import SwiftUI
import UniformTypeIdentifiers

/// The enrollment sheet: both paths spec §Voice profiles gives a user for
/// teaching KVoice a voice on purpose.
///
/// One sheet rather than two because they are the same job with a different
/// first step — pick a source, then window it, embed it, and store it against a
/// person. The visible difference is one section.
struct EnrollmentView: View {

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    let request: EnrollmentRequest
    /// Called once embeddings have actually been stored.
    let onFinished: (EnrollmentModel.Result) -> Void

    @State private var model: EnrollmentModel?
    @State private var isChoosingFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let model {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 560)
        .frame(minHeight: 460)
        .onAppear(perform: build)
        .fileImporter(
            isPresented: $isChoosingFiles,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
    }

    private func build() {
        guard model == nil else { return }
        let model = EnrollmentModel(
            target: request.target,
            mode: request.mode,
            profiles: services.profiles,
            speakerModels: services.speakerModels,
            settings: services.settings
        )
        self.model = model
        // Start the one-time model download now, so it overlaps the read
        // instead of following it.
        model.warmUpModels()
    }

    // MARK: - Layout

    @ViewBuilder
    private func content(_ model: EnrollmentModel) -> some View {
        header(model)
        Divider()

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch model.stage {
                case .finished(let result):
                    FinishedPanel(result: result)
                case .failed(let failure):
                    FailurePanel(failure: failure)
                default:
                    if model.isGuided {
                        guidedBody(model)
                    } else {
                        clipsBody(model)
                    }
                }

                if let notice = model.notice, !model.stage.isBusy || model.stage == .recording {
                    NoticeBanner(
                        icon: "exclamationmark.triangle.fill",
                        tint: .orange,
                        title: "Heads up",
                        message: notice
                    )
                }

                ModelPreparationNotice(state: services.speakerModelState)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Divider()
        footer(model)
    }

    private func header(_ model: EnrollmentModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title(model))
                .font(.title3)
                .fontWeight(.semibold)

            switch request.target {
            case .existing(_, let name):
                Text(
                    model.isGuided
                        ? "Adds to \(name)'s voice profile."
                        : "Adds clips of \(name) to their voice profile."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

            case .newPerson:
                nameField(model)
            }
        }
        .padding(20)
    }

    private func title(_ model: EnrollmentModel) -> String {
        model.isGuided ? "Record a voice" : "Add audio files"
    }

    @ViewBuilder
    private func nameField(_ model: EnrollmentModel) -> some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Name")
                    .foregroundStyle(.secondary)
                TextField("Who is speaking?", text: $model.draftName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.stage.isBusy || isDone(model))
            }
            if nameTaken(model) {
                Label(
                    "“\(model.trimmedName)” is already in your people list.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Guided

    @ViewBuilder
    private func guidedBody(_ model: EnrollmentModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                """
                Read this out loud in your normal speaking voice. KVoice records about \
                \(Int(EnrollmentScript.targetDuration)) seconds and stops on its own.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ScriptView(
                lines: EnrollmentScript.lines,
                highlightedIndex: model.stage == .recording ? model.currentLineIndex : nil
            )

            captureStatus(model)
        }
    }

    @ViewBuilder
    private func captureStatus(_ model: EnrollmentModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Display.elapsed(model.elapsed))
                    .font(.system(size: 30, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("of \(Display.elapsed(EnrollmentScript.targetDuration))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(stageLabel(model))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: model.progress)
                .progressViewStyle(.linear)

            LevelMeter(level: model.level, isActive: model.stage == .recording)
        }
        .padding(14)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func stageLabel(_ model: EnrollmentModel) -> String {
        switch model.stage {
        case .ready: return "Ready"
        case .requestingPermission: return "Waiting for microphone access…"
        case .recording: return "Recording"
        case .finishing: return "Finishing the file…"
        case .reading: return "Reading the audio…"
        case .embedding(let count): return "Embedding \(count) voice sample\(count == 1 ? "" : "s")…"
        case .saving: return "Saving…"
        case .finished: return "Done"
        case .failed: return "Stopped"
        }
    }

    // MARK: - Clips

    @ViewBuilder
    private func clipsBody(_ model: EnrollmentModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                """
                Pick audio files of this person speaking — ideally alone, without crosstalk. \
                Each file is split into 5-second windows and every window becomes its own \
                voice sample.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if model.clipURLs.isEmpty {
                ContentUnavailableView {
                    Label("No files chosen", systemImage: "waveform")
                } description: {
                    Text("Any audio macOS can read: .m4a, .wav, .mp3, .aiff, .caf.")
                } actions: {
                    Button("Choose Audio Files…") { isChoosingFiles = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(minHeight: 190)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.clipURLs, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "waveform")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Choose Different Files…") { isChoosingFiles = true }
                        .buttonStyle(.borderless)
                        .disabled(model.stage.isBusy)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10))

                if model.stage.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(stageLabel(model))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard let model else { return }
        switch result {
        case .success(let urls):
            model.setClips(urls)
        case .failure(let error):
            // A cancelled panel is not an error worth a dialog.
            if (error as NSError).code != NSUserCancelledError {
                model.setClips([])
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(_ model: EnrollmentModel) -> some View {
        HStack(spacing: 10) {
            if case .failed(let failure) = model.stage, failure == .microphoneDenied {
                Button("Open System Settings") {
                    FinderIntegration.openMicrophoneSettings()
                }
            }

            Spacer()

            if isDone(model) {
                Button("Done") { close(model) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { close(model) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.canCancel)

                if case .failed(let failure) = model.stage, failure.isRetryable {
                    Button("Try Again") {
                        Task { await model.retry() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    primaryAction(model)
                }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func primaryAction(_ model: EnrollmentModel) -> some View {
        if model.isGuided {
            switch model.stage {
            case .recording:
                Button("Stop and Save") {
                    Task { await model.finishRecording() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStopEarly)
                .help(
                    model.canStopEarly
                        ? "Use what has been recorded so far"
                        : "Keep reading — at least \(Int(EnrollmentScript.minimumDuration)) seconds are needed"
                )
            default:
                Button("Start Recording") {
                    Task { await model.startRecording() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart(model))
            }
        } else {
            Button("Add \(model.clipURLs.count) File\(model.clipURLs.count == 1 ? "" : "s")") {
                Task { await model.startClipEnrollment() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart(model) || model.clipURLs.isEmpty)
        }
    }

    private func canStart(_ model: EnrollmentModel) -> Bool {
        guard !model.stage.isBusy else { return false }
        guard case .newPerson = request.target else { return true }
        return !model.trimmedName.isEmpty && !nameTaken(model)
    }

    private func nameTaken(_ model: EnrollmentModel) -> Bool {
        guard case .newPerson = request.target, !model.trimmedName.isEmpty else { return false }
        return !services.people.isNameAvailable(model.trimmedName)
    }

    private func isDone(_ model: EnrollmentModel) -> Bool {
        if case .finished = model.stage { return true }
        return false
    }

    private func close(_ model: EnrollmentModel) {
        if case .finished(let result) = model.stage {
            onFinished(result)
        }
        Task { await model.tearDown() }
        dismiss()
    }
}

// MARK: - Script

/// The text to read, with the line the reader should be near highlighted.
///
/// The highlight is why the script is a list rather than one paragraph: without
/// a sense of pace people finish in eight seconds and then sit in silence,
/// which produces windows of nothing.
private struct ScriptView: View {

    let lines: [String]
    let highlightedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.title3)
                    .foregroundStyle(foreground(for: index))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(index == highlightedIndex ? Color.accentColor.opacity(0.14) : .clear)
                    )
                    .animation(.easeInOut(duration: 0.25), value: highlightedIndex)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func foreground(for index: Int) -> HierarchicalShapeStyle {
        guard let highlightedIndex else { return .primary }
        if index == highlightedIndex { return .primary }
        return index < highlightedIndex ? .quaternary : .secondary
    }
}

// MARK: - Panels

private struct FinishedPanel: View {

    let result: EnrollmentModel.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Voice added", systemImage: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)

            Text(
                """
                \(result.added) voice sample\(result.added == 1 ? "" : "s") stored for \
                \(result.personName), who now has \(result.total) in total.
                """
            )
            .fixedSize(horizontal: false, vertical: true)

            if result.evicted > 0 {
                Text(
                    """
                    \(result.evicted) older sample\(result.evicted == 1 ? "" : "s") \
                    dropped to stay within the \(SpeakerProfile.defaultEmbeddingCap)-sample limit.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                """
                The next recording you transcribe will be matched against this. \
                Recognition keeps improving as KVoice hears them in real meetings.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FailurePanel: View {

    let failure: EnrollmentModel.Failure

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            Text(failure.message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if case .modelsUnavailable = failure {
                Button("Show Model Folder") {
                    let folder = FluidAudioEmbedder.defaultModelDirectory
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    FinderIntegration.open(folder)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Progress of the one-time ~100 MB CoreML download (plan §3 risk 3).
///
/// Shown wherever it can happen, because an unexplained multi-minute pause on
/// first use is indistinguishable from a hang.
struct ModelPreparationNotice: View {

    let state: SpeakerModelState

    var body: some View {
        if state.isPreparing {
            VStack(alignment: .leading, spacing: 8) {
                Label("Preparing on-device voice models", systemImage: "arrow.down.circle")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(
                    """
                    About 100 MB, downloaded once and kept. Everything after this runs offline. \
                    \(state.message ?? "")
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if state.fractionCompleted > 0 {
                    ProgressView(value: state.fractionCompleted)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
