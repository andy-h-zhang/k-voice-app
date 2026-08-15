import KVoiceCore
import SwiftUI

/// The recording library (spec §Library): title, date, duration, transcription
/// status, and detected participants, with rename, delete, and the per-status
/// actions.
struct LibraryView: View {

    @Environment(AppServices.self) private var services

    @State private var editingID: UUID?
    @State private var draftTitle = ""
    @State private var pendingDelete: LibraryRow?

    /// The recording whose transcript editor is pushed on the stack.
    ///
    /// Local `@State` rather than a `LibraryModel` property: which screen is on
    /// top is a fact about this window, not about the library.
    @State private var openRecordingID: UUID?

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(item: $openRecordingID) { id in
                    TranscriptEditorScreen(recordingID: id)
                }
        }
    }

    private var content: some View {
        @Bindable var library = services.library

        return VStack(spacing: 0) {
            if !services.hasAPIKey && !library.rows.isEmpty {
                APIKeyBanner()
                    .padding([.horizontal, .top], 12)
            }

            if services.speakerModelState.isPreparing {
                modelPreparationBanner
                    .padding([.horizontal, .top], 12)
            }

            if library.rows.isEmpty {
                emptyState
            } else {
                List(selection: $library.selection) {
                    ForEach(library.rows) { row in
                        RecordingRowView(
                            row: row,
                            editingID: $editingID,
                            draftTitle: $draftTitle,
                            onRequestDelete: { pendingDelete = $0 },
                            onOpen: { openRecordingID = $0.id }
                        )
                        .tag(row.id)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }

            Divider()
            storageFooter
        }
        .navigationTitle("Recordings")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button {
                    FinderIntegration.open(services.libraryRoot)
                } label: {
                    Label("Open Library Folder", systemImage: "folder")
                }
                .help("Open \(services.libraryRoot.path) in Finder")
            }
        }
        .onAppear { library.reload() }
        .confirmationDialog(
            "Move “\(pendingDelete?.title ?? "")” to the Trash?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { row in
            Button("Move to Trash", role: .destructive) {
                services.transcription.stopObserving(row.id)
                services.jobStatus.forget(row.id)
                services.libraryPlayback.stopIfPlaying(id: row.id)
                services.library.moveToTrash(id: row.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The audio, the transcript, and any exports move to the Trash together.")
        }
        .alert(
            "Library problem",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            ),
            presenting: library.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            "Playback problem",
            isPresented: Binding(
                get: { services.libraryPlayback.errorMessage != nil },
                set: { if !$0 { services.libraryPlayback.errorMessage = nil } }
            ),
            presenting: services.libraryPlayback.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        // Opening a recording hands playback to the editor, which has its own
        // player and its own transport.
        //
        // Deliberately keyed on that, not on `onDisappear`. This view appears
        // and disappears several times while a `NavigationStack` settles, so
        // stopping there stopped playback a fraction of a second after the play
        // button was pressed — audible as a click and nothing else.
        .onChange(of: openRecordingID) { _, opened in
            if opened != nil { services.libraryPlayback.stop() }
        }
    }

    private var subtitle: String {
        let count = services.library.rows.count
        return count == 1 ? "1 recording" : "\(count) recordings"
    }

    /// Where the files are, stated rather than merely reachable.
    ///
    /// A path bar under the list rather than only the toolbar's folder button:
    /// the first thing a real user wanted to know was *where recordings are
    /// saved*, and an icon offers an action without answering the question. A
    /// footer answers it at a glance, is present in the empty state too (when
    /// the question is most likely), and clicking it opens Finder — so it is
    /// both the answer and the action. Modelled on Finder's own path bar and
    /// Xcode's status bar; deliberately quiet.
    private var storageFooter: some View {
        Button {
            FinderIntegration.open(services.libraryRoot)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(Display.friendlyPath(services.libraryRoot))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .help("Recordings are saved here. Click to open \(services.libraryRoot.path) in Finder.")
        .accessibilityLabel("Recordings folder: \(services.libraryRoot.path). Opens in Finder.")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Recordings", systemImage: "waveform")
        } description: {
            Text("Recordings appear here with their transcripts, speaker names, and exports.")
        } actions: {
            Button("Start Recording") {
                services.navigation.section = .record
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// The ~100 MB one-time model download. Without this the first
    /// "Matching speakers" looks like a hang for several minutes.
    private var modelPreparationBanner: some View {
        // Indeterminate until the downloader reports a fraction, which it only
        // does once it knows the total size.
        let raw = services.speakerModelState.fractionCompleted
        let fraction: Double? = raw > 0 ? raw : nil

        return HStack(spacing: 12) {
            ProgressView(value: fraction, total: 1.0)
                .progressViewStyle(.linear)
                .frame(width: 140)

            VStack(alignment: .leading, spacing: 2) {
                Text("Preparing speaker models")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(services.speakerModelState.message ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}
