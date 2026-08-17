import Foundation

/// The built-in themes. Seven entries: the native look, then two each of
/// atmospheric, minimal, and vivid — every one with a matched light and dark
/// palette, because ⌘O flips a theme between its own two moods rather than
/// jumping to a different theme.
public enum ThemeCatalog {

    /// Every theme, in the order the settings grid shows them. System first:
    /// it is the default, and the card a user reaches for to get back out.
    public static let all: [ThemeSpec] = [
        system, aurora, nocturne, ink, graphite, sorbet, lagoon
    ]

    /// Lookup that cannot fail: an unknown or removed id degrades to System,
    /// never to a crash over a stale `UserDefaults` value.
    public static func spec(for id: ThemeID) -> ThemeSpec {
        all.first { $0.id == id } ?? system
    }

    // MARK: - Native

    /// Exactly today's app. `isSystem` short-circuits every token, so choosing
    /// this must be pixel-identical to a build with no theming at all. The
    /// radius scale records the app's existing de-facto values for the one
    /// consumer that still needs a number (the preview card's own corners).
    public static let system = ThemeSpec(
        id: .system,
        name: "System",
        tagline: "Native macOS, exactly as it comes",
        isSystem: true,
        radius: RadiusScale(small: 5, medium: 8, large: 10),
        shadow: .none,
        surfaceStyle: .system
    )

    // MARK: - Rich & atmospheric

    /// Glassy indigo drifting into teal — the northern-lights gradient — with
    /// an ice-blue accent and surfaces that are tinted glass over material.
    public static let aurora = ThemeSpec(
        id: .aurora,
        name: "Aurora",
        tagline: "Indigo night, ice-blue light",
        light: ThemePalette(
            backgroundStops: [
                ThemeColor(hex: 0xF4F8FE),
                ThemeColor(hex: 0xE9F1FB),
                ThemeColor(hex: 0xE6F4F6),
            ],
            surface: ThemeColor(hex: 0xFFFFFF, alpha: 0.75),
            surfaceBorder: ThemeColor(hex: 0x000000, alpha: 0.06),
            accent: ThemeColor(hex: 0x0284C7),
            secondaryText: ThemeColor(hex: 0x5B6B85)
        ),
        dark: ThemePalette(
            backgroundStops: [
                ThemeColor(hex: 0x0A0F1E),
                ThemeColor(hex: 0x101A33),
                ThemeColor(hex: 0x0F2531),
            ],
            surface: ThemeColor(hex: 0xFFFFFF, alpha: 0.07),
            surfaceBorder: ThemeColor(hex: 0xFFFFFF, alpha: 0.10),
            accent: ThemeColor(hex: 0x38BDF8),
            secondaryText: ThemeColor(hex: 0x94A7C4)
        ),
        radius: RadiusScale(small: 6, medium: 10, large: 14),
        shadow: .glow(opacity: 0.30, radius: 20),
        surfaceStyle: .glass
    )

    /// Warm charcoal-plum by candlelight, with a serif display face. The dark
    /// side is a reading lamp; the light side is cream paper.
    public static let nocturne = ThemeSpec(
        id: .nocturne,
        name: "Nocturne",
        tagline: "Candlelight on charcoal and plum",
        light: ThemePalette(
            backgroundStops: [
                ThemeColor(hex: 0xFAF7F2),
                ThemeColor(hex: 0xF4EDE4),
            ],
            surface: ThemeColor(hex: 0xFFFFFF, alpha: 0.80),
            surfaceBorder: ThemeColor(hex: 0x000000, alpha: 0.05),
            accent: ThemeColor(hex: 0xC2410C),
            secondaryText: ThemeColor(hex: 0x6E6068)
        ),
        dark: ThemePalette(
            backgroundStops: [
                ThemeColor(hex: 0x17121C),
                ThemeColor(hex: 0x211826),
                ThemeColor(hex: 0x251A22),
            ],
            surface: ThemeColor(hex: 0xFFFFFF, alpha: 0.06),
            surfaceBorder: ThemeColor(hex: 0xFFFFFF, alpha: 0.08),
            accent: ThemeColor(hex: 0xE8955C),
            secondaryText: ThemeColor(hex: 0xA99BA4)
        ),
        displayDesign: .serif,
        radius: RadiusScale(small: 6, medium: 10, large: 14),
        shadow: .soft(opacity: 0.30, radius: 14, y: 6),
        surfaceStyle: .glass
    )

    // MARK: - Minimal & precise

    /// Monochrome with one shot of vermilion. No shadows anywhere — edges are
    /// hairlines, corners are barely rounded, and the single color has to
    /// carry everything. It does.
    public static let ink = ThemeSpec(
        id: .ink,
        name: "Ink",
        tagline: "Monochrome, one drop of vermilion",
        light: ThemePalette(
            backgroundStops: [ThemeColor(hex: 0xFCFCFB)],
            surface: ThemeColor(hex: 0xF3F3F1),
            surfaceBorder: ThemeColor(hex: 0xE4E4E1),
            accent: ThemeColor(hex: 0xD93025),
            secondaryText: ThemeColor(hex: 0x6B6B68)
        ),
        dark: ThemePalette(
            backgroundStops: [ThemeColor(hex: 0x111110)],
            surface: ThemeColor(hex: 0x1B1B1A),
            surfaceBorder: ThemeColor(hex: 0x2A2A28),
            accent: ThemeColor(hex: 0xFF6A55),
            secondaryText: ThemeColor(hex: 0x9C9C97)
        ),
        radius: RadiusScale(small: 2, medium: 4, large: 6),
        shadow: .none,
        surfaceStyle: .flat
    )

    /// Cool engineering gray with an azure accent and a monospaced display
    /// face — the record clock becomes a terminal readout.
    public static let graphite = ThemeSpec(
        id: .graphite,
        name: "Graphite",
        tagline: "Cool gray, azure, monospace",
        light: ThemePalette(
            backgroundStops: [ThemeColor(hex: 0xF6F7F9)],
            surface: ThemeColor(hex: 0xFFFFFF),
            surfaceBorder: ThemeColor(hex: 0xE1E5EA),
            accent: ThemeColor(hex: 0x0B6BCB),
            secondaryText: ThemeColor(hex: 0x64707E)
        ),
        dark: ThemePalette(
            backgroundStops: [ThemeColor(hex: 0x14171C)],
            surface: ThemeColor(hex: 0x1D2229),
            surfaceBorder: ThemeColor(hex: 0x2C333D),
            accent: ThemeColor(hex: 0x4C9EFF),
            secondaryText: ThemeColor(hex: 0x8C97A5)
        ),
        displayDesign: .monospaced,
        radius: RadiusScale(small: 3, medium: 6, large: 8),
        shadow: .none,
        surfaceStyle: .flat
    )

    // MARK: - Vivid & playful

    /// Peach melting into blush, everything rounded, the accent a raspberry
    /// glow. The dark side goes berry rather than gray so it stays warm.
    public static let sorbet = ThemeSpec(
        id: .sorbet,
        name: "Sorbet",
        tagline: "Peach and blush, served rounded",
        light: ThemePalette(
            backgroundStops: [
                ThemeColor(hex: 0xFFF6EE),
                ThemeColor(hex: 0xFFE9E4),
                ThemeColor(hex: 0xFFE4EF),
            ],
            surface: ThemeColor(hex: 0xFFFFFF, alpha: 0.85),
            surfaceBorder: ThemeColor(hex: 0xFFD4C9),
            accent: ThemeColor(hex: 0xFF4E64),
            secondaryText: ThemeColor(hex: 0x96757C)
        ),
        dark: ThemePalette(
            backgroundStops: [
                ThemeColor(hex: 0x221325),
                ThemeColor(hex: 0x2B1721),
                ThemeColor(hex: 0x301A1C),
            ],
            surface: ThemeColor(hex: 0xFFFFFF, alpha: 0.07),
            accent: ThemeColor(hex: 0xFF7B8E),
            secondaryText: ThemeColor(hex: 0xC4A3AC)
        ),
        bodyDesign: .rounded,
        displayDesign: .rounded,
        radius: RadiusScale(small: 8, medium: 14, large: 18),
        shadow: .glow(opacity: 0.25, radius: 16),
        surfaceStyle: .flat
    )

    /// Electric teal over deep water — mint-bright in the light, deep-sea in
    /// the dark, rounded like Sorbet but cold where Sorbet is warm.
    public static let lagoon = ThemeSpec(
        id: .lagoon,
        name: "Lagoon",
        tagline: "Electric teal over deep water",
        light: ThemePalette(
            backgroundStops: [
                ThemeColor(hex: 0xECFDF6),
                ThemeColor(hex: 0xDFF7F0),
                ThemeColor(hex: 0xDDF3F9),
            ],
            surface: ThemeColor(hex: 0xFFFFFF, alpha: 0.85),
            surfaceBorder: ThemeColor(hex: 0xBFE8DD),
            accent: ThemeColor(hex: 0x0E9384),
            secondaryText: ThemeColor(hex: 0x4F7A72)
        ),
        dark: ThemePalette(
            backgroundStops: [
                ThemeColor(hex: 0x05201F),
                ThemeColor(hex: 0x0A3436),
                ThemeColor(hex: 0x063540),
            ],
            surface: ThemeColor(hex: 0xFFFFFF, alpha: 0.07),
            accent: ThemeColor(hex: 0x2DD4BF),
            secondaryText: ThemeColor(hex: 0x86B5AE)
        ),
        bodyDesign: .rounded,
        displayDesign: .rounded,
        radius: RadiusScale(small: 8, medium: 14, large: 18),
        shadow: .glow(opacity: 0.25, radius: 16),
        surfaceStyle: .flat
    )
}
