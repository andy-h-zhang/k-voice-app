import KVoiceCore
import SwiftUI

/// Builds the editor's model from the app's services.
///
/// A separate wrapper because the model needs the `ModelContainer` and the
/// profile source, which arrive through the environment and are therefore not
/// available in a `View`'s initializer.
struct TranscriptEditorScreen: View {

    let recordingID: UUID

    @Environment(AppServices.self) private var services
    @State private var model: TranscriptEditorModel?

    var body: some View {
        Group {
            if let model {
                TranscriptEditorView(model: model)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: recordingID) {
            let model = TranscriptEditorModel(
                recordingID: recordingID,
                container: services.container,
                profiles: services.profiles,
                libraryRoot: services.libraryRoot
            )
            model.reload()
            self.model = model
            await model.refreshPeople()
        }
    }
}

/// The transcript editor (spec §Library and editor, plan §2 Phase 5).
///
/// Turns with `Speaker — [hh:mm:ss]` headers, paragraphs that edit in place,
/// synced playback along the bottom, and every speaker operation the spec asks
/// for. The grouping is `TranscriptDocument`'s, so what is on screen is exactly
/// what an export produces.
struct TranscriptEditorView: View {

    let model: TranscriptEditorModel

    @Environment(AppServices.self) private var services
    @State private var playback = TranscriptPlayback()
    @State private var followPlayback = true
    @State private var assignment: SpeakerAssignmentRequest?
    @State private var merge: SpeakerMergeRequest?
    @State private var lastExport: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.isEmpty {
                emptyState
            } else {
                transcript
            }

            Divider()
            TransportBar(playback: playback)
        }
        .navigationTitle(model.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarItems }
        // Keyed to the recording, not to "appeared once": if this view is ever
        // reused for a different recording — which is exactly what happens the
        // day the editor becomes a split-view detail pane — the player, the
        // duration and the spans must all be rebuilt rather than left pointing
        // at the previous meeting.
        .task(id: model.recordingID) {
            playback.stop()
            playback.load(url: model.audioURL)
            playback.setSpans(model.orderedUtterances)
        }
        .onDisappear {
            // The screen is going away: get every pending keystroke into the
            // database before the model does, and hand the audio device back.
            model.flushPendingEdits()
            playback.stop()
            // Naming a speaker here changes the library's "detected
            // participants" column. The list re-reads itself on pop rather
            // than trusting `onAppear` to fire on the way back — in a
            // NavigationStack the root never actually went away.
            services.library.reload()
        }
        .onChange(of: model.turns) { _, _ in
            playback.setSpans(model.orderedUtterances)
        }
        .sheet(item: $assignment) { request in
            SpeakerAssignmentSheet(
                request: request,
                people: model.people,
                arePeopleLoaded: model.arePeopleLoaded,
                context: assignmentContext(for: request)
            ) { choice in
                Task { await apply(choice, to: request) }
            }
        }
        .confirmationDialog(
            mergeQuestion,
            isPresented: Binding(get: { merge != nil }, set: { if !$0 { merge = nil } }),
            presenting: merge
        ) { request in
            Button("Merge Speakers", role: .destructive) {
                Task { await model.mergeSpeaker(labeled: request.sourceLabel, into: request.destinationLabel) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(
                "Every line moves under one speaker and the other is removed. "
                    + "This cannot be undone — re-process the transcript to start over."
            )
        }
        .alert(
            "Transcript problem",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                FileDragChip(
                    title: model.audioURL.lastPathComponent,
                    systemImage: "waveform",
                    help: "Drag the audio file out, or click to show it in Finder."
                ) {
                    FileDrag.provider(for: model.audioURL)
                } reveal: {
                    FinderIntegration.reveal(model.audioURL)
                }

                FileDragChip(
                    title: "\(model.title).\(defaultFormat.fileExtension)",
                    systemImage: "doc.text",
                    help: "Drag out a \(defaultFormat.displayName) transcript. "
                        + "Dragging exports it into the recording's folder first."
                ) {
                    // The drag renders from the database, so anything still
                    // sitting in the debounce has to land first — otherwise the
                    // file that leaves the app is missing the user's last
                    // sentence, and they have no way to know.
                    model.flushPendingEdits()
                    return FileDrag.transcriptProvider(
                        recordingID: model.recordingID,
                        container: services.container,
                        libraryRoot: services.libraryRoot,
                        format: defaultFormat
                    )
                } reveal: {
                    // The folder rather than the file: an export may not have
                    // been written yet, and the folder is where it will land.
                    FinderIntegration.reveal(lastExport ?? model.folderURL)
                }
                .disabled(model.isEmpty)

                Spacer()
            }

            if !model.speakers.isEmpty {
                SpeakersBar(
                    speakers: model.speakers,
                    onAssign: { assignment = $0 },
                    onMerge: { merge = $0 },
                    onClear: { model.clearSpeaker(labeled: $0) }
                )
            }

            if let status = model.statusMessage {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            if let failure = playback.loadFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.turns) { turn in
                        TurnView(
                            turn: turn,
                            model: model,
                            playback: playback,
                            speakers: model.speakers,
                            onAssign: { assignment = $0 },
                            onMerge: { merge = $0 },
                            onClear: { model.clearSpeaker(labeled: $0) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: playback.currentUtteranceIndex) { _, index in
                guard followPlayback, playback.isPlaying, let index else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(ParagraphAnchor(utteranceIndex: index), anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Transcript Yet", systemImage: "text.bubble")
        } description: {
            Text("Transcribe this recording from the library to edit its speakers and text.")
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem {
            Toggle(isOn: $followPlayback) {
                Label("Follow Playback", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .help("Scroll the transcript to keep up with playback.")
        }

        ToolbarItem {
            RecordingExportMenu(
                recordingID: model.recordingID,
                hasTranscript: !model.isEmpty,
                container: services.container,
                libraryRoot: services.libraryRoot,
                defaultFormat: defaultFormat,
                // Same reason as the drag chip: an export renders from the
                // rows, so the debounce has to be drained before it reads them.
                willExport: { model.flushPendingEdits() }
            ) { result in
                switch result {
                case .success(let url):
                    lastExport = url
                    model.statusMessage = "Exported \(url.lastPathComponent)."
                case .failure(let error):
                    model.errorMessage = "Could not export: \(LibraryModel.describe(error))"
                }
            }
        }

        ToolbarItem {
            Button {
                FinderIntegration.reveal(lastExport ?? model.audioURL)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Show this recording's folder in Finder.")
        }
    }

    // MARK: - Helpers

    private var defaultFormat: ExportFormat {
        services.settings.defaultExportFormat
    }

    private var subtitle: String {
        let speakers = model.speakers.count
        return "\(Display.rowDate(model.createdAt)) · \(Display.duration(model.durationSec))"
            + " · \(speakers) speaker\(speakers == 1 ? "" : "s")"
    }

    private var mergeQuestion: String {
        guard let merge,
            let source = model.speaker(labeled: merge.sourceLabel),
            let destination = model.speaker(labeled: merge.destinationLabel)
        else { return "Merge these speakers?" }
        return "Merge “\(source.displayName)” into “\(destination.displayName)”?"
    }

    /// The explanatory line the assignment sheet shows.
    private func assignmentContext(for request: SpeakerAssignmentRequest) -> String? {
        switch request {
        case .speaker(let label):
            return model.speaker(labeled: label)?.nearMissDescription
        case .utterance(let index):
            guard let utterance = model.utterance(index) else { return nil }
            return "Currently \(utterance.speakerName). Only this line moves."
        }
    }

    private func apply(_ choice: PersonChoice, to request: SpeakerAssignmentRequest) async {
        switch request {
        case .speaker(let label):
            await model.assignSpeaker(labeled: label, to: choice)
        case .utterance(let index):
            await model.reassignUtterance(index, to: choice)
        }
        await model.refreshPeople()
    }
}

// MARK: - Speakers bar

/// The recording's speakers as chips, each a menu of the operations that apply
/// to a whole diarized speaker.
///
/// A per-slot control rather than only the turn headers, because two slots can
/// carry the same display name once both are assigned to one person — and
/// "merge these two" needs to address the slots unambiguously.
struct SpeakersBar: View {

    let speakers: [EditorSpeaker]
    let onAssign: (SpeakerAssignmentRequest) -> Void
    let onMerge: (SpeakerMergeRequest) -> Void
    let onClear: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(speakers) { speaker in
                    Menu {
                        SpeakerMenuItems(
                            speaker: speaker,
                            allSpeakers: speakers,
                            onAssign: onAssign,
                            onMerge: onMerge,
                            onClear: onClear
                        )
                    } label: {
                        chip(speaker)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
    }

    private func chip(_ speaker: EditorSpeaker) -> some View {
        HStack(spacing: 6) {
            Image(systemName: speaker.isUnknown ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill")
                .foregroundStyle(speaker.isUnknown ? .orange : .secondary)
            Text(speaker.displayName)
                .fontWeight(.medium)
            Text("\(speaker.utteranceCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quinary, in: Capsule())
        .help(helpText(speaker))
    }

    private func helpText(_ speaker: EditorSpeaker) -> String {
        var parts = ["Diarized speaker \(speaker.label)"]
        if let near = speaker.nearMissDescription { parts.append(near) }
        if speaker.isConfirmed { parts.append("Confirmed by you") }
        if !speaker.hasClusterEmbedding {
            parts.append("No voice sample — naming this speaker will not train a profile")
        }
        return parts.joined(separator: " · ")
    }
}

/// The speaker operations, as menu items. Shared by the chips and the turn
/// headers so both offer exactly the same set.
struct SpeakerMenuItems: View {

    let speaker: EditorSpeaker
    let allSpeakers: [EditorSpeaker]
    let onAssign: (SpeakerAssignmentRequest) -> Void
    let onMerge: (SpeakerMergeRequest) -> Void
    let onClear: (String) -> Void

    var body: some View {
        Button(speaker.isUnknown ? "Name This Speaker…" : "Reassign to Another Person…") {
            onAssign(.speaker(label: speaker.label))
        }

        if !speaker.isUnknown {
            Button("Mark as Unknown") { onClear(speaker.label) }
        }

        let others = allSpeakers.filter { $0.label != speaker.label }
        if !others.isEmpty {
            Menu("Merge Into") {
                ForEach(others) { other in
                    Button(other.displayName) {
                        onMerge(
                            SpeakerMergeRequest(
                                sourceLabel: speaker.label,
                                destinationLabel: other.label
                            )
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Transport

/// Play/pause, skip, scrubber, and the clock — standard transport over the
/// recording's audio.
struct TransportBar: View {

    let playback: TranscriptPlayback

    var body: some View {
        HStack(spacing: 14) {
            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 22)
            }
            .buttonStyle(.borderless)
            // Deliberately not the space bar: this screen's main activity is
            // typing into a transcript, and a no-modifier key equivalent is
            // consumed before the focused text field ever sees it.
            .keyboardShortcut("k", modifiers: [.command])
            .help(playback.isPlaying ? "Pause (⌘K)" : "Play (⌘K)")

            Button { playback.skip(by: -15) } label: {
                Image(systemName: "gobackward.15")
            }
            .buttonStyle(.borderless)

            Button { playback.skip(by: 15) } label: {
                Image(systemName: "goforward.15")
            }
            .buttonStyle(.borderless)

            Text(Display.elapsed(playback.currentTime))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { playback.scrub(to: $0) }
                ),
                in: 0...max(playback.duration, 0.001)
            ) { editing in
                playback.isScrubbing = editing
            }

            Text(Display.elapsed(playback.duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .disabled(!playback.isLoaded)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
