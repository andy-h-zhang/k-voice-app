import KVoiceCore
import SwiftUI

// MARK: - Core → SwiftUI adapters

extension Color {
    /// `KVoiceCore` describes colors as plain sRGB numbers so its catalog can
    /// be tested without AppKit; this is where they become drawable.
    init(_ color: ThemeColor) {
        self.init(
            .sRGB,
            red: color.red,
            green: color.green,
            blue: color.blue,
            opacity: color.alpha
        )
    }
}

extension Font.Design {
    init(_ spec: FontDesignSpec) {
        switch spec {
        case .standard: self = .default
        case .rounded: self = .rounded
        case .serif: self = .serif
        case .monospaced: self = .monospaced
        }
    }
}

// MARK: - Resolved theme

/// A theme, resolved for the color scheme the window is actually showing —
/// the palette question ("light or dark?") is already answered, so views
/// consume tokens without caring about the mode.
///
/// Reaches views through `@Environment(\.theme)`. The default is
/// ``ResolvedTheme/system``, so a preview or a view outside the themed tree
/// renders natively rather than crashing on a missing key.
struct ResolvedTheme {

    let spec: ThemeSpec
    private let palette: ThemePalette?

    init(spec: ThemeSpec, colorScheme: ColorScheme) {
        self.spec = spec
        self.palette = spec.palette(dark: colorScheme == .dark)
    }

    /// The native look — also what any custom theme degrades to if its
    /// palette is missing, which the catalog tests forbid but the render
    /// path still has to survive.
    static let system = ResolvedTheme(spec: ThemeCatalog.system, colorScheme: .light)

    /// True when every token should be a no-op and the app must look exactly
    /// as it does with no theming at all.
    var isSystem: Bool { spec.isSystem || palette == nil }

    var radius: RadiusScale { spec.radius }
    var bodyDesign: Font.Design { Font.Design(spec.bodyDesign) }
    var displayDesign: Font.Design { Font.Design(spec.displayDesign) }

    /// The window background. Flat palettes still come through here — a
    /// one-stop gradient draws as a solid — so callers have one code path.
    var background: LinearGradient {
        let stops = palette?.backgroundStops.map(Color.init) ?? [.clear]
        return LinearGradient(
            colors: stops.count == 1 ? [stops[0], stops[0]] : stops,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var accent: Color? { palette.map { Color($0.accent) } }
    var surfaceBorder: Color? { palette?.surfaceBorder.map(Color.init) }
    var secondaryText: Color? { palette.map { Color($0.secondaryText) } }

    /// Fill for banners, cards, and chips. Glass themes composite their tint
    /// over material; the System theme keeps today's `.quinary`.
    var surface: AnyShapeStyle {
        guard let palette, !spec.isSystem else { return AnyShapeStyle(.quinary) }
        switch spec.surfaceStyle {
        case .system: return AnyShapeStyle(.quinary)
        case .flat: return AnyShapeStyle(Color(palette.surface))
        case .glass: return AnyShapeStyle(.ultraThinMaterial)
        }
    }

    /// Glass themes tint their material with this wash, drawn over `surface`.
    var surfaceTint: Color? {
        guard let palette, spec.surfaceStyle == .glass else { return nil }
        return Color(palette.surface)
    }
}

// MARK: - Shadow application

extension View {
    /// Applies a theme's shadow spec — none, a neutral drop, or an
    /// accent-colored glow.
    @ViewBuilder
    func themeShadow(_ theme: ResolvedTheme) -> some View {
        switch theme.spec.shadow {
        case .none:
            self
        case .soft(let opacity, let radius, let y):
            shadow(color: .black.opacity(theme.isSystem ? 0 : opacity), radius: radius, y: y)
        case .glow(let opacity, let radius):
            shadow(
                color: (theme.accent ?? .clear).opacity(theme.isSystem ? 0 : opacity),
                radius: radius
            )
        }
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ResolvedTheme.system
}

extension EnvironmentValues {
    var theme: ResolvedTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
