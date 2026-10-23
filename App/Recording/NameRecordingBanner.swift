import AppKit
import SwiftUI

/// The last step of recording: name it.
///
/// Appears the moment `stop()` writes the row, focused, pre-filled with
/// `"2026-08-16 "` and the caret sitting after the space. Type a name and press
/// Enter; or press Enter straight away and the date alone is the name, deduped
/// to `2026-08-16 2` if that day already has one.
///
/// ## Why it commits when it loses focus
///
/// There is no earlier name to fall back to — the folder is sitting under a
/// provisional timestamp until this commits — so "cancel" has no sensible
/// meaning here. Clicking away, switching tabs and pressing Escape therefore
/// all mean the same thing as pressing Enter with whatever has been typed.
/// That is also what makes it safe for transcription to wait on the name:
/// nothing can leave a recording un-named and so un-transcribed.
///
/// ## Delete
///
/// The one way out that is not a name: a recording started by accident goes to
/// the Trash before transcription ever sees it. That is why a focus loss commits
/// after a short delay rather than at once. Clicking **Delete** can take focus
/// from the field on the way, and an instant commit would start transcribing the
/// very recording being thrown away. Delete clears the pending name first, so a
/// delayed commit that lands afterwards finds nothing to name and does nothing.
struct NameRecordingBanner: View {

    let pending: RecordingSessionModel.PendingName
    let commit: (String) -> Void
    let discard: () -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    /// Long enough to cover a click on Delete (focus can leave on mouse-down,
    /// the button fires on mouse-up); short enough that switching away still
    /// names the recording before anyone notices.
    private static let blurCommitDelay: Duration = .milliseconds(600)

    var body: some View {
        NoticeBanner(
            icon: "square.and.pencil",
            tint: .accentColor,
            title: "Name this recording",
            message: "Press Return to keep just the date, or delete it if you didn't mean to record."
        ) {
            HStack(spacing: 8) {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .frame(minWidth: 220)
                    .focused($focused)
                    .onSubmit { commit(draft) }
                    // Escape is not a cancel — see the type's note. Committing what
                    // is there beats leaving a recording called "2026-08-16 14.32.07".
                    .onExitCommand { commit(draft) }
                    .onChange(of: focused) { wasFocused, isFocused in
                        guard wasFocused, !isFocused else { return }
                        let typed = draft
                        Task { @MainActor in
                            try? await Task.sleep(for: Self.blurCommitDelay)
                            // A no-op if Delete (or Return) already settled it.
                            commit(typed)
                        }
                    }

                Button("Delete", role: .destructive, action: discard)
                    .help("Move this recording to the Trash without transcribing it")
            }
        }
        .onAppear {
            draft = pending.seed
            focused = true
            placeCursorAtEnd()
        }
    }

    /// Puts the caret after the date instead of selecting the whole field.
    ///
    /// A SwiftUI `TextField` given focus programmatically selects its entire
    /// contents, so the first keystroke would *replace* `"2026-08-16 "` rather
    /// than continue it — the opposite of the intended flow. There is no
    /// SwiftUI API for this, so this reaches the window's field editor (the
    /// shared `NSTextView` AppKit hands to whichever control is editing) and
    /// collapses the selection to the end.
    ///
    /// Deferred to the next runloop turn because focus is applied during the
    /// same update: ask for the field editor now and the field does not have
    /// it yet. Best-effort — if the editor cannot be reached the field is
    /// merely select-all, which is recoverable by pressing End.
    private func placeCursorAtEnd() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            let end = editor.string.count
            editor.setSelectedRange(NSRange(location: end, length: 0))
        }
    }
}

// MARK: - Previews

// The layout only. The behaviour that actually matters here — focus landing on
// the field and the caret sitting *after* the date rather than selecting it —
// depends on a real key window, which the canvas does not give you. Check that
// part by recording something.
#if DEBUG

#Preview("Name this recording") {
    NameRecordingBanner(
        pending: .init(id: UUID(), seed: "2026-08-16 "),
        commit: { _ in },
        discard: {}
    )
    .frame(width: 560)
    .padding()
}

#endif
