import KVoiceCore
import SwiftUI

/// One recording in the sidebar: what it is, when it was made, how long it runs,
/// and — only when there is something to say — how its transcription is going.
///
/// ## Why it is this thin
///
/// Its predecessor carried a play button, a scrubber, a drag handle, a Finder
/// button, a full status badge, a Transcribe button and a disclosure chevron.
/// That was a reasonable row in a full-width list; in a 200-point column it
/// would be seven controls fighting over the space the title needs, and the
/// title is the only part that tells you which recording this is.
///
/// So the row shows what identifies a recording and nothing else. Everything it
/// used to carry still exists: the actions are on the context menu, and playback,
/// dragging and export are one click away in the detail screen — which clicking
/// the row now opens directly, rather than after a second navigation.
struct RecordingSidebarRow: View {

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
    private var hasTranscript: Bool { row.snapshot.utteranceCount > 0 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                title
                metadata
            }

            Spacer(minLength: 0)

            StatusBadge(
                status: status,
                detail: services.jobStatus.detail(for: row.id),
                style: .glyph
            )
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
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
                .frame(maxWidth: .infinity)
        } else {
            Text(row.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                // A 200-point column truncates almost every title, so hovering
                // has to be able to answer which recording this is.
                .help(row.title)
        }
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            Text(Display.rowDate(row.createdAt))
            Text("·")
            Text(Display.duration(row.durationSec))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    // MARK: - Context menu

    @ViewBuilder
    private var menu: some View {
        Button("Rename…") { beginRename() }

        Divider()

        if status.kind == .recorded {
            Button("Transcribe") { services.transcription.enqueue(row.id) }
                .disabled(!canTranscribe || isRunning)
                .help(
                    canTranscribe
                        ? "Upload this recording and identify its speakers."
                        : "Add your AssemblyAI key in Settings to transcribe."
                )
        }
        if status.kind == .failed {
            Button("Retry") { services.transcription.retry(row.id) }
                .disabled(!canTranscribe || isRunning)
                .help(retryHelp)
        }
        if row.hasRawTranscript {
            // No network and no key needed: this rebuilds utterances and
            // re-runs speaker matching from the saved response.
            Button("Re-process Transcript") { services.transcription.reprocess(row.id) }
                .disabled(isRunning)
        }

        Divider()

        RecordingExportMenu(
            recordingID: row.id,
            hasTranscript: hasTranscript,
            container: services.container,
            libraryRoot: services.libraryRoot,
            defaultFormat: services.settings.defaultExportFormat
        ) { result in
            switch result {
            case .success(let url):
                // A sidebar row has nowhere to report success, so the file
                // itself is the receipt.
                FinderIntegration.reveal(url)
            case .failure(let error):
                services.library.errorMessage = "Could not export: \(LibraryModel.describe(error))"
            }
        }

        Button("Show in Finder") { FinderIntegration.reveal(row.folderURL) }

        Divider()

        Button("Move to Trash…", role: .destructive) { onRequestDelete(row) }
    }

    private var retryHelp: String {
        guard canTranscribe else { return "Add your AssemblyAI key in Settings to transcribe." }
        return row.hasRawTranscript
            ? "Rebuild from the saved transcript — no upload, no network."
            : "Resume from the cheapest point: the recording is never made again."
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
