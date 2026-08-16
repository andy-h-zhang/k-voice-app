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
struct NameRecordingBanner: View {

    let pending: RecordingSessionModel.PendingName
    let commit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NoticeBanner(
            icon: "square.and.pencil",
            tint: .accentColor,
            title: "Name this recording",
            message: "Press Return to keep just the date."
        ) {
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
                    if wasFocused, !isFocused { commit(draft) }
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
        pending: .init(id: UUID(), seed: "2026-08-16 ")
    ) { _ in }
    .frame(width: 560)
    .padding()
}

#endif
