import Foundation

/// An sRGB color as plain numbers, because `KVoiceCore` links neither AppKit
/// nor SwiftUI. The app layer turns one of these into a `Color`; the tests can
/// check its components without a display in sight.
public struct ThemeColor: Sendable, Equatable {

    /// Components in 0…1.
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    /// `0xRRGGBB`, the form the catalog is written in — a palette is easier to
    /// review against a design when it reads like one.
    public init(hex: UInt32, alpha: Double = 1) {
        self.red = Double((hex >> 16) & 0xFF) / 255
        self.green = Double((hex >> 8) & 0xFF) / 255
        self.blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }
}

/// One appearance's worth of a theme — every theme carries two of these, and
/// ⌘O is a swap between them.
public struct ThemePalette: Sendable, Equatable {

    /// Window background. One stop is a flat color; two or three are a
    /// gradient from top-leading to bottom-trailing.
    public var backgroundStops: [ThemeColor]

    /// Fill for raised things: banners, cards, chips.
    public var surface: ThemeColor

    /// Hairline around a surface, for themes that draw edges instead of
    /// casting shadows. Nil means no border.
    public var surfaceBorder: ThemeColor?

    /// The tint — buttons, selection, links, the in-flight status color.
    public var accent: ThemeColor

    /// De-emphasized text *on themed surfaces* (the preview cards, mainly).
    /// Ordinary body text keeps SwiftUI's `.secondary`, which already adapts.
    public var secondaryText: ThemeColor

    public init(
        backgroundStops: [ThemeColor],
        surface: ThemeColor,
        surfaceBorder: ThemeColor? = nil,
        accent: ThemeColor,
        secondaryText: ThemeColor
    ) {
        self.backgroundStops = backgroundStops
        self.surface = surface
        self.surfaceBorder = surfaceBorder
        self.accent = accent
        self.secondaryText = secondaryText
    }
}

/// A system font *design*, by name. The app maps these onto `Font.Design`;
/// keeping the enum here lets the catalog state "Nocturne's clock is serif"
/// where the rest of the theme is stated, and keeps bundled font files out of
/// the picture entirely.
public enum FontDesignSpec: String, Sendable, Equatable {
    case standard
    case rounded
    case serif
    case monospaced
}

/// Corner radii, smallest to largest. A theme's shape language in three
/// numbers: Ink is 2/4/6 and reads sharp, Sorbet is 8/14/18 and reads soft.
public struct RadiusScale: Sendable, Equatable {
    public var small: Double
    public var medium: Double
    public var large: Double

    public init(small: Double, medium: Double, large: Double) {
        self.small = small
        self.medium = medium
        self.large = large
    }
}

/// How a theme lifts a surface off the background.
public enum ShadowSpec: Sendable, Equatable {
    /// Flat — the minimal themes draw a hairline border instead.
    case none
    /// A neutral drop shadow.
    case soft(opacity: Double, radius: Double, y: Double)
    /// An accent-colored bloom, for the atmospheric and vivid themes.
    case glow(opacity: Double, radius: Double)
}

/// What a surface is made of.
public enum SurfaceStyle: String, Sendable, Equatable {
    /// Whatever the system would do — the System theme only.
    case system
    /// A plain fill in the palette's surface color.
    case flat
    /// The surface color over a translucent material.
    case glass
}

/// Stable identities for the built-in themes. Raw strings are the persistence
/// contract: they go into `UserDefaults` and must never be renamed.
public enum ThemeID: String, CaseIterable, Sendable {
    case system
    case aurora
    case nocturne
    case ink
    case graphite
    case sorbet
    case lagoon
}

/// Everything a theme is: identity, both palettes, and its shape, type, and
/// shadow language. Pure data — the SwiftUI mapping lives in the app target.
public struct ThemeSpec: Sendable, Equatable, Identifiable {

    public let id: ThemeID
    public let name: String

    /// One line of mood, shown on the theme's preview card.
    public let tagline: String

    /// True only for the System theme: every token is a no-op and the app
    /// looks exactly as it does with no theming at all.
    public let isSystem: Bool

    /// Nil only when `isSystem` — the native look has no palette to state.
    public let light: ThemePalette?
    public let dark: ThemePalette?

    /// Design for ordinary text app-wide.
    public let bodyDesign: FontDesignSpec

    /// Design for display moments — the record clock, the card sample.
    public let displayDesign: FontDesignSpec

    public let radius: RadiusScale
    public let shadow: ShadowSpec
    public let surfaceStyle: SurfaceStyle

    public init(
        id: ThemeID,
        name: String,
        tagline: String,
        isSystem: Bool = false,
        light: ThemePalette? = nil,
        dark: ThemePalette? = nil,
        bodyDesign: FontDesignSpec = .standard,
        displayDesign: FontDesignSpec = .standard,
        radius: RadiusScale,
        shadow: ShadowSpec = .none,
        surfaceStyle: SurfaceStyle = .flat
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.isSystem = isSystem
        self.light = light
        self.dark = dark
        self.bodyDesign = bodyDesign
        self.displayDesign = displayDesign
        self.radius = radius
        self.shadow = shadow
        self.surfaceStyle = surfaceStyle
    }

    /// The palette for one appearance. `isSystem` has none, by design.
    public func palette(dark isDark: Bool) -> ThemePalette? {
        isDark ? dark : light
    }
}
