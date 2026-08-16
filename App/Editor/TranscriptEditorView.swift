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

/// The recording detail screen (spec §Library and editor, plan §2 Phase 5).
///
/// Turns with `Speaker — [hh:mm:ss]` headers, paragraphs that edit in place,
/// synced playback along the bottom, and every speaker operation the spec asks
/// for. The grouping is `TranscriptDocument`'s, so what is on screen is exactly
/// what an export produces.
///
/// ## It opens for recordings with no transcript, too
///
/// The transport bar and the audio it drives are outside the
/// transcript/empty-state branch, and always have been — but the library only
/// offered a way in once utterances existed, which with no API key configured
/// is *never*. So the app had a player nobody could reach and recordings
/// nobody could listen to. Opening is now unconditional; the middle of the
/// screen explains the missing transcript and offers the thing that would fix
/// it, while the bottom of the screen plays the audio.
struct TranscriptEditorView: View {

    let model: TranscriptEditorModel

    @Environment(AppServices.self) private var services
    @State private var playback = TranscriptPlayback()
    @State private var followPlayback = true
    @State private var assignment: SpeakerAssignmentRequest?
    @State private var merge: SpeakerMergeRequest?
    @State private var didCopy = false

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
        // No `.navigationTitle` or `.navigationSubtitle`. Both moved into
        // `header`, and the reason is the tab picker.
        //
        // A `.principal` toolbar item is *centred*, so AppKit has to balance the
        // leading and trailing regions around it. The title sits leading,
        // alongside the traffic lights and the sidebar toggle, and at the 720pt
        // window floor that side outweighed the trailing side badly enough that
        // AppKit pushed this screen's own buttons into the `»` overflow menu —
        // measured, not guessed. Reclaiming the title's width is what makes the
        // toolbar fit.
        //
        // Nothing is lost by it: the header below has the full width of the
        // window for a title that the toolbar could only ever truncate, and the
        // sidebar is simultaneously highlighting the same recording.
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
        // A finished job rewrote this recording's rows through its own
        // `ModelContext`, and nothing in the model observes the store — so the
        // pane sat on "No Transcript Yet" until the screen was rebuilt, which
        // is exactly what clicking away and back was doing by hand. Reload in
        // place instead, and the empty state's promise that "the transcript
        // appears here when it lands" becomes true.
        //
        // Keyed on the *running* set rather than a `.done` event because
        // `markFinished` fires after the job's terminal event, so the rows are
        // committed by the time this runs. It covers failures too, where the
        // reload is a no-op and the failure message renders as before.
        //
        // Not `.task(id:)` keyed on job status: that rebuilds the whole model
        // and drops pending edits, the data loss `RootView` goes out of its way
        // to avoid.
        .onChange(of: isTranscribing) { wasRunning, isRunning in
            guard wasRunning, !isRunning else { return }
            model.reloadAfterTranscription()
        }
        // The job may have landed while this screen was off-screen entirely —
        // the user watching the sidebar from the Record tab. Nothing is at
        // stake when there is no transcript yet, so re-read on the way in.
        .onAppear {
            if model.isEmpty { model.reloadAfterTranscription() }
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
            // The recording's name and vitals, evicted from the title bar to
            // make room for the tab picker. They read better here anyway: full
            // width instead of truncated, and above the files they describe.
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.title)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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

                // One chip per transcript file, both of which are real files in
                // this recording's own folder. Dragging used to *export* first,
                // because nothing existed until someone asked; now the files
                // are maintained as the transcript changes, so a drag is a
                // plain drag and reveal points at the file itself.
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    FileDragChip(
                        title: model.transcriptFileName(format),
                        systemImage: "doc.text",
                        help: "Drag out the \(format.displayName) transcript, "
                            + "or click to show it in Finder."
                    ) {
                        // Rendered from the database, so anything still sitting
                        // in the debounce has to land first — otherwise the file
                        // that leaves the app is missing the user's last
                        // sentence, and they have no way to know.
                        model.flushPendingEdits()
                        model.syncTranscriptFiles()
                        return FileDrag.provider(for: model.transcriptURL(format))
                    } reveal: {
                        FinderIntegration.reveal(model.transcriptURL(format))
                    }
                    .disabled(model.isEmpty)
                }

                Spacer()

                // Pasting the transcript somewhere is the common case; the drag
                // chips beside this one cover the far rarer "I want the file".
                //
                // `⌘⇧C`, not `⌘C`: every paragraph on this screen is an
                // editable text field, and `⌘C` has to keep meaning "copy my
                // selection" inside one. Same reason the transport bar avoids
                // no-modifier key equivalents.
                Button {
                    copyTranscript()
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(model.isEmpty)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the transcript as plain text.")
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

    /// What an untranscribed recording shows — which, with no API key
    /// configured, is *every* recording.
    ///
    /// This screen is reachable for any recording precisely so that the audio
    /// can be played, so the state says that first: the transport along the
    /// bottom is live and loaded whether or not a transcript exists. The
    /// action is whatever actually unblocks the user — transcribe if a key is
    /// configured, Settings if not — rather than a dead end telling them to go
    /// somewhere else and do something the app could do here.
    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                failureMessage == nil ? "No Transcript Yet" : "Transcription Failed",
                systemImage: failureMessage == nil ? "text.bubble" : "exclamationmark.triangle.fill"
            )
        } description: {
            // Selectable, because a failure message is the thing a user needs to
            // paste into a search box or a bug report, and an API error names
            // the exact status code that makes the difference.
            Text(failureMessage ?? emptyStateDescription)
                .textSelection(.enabled)
        } actions: {
            if isTranscribing {
                ProgressView().controlSize(.small)
            } else if !services.hasAPIKey {
                Button("Open Settings…") { services.navigation.select(.settings) }
                    .buttonStyle(.borderedProminent)
            } else if failureMessage != nil {
                HStack(spacing: 8) {
                    Button("Try Again") { services.transcription.retry(model.recordingID) }
                        .buttonStyle(.borderedProminent)
                    Button("Open Settings…") { services.navigation.select(.settings) }
                }
            } else {
                Button("Transcribe") { services.transcription.enqueue(model.recordingID) }
                    .buttonStyle(.borderedProminent)
                    .help("Upload this recording and identify its speakers.")
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var isTranscribing: Bool {
        services.jobStatus.running.contains(model.recordingID)
    }

    /// The persisted status of this recording, preferring a live job's view of
    /// it over the row that was read when the library last reloaded.
    private var recordingStatus: RecordingStatus {
        services.jobStatus.status(
            for: model.recordingID,
            fallback: services.library.row(id: model.recordingID)?.snapshot.status ?? .recorded
        )
    }

    /// Why the last attempt failed, or nil if none has.
    ///
    /// This screen used to ignore it entirely: a transcription could fail with a
    /// precise, actionable message — "AssemblyAI rejected the API key (401)" —
    /// and the editor would drop straight back to "No Transcript Yet" as though
    /// the button had never been pressed. The message was persisted on the row
    /// and shown only in the sidebar glyph's tooltip, which is not a place
    /// anyone looks after clicking Transcribe.
    private var failureMessage: String? {
        guard !isTranscribing else { return nil }
        return recordingStatus.failureMessage
    }

    private var emptyStateDescription: String {
        if isTranscribing {
            return "Transcribing now. You can play the recording while you wait — "
                + "the transcript appears here when it lands."
        }
        if services.hasAPIKey {
            return "Play the recording with the controls below, or transcribe it to "
                + "edit its speakers and text."
        }
        return "Play the recording with the controls below. Add your AssemblyAI key "
            + "in Settings to transcribe it — the audio is already saved either way."
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // One item, not three.
        //
        // A `.principal` toolbar item is *centred*, so AppKit balances the
        // leading and trailing regions around it and starts pushing things into
        // the `»` overflow well before the toolbar looks full. Measured at the
        // 720-point window floor: three items overflowed, two still overflowed,
        // one fits. That is a bad place for anything and a *very* bad place for
        // the app's primary navigation, which is what would go there next.
        //
        // Follow Playback loses its one-click toggle and becomes a checked menu
        // item, which is the right trade — it is a preference you set once per
        // session, not a control you operate while reading.
        ToolbarItem {
            Menu {
                Toggle("Follow Playback", isOn: $followPlayback)
                    .help("Scroll the transcript to keep up with playback.")

                Divider()

                // No export items. Both transcripts are already written into
                // this recording's folder and kept current, so "export" would
                // mean "write the file that is already there" — the chips in
                // the header reveal and drag the real thing instead.
                Button("Show Project Folder in Finder") {
                    FinderIntegration.reveal(model.audioURL)
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .help("Show this recording in Finder, or follow playback.")
        }
    }

    // MARK: - Helpers

    /// Puts the transcript on the clipboard as plain text.
    ///
    /// Deliberately the plain-text *export*, character for character — title,
    /// date, and `Speaker — [hh:mm:ss]` headers — rather than a second,
    /// slightly-different rendering that would make a pasted transcript
    /// disagree with an exported one.
    private func copyTranscript() {
        // Renders from the database, so the debounce has to drain first — the
        // same reason the transcript drag chip and the export menu do it.
        // Without this, copying right after typing silently omits the last
        // sentence.
        model.flushPendingEdits()

        do {
            let document = try TranscriptExport.document(
                for: model.recordingID,
                container: services.container
            )
            Clipboard.copy(PlainTextRenderer.render(document))
            model.statusMessage = "Copied transcript."

            // The status line says what happened; the glyph says it at the
            // point the user is already looking. It reverts on its own so the
            // button does not sit lying about a copy made minutes ago.
            didCopy = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                didCopy = false
            }
        } catch {
            model.errorMessage = "Could not copy: \(LibraryModel.describe(error))"
        }
    }

    private var subtitle: String {
        let head = "\(Display.rowDate(model.createdAt)) · \(Display.duration(model.durationSec))"
        // "0 speakers" is not information — it is the empty state repeating
        // itself in the title bar.
        let speakers = model.speakers.count
        guard speakers > 0 else { return head }
        return head + " · \(speakers) speaker\(speakers == 1 ? "" : "s")"
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

// MARK: - Previews

// Sub-second iteration on this screen, which otherwise costs a rebuild, a
// relaunch, and — for anything but the empty state — an actual transcription.
// The fixture and the caveats are in `PreviewSupport.swift`; the short version
// is that these are the real services over a throwaway library, so speaker
// assignment, editing, and Copy all genuinely work here.
//
// `TranscriptEditorScreen` rather than `TranscriptEditorView`, so the preview
// exercises the real model construction and its `.task`-driven first load.
// `NavigationStack` so the toolbar has somewhere to render.
#if DEBUG

#Preview("Transcript") {
    let fixture = PreviewFixture.make(.populated)
    NavigationStack {
        TranscriptEditorScreen(recordingID: fixture.recordingID)
    }
    .environment(fixture.services)
    .frame(width: 900, height: 720)
}

#Preview("No Transcript Yet") {
    let fixture = PreviewFixture.make(.empty)
    NavigationStack {
        TranscriptEditorScreen(recordingID: fixture.recordingID)
    }
    .environment(fixture.services)
    .frame(width: 900, height: 720)
}

#Preview("Transcription Failed") {
    let fixture = PreviewFixture.make(.failed)
    NavigationStack {
        TranscriptEditorScreen(recordingID: fixture.recordingID)
    }
    .environment(fixture.services)
    .frame(width: 900, height: 720)
}

#Preview("No API Key") {
    let fixture = PreviewFixture.make(.noAPIKey)
    NavigationStack {
        TranscriptEditorScreen(recordingID: fixture.recordingID)
    }
    .environment(fixture.services)
    .frame(width: 900, height: 720)
}

#endif
