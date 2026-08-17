import Foundation
import Testing

@testable import KVoiceCore

@Suite("Theme catalog")
struct ThemeCatalogTests {

    @Test("the catalog covers every ThemeID exactly once, System first")
    func coverage() {
        #expect(ThemeCatalog.all.count == ThemeID.allCases.count)
        #expect(Set(ThemeCatalog.all.map(\.id)).count == ThemeCatalog.all.count)
        #expect(ThemeCatalog.all.first?.id == .system)
    }

    @Test("System is the only theme that claims to be the native look")
    func onlyOneSystem() {
        #expect(ThemeCatalog.all.filter(\.isSystem).map(\.id) == [.system])
        #expect(ThemeCatalog.system.light == nil)
        #expect(ThemeCatalog.system.dark == nil)
        #expect(ThemeCatalog.system.surfaceStyle == .system)
    }

    @Test("every custom theme carries both palettes — ⌘O needs somewhere to land")
    func pairedVariants() {
        for spec in ThemeCatalog.all where !spec.isSystem {
            for isDark in [false, true] {
                let palette = spec.palette(dark: isDark)
                #expect(palette != nil, "\(spec.id) missing \(isDark ? "dark" : "light") palette")
                let stops = palette?.backgroundStops.count ?? 0
                #expect((1...3).contains(stops), "\(spec.id): \(stops) background stops")
            }
        }
    }

    @Test("every color component is a displayable 0…1 value")
    func colorComponents() {
        for spec in ThemeCatalog.all {
            for palette in [spec.light, spec.dark].compactMap({ $0 }) {
                var colors = palette.backgroundStops
                colors.append(contentsOf: [palette.surface, palette.accent, palette.secondaryText])
                if let border = palette.surfaceBorder { colors.append(border) }
                for color in colors {
                    for component in [color.red, color.green, color.blue, color.alpha] {
                        #expect((0.0...1.0).contains(component), "\(spec.id) out of range")
                    }
                }
            }
        }
    }

    @Test("radius scales are positive and ordered")
    func radiusScales() {
        for spec in ThemeCatalog.all {
            #expect(spec.radius.small > 0)
            #expect(spec.radius.small <= spec.radius.medium)
            #expect(spec.radius.medium <= spec.radius.large)
        }
    }

    @Test("lookup by id round-trips, and never fails")
    func lookup() {
        for id in ThemeID.allCases {
            #expect(ThemeCatalog.spec(for: id).id == id)
        }
    }

    @Test("hex colors decode the channels in RRGGBB order")
    func hexDecoding() {
        let color = ThemeColor(hex: 0x38BDF8)
        #expect(abs(color.red - 0x38 / 255.0) < 1e-9)
        #expect(abs(color.green - 0xBD / 255.0) < 1e-9)
        #expect(abs(color.blue - 0xF8 / 255.0) < 1e-9)
        #expect(color.alpha == 1)
        #expect(ThemeColor(hex: 0xFFFFFF, alpha: 0.07).alpha == 0.07)
    }

    /// The raw strings are what `UserDefaults` holds; renaming a case would
    /// silently reset every user of that theme to System.
    @Test("theme ids are stable persistence strings")
    func rawValueStability() {
        #expect(ThemeID.system.rawValue == "system")
        #expect(ThemeID.aurora.rawValue == "aurora")
        #expect(ThemeID.nocturne.rawValue == "nocturne")
        #expect(ThemeID.ink.rawValue == "ink")
        #expect(ThemeID.graphite.rawValue == "graphite")
        #expect(ThemeID.sorbet.rawValue == "sorbet")
        #expect(ThemeID.lagoon.rawValue == "lagoon")
    }
}
