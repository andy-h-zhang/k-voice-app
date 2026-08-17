import Foundation

/// Whether the app follows macOS's appearance or overrides it. Raw strings are
/// the persistence contract — they go into `UserDefaults` and must not change.
public enum AppearanceMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// ⌘O. The result is always an explicit override, opposite to whatever is
    /// on screen *right now* — which is why `.system` needs to be told what
    /// the system currently shows. Toggling never lands back on `.system`;
    /// the menu's "Match System Appearance" is the way back.
    public func toggled(systemIsDark: Bool) -> AppearanceMode {
        switch self {
        case .system: return systemIsDark ? .light : .dark
        case .light: return .dark
        case .dark: return .light
        }
    }

    /// What to hand `preferredColorScheme`: nil means "don't override".
    public var prefersDark: Bool? {
        switch self {
        case .system: return nil
        case .light: return false
        case .dark: return true
        }
    }
}
