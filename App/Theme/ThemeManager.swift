import AppKit
import KVoiceCore
import Observation

/// The app's one handle on "which theme, and which of its two moods".
///
/// Follows the mirrored-settings pattern documented in ``AppSettingsModel``:
/// `SettingsStore` is not `@Observable`, so a control bound straight through
/// to it would write correctly and never redraw. Both values are mirrored
/// here and every write goes through a setter that updates both.
@MainActor
@Observable
final class ThemeManager {

    private(set) var themeID: ThemeID
    private(set) var appearanceMode: AppearanceMode

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        self.themeID = settings.themeID
        self.appearanceMode = settings.appearanceMode
    }

    /// The current theme's full spec.
    var spec: ThemeSpec { ThemeCatalog.spec(for: themeID) }

    func setTheme(_ id: ThemeID) {
        settings.themeID = id
        themeID = settings.themeID
    }

    func setAppearanceMode(_ mode: AppearanceMode) {
        settings.appearanceMode = mode
        appearanceMode = settings.appearanceMode
    }

    /// ⌘O. Lands on an explicit override opposite to what is on screen now;
    /// the menu's "Match System Appearance" is the way back to following macOS.
    func toggleAppearance() {
        setAppearanceMode(appearanceMode.toggled(systemIsDark: Self.systemIsDark))
    }

    /// What macOS itself is showing, independent of this app's override.
    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Menu title for the toggle, naming where it will take you.
    var menuTitle: String {
        let isDarkNow = appearanceMode.prefersDark ?? Self.systemIsDark
        return isDarkNow ? "Switch to Light Appearance" : "Switch to Dark Appearance"
    }
}
