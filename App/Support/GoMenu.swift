import AppKit
import SwiftUI

/// The **Go** menu: start or stop a recording, and jump to any tab or recent
/// recording without reaching for the mouse.
///
/// ## Why a menu and not shortcuts on the views
///
/// A `.keyboardShortcut` is only live while the view carrying it is on screen.
/// That is fine for ⌘⇧C in the transcript editor, and useless for navigation:
/// "go to People" attached to the People tab would only work once you were
/// already in People. Menu commands belong to the window, so they work from
/// anywhere — and they are also discoverable, which a bare key binding is not.
///
/// ⌘R is here for that reason plus one more: a recording started on the Record
/// tab keeps running while you read a transcript, and stopping it has to work
/// from wherever you ended up.
struct GoMenu: View {

    let services: AppServices

    /// How many recordings get a numbered shortcut before ⌃9 takes over.
    private static let numberedRecordings = 8

    var body: some View {
        Button(services.recorder.isActive ? "Stop Recording" : "Start Recording") {
            toggleRecording()
        }
        .keyboardShortcut("r", modifiers: .command)
        // Mid-transition the answer to "should this start or stop?" is neither.
        .disabled(services.recorder.phase == .starting || services.recorder.phase == .saving)

        Divider()

        // Numbered by position, so the digits always match the order of the
        // tabs on screen. Inserting a tab renumbers everything after it, which
        // is the behaviour that stays learnable — the alternative is a fixed
        // number per tab and a bar whose digits run 1, 4, 2, 3.
        ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { index, tab in
            Button(tab.title) { go(to: tab) }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        }

        Divider()

        recordingItems
    }

    // MARK: - Recordings

    /// ⌃1…⌃8 by recency, ⌃9 for the oldest.
    ///
    /// The rows are newest-first already (`LibraryModel.reload`), so position
    /// *is* recency and no second sort is needed.
    ///
    /// ⌃9 is the oldest rather than the ninth, which means that in a library of
    /// fewer than ten it points at the same recording as one of the numbered
    /// items. That overlap is deliberate: "the bottom of the list" is a place
    /// people navigate to, and it should not silently become "nothing happens"
    /// just because the list is short.
    @ViewBuilder
    private var recordingItems: some View {
        let rows = services.library.rows

        if rows.isEmpty {
            Button("No Recordings Yet") {}
                .disabled(true)
        } else {
            ForEach(Array(rows.prefix(Self.numberedRecordings).enumerated()), id: \.element.id) {
                index, row in
                Button(row.title) { services.navigation.openRecording(row.id) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")),
                        modifiers: .control
                    )
            }

            if let oldest = rows.last {
                Divider()
                Button("Oldest — \(oldest.title)") {
                    services.navigation.openRecording(oldest.id)
                }
                .keyboardShortcut("9", modifiers: .control)
            }
        }
    }

    // MARK: - Actions

    private func go(to tab: AppTab) {
        services.navigation.select(tab)
        // The window may have been closed with ⌘W while the app stayed running;
        // setting a route on nothing is a silent no-op, and it is the path that
        // never comes up in ordinary testing. Same guard as "Settings…".
        bringWindowForward()
    }

    private func toggleRecording() {
        let recorder = services.recorder
        Task {
            if recorder.isActive {
                await recorder.stop()
                // Stopping leaves a name to type, and the field for it is on
                // the Record tab. Sending the user there is the difference
                // between ⌘R-from-anywhere working and it quietly parking a
                // recording under a timestamp.
                services.navigation.select(.record)
            } else {
                services.navigation.select(.record)
                await recorder.start()
            }
            bringWindowForward()
        }
    }

    private func bringWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
