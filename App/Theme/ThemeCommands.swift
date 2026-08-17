import KVoiceCore
import SwiftUI

/// The View-menu appearance commands: ⌘O to flip light/dark, and the way back
/// to following macOS.
///
/// A menu rather than a shortcut on a view for the reason documented in
/// ``GoMenu``: a `.keyboardShortcut` only fires while its view is on screen,
/// and toggling the appearance has to work from anywhere. Same pattern too —
/// a `View` handed `services`, so `@Observable` tracking re-titles the item
/// as the mode changes.
struct ThemeCommands: View {

    let services: AppServices

    var body: some View {
        Button(services.theme.menuTitle) {
            services.theme.toggleAppearance()
        }
        .keyboardShortcut("o", modifiers: .command)

        Button("Match System Appearance") {
            services.theme.setAppearanceMode(.system)
        }
        .disabled(services.theme.appearanceMode == .system)
    }
}
