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
    /// Pushes the Phase-5 transcript editor for this recording.
    let onOpenTranscript: (LibraryRow) -> Void

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

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                title
                metadata
                if !row.participantNames.isEmpty {
                    participants
                }
                if status.kind == .recorded, !canTranscribe {
                    Text("Add your AssemblyAI key in Settings to transcribe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            audioDragHandle

            StatusBadge(status: status, detail: services.jobStatus.detail(for: row.id))

            primaryAction
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        // Double-click opens the transcript, as every other macOS library does.
        .onTapGesture(count: 2) {
            guard hasTranscript else { return }
            onOpenTranscript(row)
        }
        .contextMenu { menu }
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
            if hasTranscript {
                Button("Transcript") { onOpenTranscript(row) }
                    .help("Open the transcript editor.")
            }
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
        Button("Open Transcript") { onOpenTranscript(row) }
            .disabled(!hasTranscript)

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
        services.library.rename(id: row.id, to: newTitle)
    }

    private func cancelRename() {
        editingID = nil
        draftTitle = ""
    }
}
