import KVoiceCore
import SwiftUI

/// One recording in the library: title, date, duration, live status, and the
/// people found in it.
///
/// The row holds no state of its own beyond the rename draft it is lent. Its
/// status comes from ``JobStatusStore`` while a job runs and from the persisted
/// row otherwise, so the badge advances through
/// `Uploading → Queued → Transcribing → Matching speakers → Done` live, and
/// still reads correctly after a relaunch.
struct RecordingRowView: View {

    let row: LibraryRow

    @Binding var editingID: UUID?
    @Binding var draftTitle: String
    let onRequestDelete: (LibraryRow) -> Void
    /// Pushes the recording's detail screen — the transcript editor when there
    /// is a transcript, the player and a "no transcript yet" state when there
    /// is not. Every row can be opened.
    let onOpen: (LibraryRow) -> Void

    @Environment(AppServices.self) private var services
    @FocusState private var titleFocused: Bool

    private var status: RecordingStatus {
        services.jobStatus.status(for: row.id, fallback: row.snapshot.status)
    }

    private var isEditing: Bool { editingID == row.id }
    private var isRunning: Bool { services.jobStatus.running.contains(row.id) }
    private var canTranscribe: Bool { services.hasAPIKey }

    /// Whether there is anything to edit or export yet.
    private var hasTranscript: Bool { row.snapshot.utteranceCount > 0 }

    private var audioURL: URL {
        row.folderURL.appendingPathComponent(row.snapshot.audioFileName)
    }

    private var playback: LibraryPlayback { services.libraryPlayback }

    /// Whether this row is the one the library player has loaded.
    private var isLoaded: Bool { playback.recordingID == row.id }

    private var isPlayingThisRow: Bool { isLoaded && playback.isPlaying }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                title
                metadata
                if !row.participantNames.isEmpty {
                    participants
                }
                if isLoaded {
                    transport
                }
                // No per-row "add your API key" line. The banner at the top of
                // the list already says it once, and repeating it under every
                // recording buried the thing each row is actually for — its
                // title, date and length — under a sentence that is identical
                // twenty times over. The disabled Transcribe button still
                // carries the explanation in its tooltip.
            }

            Spacer(minLength: 12)

            playButton

            audioDragHandle

            finderButton

            StatusBadge(status: status, detail: services.jobStatus.detail(for: row.id))

            primaryAction

            openButton
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        // Double-click opens the recording, as every other macOS library does.
        // Unconditionally: an untranscribed recording still has audio to play,
        // and a row that silently ignores a double-click reads as broken.
        .onTapGesture(count: 2) { onOpen(row) }
        .contextMenu { menu }
    }

    // MARK: - Playback

    /// Play this recording without leaving the list.
    ///
    /// Every row has audio — that is the one thing a KVoice recording always
    /// has, transcript or not — so this button is never disabled and never
    /// depends on an API key. It is the first control in the trailing cluster
    /// because "let me hear it again" is the most common reason to come back to
    /// this list at all.
    private var playButton: some View {
        Button {
            playback.toggle(id: row.id, url: audioURL)
        } label: {
            Image(systemName: isPlayingThisRow ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isLoaded ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        .help(isPlayingThisRow ? "Pause" : "Play this recording")
        .accessibilityLabel(isPlayingThisRow ? "Pause" : "Play")
    }

    /// The scrubber, shown only on the row that is loaded.
    ///
    /// Inline rather than in a player bar at the bottom of the window: with one
    /// recording playing at a time, the row *is* the player, and a separate bar
    /// would leave the user matching a title in two places.
    private var transport: some View {
        HStack(spacing: 8) {
            Text(Display.duration(playback.currentTime))
                .monospacedDigit()

            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { services.libraryPlayback.scrub(to: $0) }
                ),
                in: 0...max(playback.duration, 0.01),
                onEditingChanged: { editing in
                    services.libraryPlayback.isScrubbing = editing
                }
            )
            .controlSize(.mini)

            Text(Display.duration(playback.duration))
                .monospacedDigit()

            Button {
                services.libraryPlayback.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .help("Close the player")
            .accessibilityLabel("Stop playback")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 420)
        .padding(.top, 2)
    }

    /// The always-visible way to find this recording on disk.
    ///
    /// Persistent rather than hover-revealed, and next to the drag handle it
    /// pairs with: "where is this file?" was the first question a real user
    /// asked, and the answer was buried in a context menu nobody opens. It is
    /// styled as a secondary control so a list of twenty rows does not read as
    /// twenty buttons.
    private var finderButton: some View {
        Button {
            FinderIntegration.reveal(row.folderURL)
        } label: {
            Image(systemName: "folder")
                .font(.callout)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Show this recording's folder in Finder — \(row.folderURL.path)")
        .accessibilityLabel("Show in Finder")
    }

    /// The disclosure affordance every macOS list that pushes a detail screen
    /// carries. Enabled for every row, transcript or not.
    private var openButton: some View {
        Button {
            onOpen(row)
        } label: {
            Image(systemName: "chevron.right")
                .font(.callout)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(hasTranscript ? "Open the transcript editor." : "Open this recording to play it.")
        .accessibilityLabel("Open recording")
    }

    /// Drag-out of the audio (spec §Export), on a grab handle rather than the
    /// whole row.
    ///
    /// `onDrag` applied to the row wraps everything inside it in a drag
    /// gesture, and on macOS that takes precedence over the `List`'s own
    /// click-to-select and over the double-click that opens the transcript —
    /// so the row-wide version cost two working interactions to add one. A
    /// dedicated handle keeps all three.
    private var audioDragHandle: some View {
        Image(systemName: "waveform")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onDrag { FileDrag.provider(for: audioURL) }
            .help("Drag the audio file out of KVoice.")
            .accessibilityLabel("Drag audio file")
    }

    // MARK: - Title

    @ViewBuilder
    private var title: some View {
        if isEditing {
            TextField("Title", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .focused($titleFocused)
                .onSubmit(commitRename)
                .onExitCommand(perform: cancelRename)
                .onAppear { titleFocused = true }
                .onChange(of: titleFocused) { _, focused in
                    // Clicking away commits, which is what every other inline
                    // rename on this platform does.
                    if !focused, isEditing { commitRename() }
                }
                .frame(maxWidth: 360)
        } else {
            Text(row.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                // The row is dense enough that a long title is always
                // truncated; hovering should still answer which one this is.
                .help(row.title)
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(Display.rowDate(row.createdAt))
            Text("·")
            Text(Display.duration(row.durationSec))
                .monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var participants: some View {
        Label {
            Text(row.participantNames.joined(separator: ", "))
                .lineLimit(1)
        } icon: {
            Image(systemName: "person.2")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    @ViewBuilder
    private var primaryAction: some View {
        switch status {
        case .recorded:
            Button("Transcribe") { services.transcription.enqueue(row.id) }
                .disabled(!canTranscribe || isRunning)
                .help(
                    canTranscribe
                        ? "Upload this recording and identify its speakers."
                        : "Add your AssemblyAI key in Settings to transcribe."
                )

        case .failed:
            Button("Retry") { services.transcription.retry(row.id) }
                .disabled(!canTranscribe || isRunning)
                .help(retryHelp)

        default:
            // Nothing: the trailing chevron opens this row, and it is there for
            // every row rather than only the transcribed ones.
            EmptyView()
        }
    }

    private var retryHelp: String {
        guard canTranscribe else { return "Add your AssemblyAI key in Settings to transcribe." }
        return row.hasRawTranscript
            ? "Rebuild from the saved transcript — no upload, no network."
            : "Resume from the cheapest point: the recording is never made again."
    }

    @ViewBuilder
    private var menu: some View {
        // Never disabled: without a transcript this opens the player and the
        // "no transcript yet" state, which is exactly what someone with no API
        // key needs to reach.
        Button(hasTranscript ? "Open Transcript" : "Open Recording") { onOpen(row) }

        Button(isPlayingThisRow ? "Pause" : "Play") {
            playback.toggle(id: row.id, url: audioURL)
        }

        Button("Rename…") { beginRename() }

        if status.kind == .recorded {
            Button("Transcribe") { services.transcription.enqueue(row.id) }
                .disabled(!canTranscribe || isRunning)
        }
        if status.kind == .failed {
            Button("Retry") { services.transcription.retry(row.id) }
                .disabled(!canTranscribe || isRunning)
        }
        if row.hasRawTranscript {
            // No network and no key needed: this rebuilds utterances and
            // re-runs speaker matching from the saved response.
            Button("Re-process Transcript") { services.transcription.reprocess(row.id) }
                .disabled(isRunning)
        }
        Divider()

        // Phase 7's app half: the same menu the editor's toolbar carries.
        // Exporting reveals the file, since a library row has nowhere to
        // report success.
        RecordingExportMenu(
            recordingID: row.id,
            hasTranscript: hasTranscript,
            container: services.container,
            libraryRoot: services.libraryRoot,
            defaultFormat: services.settings.defaultExportFormat
        ) { result in
            switch result {
            case .success(let url):
                FinderIntegration.reveal(url)
            case .failure(let error):
                services.library.errorMessage = "Could not export: \(LibraryModel.describe(error))"
            }
        }

        Button("Show in Finder") { FinderIntegration.reveal(row.folderURL) }

        Divider()

        Button("Move to Trash…", role: .destructive) { onRequestDelete(row) }
    }

    // MARK: - Rename

    private func beginRename() {
        draftTitle = row.title
        editingID = row.id
    }

    private func commitRename() {
        guard isEditing else { return }
        let newTitle = draftTitle
        editingID = nil
        // A rename moves the folder and the `.m4a` inside it, so an open player
        // would be holding a path that no longer exists.
        services.libraryPlayback.stopIfPlaying(id: row.id)
        services.library.rename(id: row.id, to: newTitle)
    }

    private func cancelRename() {
        editingID = nil
        draftTitle = ""
    }
}
