import Foundation
import Testing

@testable import KVoiceCore

@Suite("Appearance mode")
struct AppearanceModeTests {

    @Test("toggling from system overrides against what the system shows now")
    func toggleFromSystem() {
        #expect(AppearanceMode.system.toggled(systemIsDark: true) == .light)
        #expect(AppearanceMode.system.toggled(systemIsDark: false) == .dark)
    }

    @Test("an explicit override toggles to the other override, whatever the system says")
    func toggleExplicit() {
        for systemIsDark in [false, true] {
            #expect(AppearanceMode.light.toggled(systemIsDark: systemIsDark) == .dark)
            #expect(AppearanceMode.dark.toggled(systemIsDark: systemIsDark) == .light)
        }
    }

    /// Toggling never lands back on `.system` — "Match System Appearance" is
    /// the deliberate way back, not a ⌘O side effect.
    @Test("toggling always produces an explicit override")
    func toggleNeverSystem() {
        for mode in AppearanceMode.allCases {
            for systemIsDark in [false, true] {
                #expect(mode.toggled(systemIsDark: systemIsDark) != .system)
            }
        }
    }

    @Test("prefersDark maps onto preferredColorScheme's three states")
    func prefersDark() {
        #expect(AppearanceMode.system.prefersDark == nil)
        #expect(AppearanceMode.light.prefersDark == false)
        #expect(AppearanceMode.dark.prefersDark == true)
    }

    /// The raw strings live in `UserDefaults`; renaming one would silently
    /// drop a user's saved override.
    @Test("modes are stable persistence strings")
    func rawValueStability() {
        #expect(AppearanceMode.system.rawValue == "system")
        #expect(AppearanceMode.light.rawValue == "light")
        #expect(AppearanceMode.dark.rawValue == "dark")
    }
}
