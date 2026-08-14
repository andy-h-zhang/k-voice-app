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

    @Environment(AppServices.self) private var services
    @FocusState private var titleFocused: Bool

    private var status: RecordingStatus {
        services.jobStatus.status(for: row.id, fallback: row.snapshot.status)
    }

    private var isEditing: Bool { editingID == row.id }
    private var isRunning: Bool { services.jobStatus.running.contains(row.id) }
    private var canTranscribe: Bool { services.hasAPIKey }

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

            StatusBadge(status: status, detail: services.jobStatus.detail(for: row.id))

            primaryAction
        }
        .padding(.vertical, 6)
        .contextMenu { menu }
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
