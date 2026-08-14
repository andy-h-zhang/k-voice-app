import KVoiceCore
import SwiftData
import SwiftUI

/// The export menu, shared by the editor's toolbar and the library row's
/// context menu (spec §Export, plan §2 Phase 7).
///
/// One component in one place rather than two menus that drift: the library and
/// the editor must offer the same formats, write to the same folder, and honor
/// the same default. It reports through a closure instead of owning an alert,
/// because the two hosts surface success and failure differently — the editor
/// has a status line, the library has an alert and reveals the file.
struct RecordingExportMenu: View {

    let recordingID: UUID

    /// False for a recording with no utterances yet: there is nothing to
    /// export, and a menu that writes an empty document is worse than a
    /// disabled one.
    let hasTranscript: Bool

    /// Everything the export needs, passed in rather than read from
    /// `@Environment`.
    ///
    /// One of this menu's two homes is a `contextMenu`, whose content macOS
    /// hosts in a platform menu outside the ordinary view tree. Reading
    /// `AppServices` from the environment there is a trap that either works or
    /// crashes depending on SwiftUI's version; taking the three values as
    /// parameters is both safe and honest about what the component needs.
    let container: ModelContainer
    let libraryRoot: URL
    let defaultFormat: ExportFormat

    /// Called with the file that was written, or with what went wrong.
    let onResult: (Result<URL, Error>) -> Void

    var body: some View {
        Menu("Export") {
            Button("Export as \(defaultFormat.displayName)") { export(defaultFormat) }
                .help("Uses the default format from Settings.")

            Divider()

            ForEach(ExportFormat.allCases, id: \.self) { format in
                Button("\(format.displayName) (.\(format.fileExtension))") { export(format) }
            }
        }
        .disabled(!hasTranscript)
    }

    private func export(_ format: ExportFormat) {
        do {
            let url = try TranscriptExport.export(
                recordingID: recordingID,
                container: container,
                libraryRoot: libraryRoot,
                format: format
            )
            onResult(.success(url))
        } catch {
            onResult(.failure(error))
        }
    }
}

/// A draggable chip standing for one of the recording's files.
///
/// The spec wants both the audio and a transcript to be draggable out of the
/// app. A labelled chip makes that affordance visible — a bare row you can
/// happen to drag is not discoverable — and doubles as a "Reveal in Finder"
/// button, which is the same idea expressed for people who do not drag.
struct FileDragChip: View {

    let title: String
    let systemImage: String
    let help: String

    /// Built lazily: the transcript chip *exports* when the drag starts.
    let makeProvider: () -> NSItemProvider

    /// Reveals the file. Nil hides the button (nothing on disk yet).
    var reveal: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            if let reveal {
                Button {
                    reveal()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quinary, in: Capsule())
        .help(help)
        .onDrag { makeProvider() }
    }
}
