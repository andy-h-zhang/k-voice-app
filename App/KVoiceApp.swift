import AppKit
import SwiftUI

/// KVoice — a meeting recorder with speaker-aware transcription.
///
/// The app is a thin shell: `KVoiceCore` owns recording, transcription,
/// speaker identification, storage, and persistence, and everything here
/// observes it. ``AppServices`` is built once at launch and reaches the views
/// through the environment.
@main
struct KVoiceApp: App {

    /// Only for the quit guard (spec §Core pipeline 1: a confirm dialog must
    /// stand between a running recording and termination).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var bootstrap = AppBootstrap.make()

    var body: some Scene {
        WindowGroup {
            // One size report for the whole window, identical for every
            // sidebar section.
            //
            // The window follows what the root view reports, and before this
            // that was whatever the current section happened to compute.
            // Measured on a clean profile, the detail column alone drove the
            // window to 960×1292 — a 1292-point-tall window on a 949-point
            // screen — while an empty detail column gave exactly the 960×640
            // `defaultSize`. That is the whole bug: the *content* was sizing
            // the window, so every section switch re-sized it, and the number
            // it landed on was nonsense. (The user's saved frame had reached
            // "736 -1767 960 3177".)
            //
            // Flexible in both axes fixes it by making the report constant:
            // whatever section is showing, the root says "any size from
            // 720×480 upward", so switching sections changes nothing and
            // nothing but the user moves the window. Verified by seeding
            // frames and reading back the real geometry: 320×200 clamps up to
            // exactly 720×532 (480 content + chrome), 5000×4000 fills the
            // display, and 1240×820 survives a relaunch.
            //
            // Nothing else may go around `content`: SwiftUI derives this
            // window's frame-autosave key from the root view's *type name*, so
            // any wrapper that is a private type (or otherwise unnameable)
            // mangles a runtime address into the key, and every launch then
            // reads a key the last launch never wrote — the window comes back
            // at `defaultSize` and the fix looks like the bug it was meant to
            // repair. An earlier draft of this file did exactly that.
            content
                .frame(
                    minWidth: 720,
                    idealWidth: 960,
                    maxWidth: .infinity,
                    minHeight: 480,
                    idealHeight: 640,
                    maxHeight: .infinity
                )
        }
        // Only ever a first-launch fallback: once a frame has been saved, that
        // wins. A window opening on a display too small for the size it asks
        // for is filled to that display by AppKit, which is macOS's call, not
        // this app's.
        .defaultSize(width: 960, height: 640)
        // Floor from the content, no ceiling at all. The default `.automatic`
        // also lets content impose a *maximum*, which is the other half of how
        // a section can shrink the window it is shown in.
        .windowResizability(.contentMinSize)
        .commands {
            // Settings is a tab in the main window now, not a `Settings` scene,
            // so ⌘, and the app menu's "Settings…" have to be given something to
            // do — without this they would keep opening a window that no longer
            // exists, or nothing at all.
            //
            // `openWindow` first, because the user may have closed the window
            // with ⌘W: setting a route on a window that is not on screen is a
            // silent no-op, and it is the one path that never comes up in
            // ordinary testing.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(services == nil)
            }

            // Replaces New/Open — KVoice has no documents to open — with the
            // two places its files actually live. The File menu is where a Mac
            // user looks for "where is this saved", and it works from any
            // section, including the record screen.
            CommandGroup(replacing: .newItem) {
                // One item, not two. There is no transcripts folder to open
                // any more — every transcript sits in its recording's own
                // folder, so the library root is the only place to point at.
                Button("Show Recordings in Finder") {
                    guard let libraryRoot else { return }
                    FinderIntegration.open(libraryRoot)
                }
                .disabled(libraryRoot == nil)
            }

            // Navigation lives in a menu rather than on the views it moves to,
            // and that is the point: a `.keyboardShortcut` on a button only
            // fires while that button is on screen, so "go to the Vocab tab"
            // hung off the Vocab tab would only work once you were already
            // there. Menu commands are window-wide.
            //
            // ⌘R is here for the same reason and one more: stopping a
            // recording has to work from wherever you drifted to while it ran.
            CommandMenu("Go") {
                if let services {
                    GoMenu(services: services)
                }
            }

            // Appearance lives in the View menu, and it is a menu command for
            // the same reason the Go items are: ⌘O has to work from any tab,
            // and a shortcut on a view only fires while that view is showing.
            CommandGroup(before: .toolbar) {
                if let services {
                    ThemeCommands(services: services)
                    Divider()
                }
            }
        }

        // There is deliberately no `Settings` scene. Settings is the third tab
        // in the main window: the API key gates transcription entirely, and the
        // input device and matching threshold are things you change while
        // looking at what they affect — none of which is well served by a
        // separate window you have to dismiss to get back to your work.
    }

    /// The live services, when the app got off the ground.
    private var services: AppServices? {
        if case .ready(let services) = bootstrap { return services }
        return nil
    }

    /// Selects the Settings tab and brings a window forward to show it in.
    ///
    /// The route is set whether or not a window is on screen: `NavigationModel`
    /// lives in ``AppServices`` and outlives every window, so a user who has
    /// closed the window with ⌘W and reopens it from the Dock still lands where
    /// they asked to go.
    private func showSettings() {
        guard let services else { return }
        services.navigation.select(.settings)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    @ViewBuilder
    private var content: some View {
        switch bootstrap {
        case .ready(let services):
            RootView()
                .environment(services)
        case .failed(let message, let path):
            BootstrapFailureView(message: message, path: path)
        }
    }

    /// The library root, when there is one.
    ///
    /// A failed bootstrap still knows the path it could not open, and that is
    /// exactly the moment someone wants Finder pointed at it.
    private var libraryRoot: URL? {
        switch bootstrap {
        case .ready(let services): return services.libraryRoot
        case .failed(_, let path): return URL(fileURLWithPath: path)
        }
    }
}

// MARK: - Window frame persistence
//
// There is deliberately no code here.
//
// SwiftUI already gives a `WindowGroup`'s window an `NSWindow` frame-autosave
// name, so the size and position a user chooses are written to `UserDefaults`
// on every resize and restored on the next launch — for free. What it does not
// do is make that name stable: it is derived from the root view's *type name*,
// so wrapping the root in a private helper (an `NSViewRepresentable` that sets
// its own autosave name, say) mangles an unnameable context — including a
// runtime address — into the key, and every launch then reads a key the last
// launch never wrote. The window comes back at `defaultSize` and the fix looks
// like the bug it was meant to repair.
//
// An earlier draft of this file did exactly that. What it left behind on disk
// is worth recording:
//
//     "NSWindow Frame …KVoice.RootView…-1-AppWindow-1" = "736 -1767 960 3177"
//
// A 3177-point-tall window at y = -1767 — the ideal-size runaway that made
// resizing feel "very restricted", saved faithfully by a mechanism that was
// working correctly on wrong input. That key is now orphaned: the root view's
// type changed when the frame modifier above was added, so the poisoned frame
// is simply never read again, and existing installs come back at
// `defaultSize` once and then persist whatever the user picks.
