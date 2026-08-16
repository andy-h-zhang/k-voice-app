import SwiftUI

/// A draggable chip standing for one of the recording's files.
///
/// The spec wants both the audio and the transcripts to be draggable out of the
/// app. A labelled chip makes that affordance visible — a bare row you can
/// happen to drag is not discoverable — and doubles as a "Reveal in Finder"
/// button, which is the same idea expressed for people who do not drag.
///
/// One chip per real file in the project folder: the `.m4a` and both
/// transcripts. It used to be two chips, and the transcript one *exported* on
/// drag because no transcript file existed until somebody asked for one.
struct FileDragChip: View {

    let title: String
    let systemImage: String
    let help: String

    /// Built lazily, so a chip can drain the edit debounce before handing over
    /// a file that would otherwise be missing the user's last sentence.
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
