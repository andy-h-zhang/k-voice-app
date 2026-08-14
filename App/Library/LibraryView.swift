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
                            onOpenTranscript: { openRecordingID = $0.id }
                        )
                        .tag(row.id)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
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
    }

    private var subtitle: String {
        let count = services.library.rows.count
        return count == 1 ? "1 recording" : "\(count) recordings"
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
