import KVoiceCore
import SwiftUI

extension View {
    /// Applies the current theme to a whole view tree: the light/dark
    /// override, the accent tint, the body font design, and the resolved
    /// token set in `\.theme`.
    ///
    /// Goes on the `NavigationSplitView` inside `RootView.body` — never
    /// around the `WindowGroup`'s root content, where a new wrapping type
    /// would change the window's frame-autosave key (see the comment at the
    /// bottom of `KVoiceApp.swift`). `preferredColorScheme` is a preference
    /// and propagates up to the window from here just fine.
    func themed(_ manager: ThemeManager) -> some View {
        modifier(ThemeApplication(manager: manager))
    }
}

private struct ThemeApplication: ViewModifier {

    let manager: ThemeManager

    func body(content: Content) -> some View {
        let spec = manager.spec
        content
            .modifier(ThemeResolution(spec: spec))
            .tint(spec.isSystem ? nil : tintColor(for: spec))
            .fontDesign(spec.bodyDesign == .standard ? nil : Font.Design(spec.bodyDesign))
            .preferredColorScheme(
                manager.appearanceMode.prefersDark.map { $0 ? .dark : .light }
            )
    }

    /// The tint has to be picked *outside* the resolved environment — it is
    /// applied at the same level the resolution happens — so it reads the
    /// override directly and falls back to the system's current appearance.
    private func tintColor(for spec: ThemeSpec) -> Color? {
        let isDark = manager.appearanceMode.prefersDark ?? ThemeManager.systemIsDark
        return spec.palette(dark: isDark).map { Color($0.accent) }
    }
}

/// The inner layer: reads the color scheme *after* `preferredColorScheme`
/// has had its say, resolves the palette for it, and publishes the result.
/// Split from ``ThemeApplication`` because the resolution must see the
/// post-override scheme, and a view cannot read an environment value it is
/// itself in the middle of changing.
private struct ThemeResolution: ViewModifier {

    let spec: ThemeSpec
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.environment(\.theme, ResolvedTheme(spec: spec, colorScheme: colorScheme))
    }
}

/// The theme's window background, or nothing at all on the System theme —
/// leaving whatever the system would have drawn.
///
/// A view rather than an inline expression because the resolved theme is only
/// in the environment *inside* the tree `themed(_:)` wraps; anything placed
/// with `.background { }` there can read it, the wrapping view itself cannot.
struct ThemeBackground: View {

    @Environment(\.theme) private var theme

    /// Extra darkening (or lightening, in light palettes it reads as a wash)
    /// so adjacent panes — the sidebar, mainly — stay distinguishable from
    /// the detail column they sit beside.
    var dimmed = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !theme.isSystem {
            ZStack {
                theme.background
                if dimmed {
                    (colorScheme == .dark
                        ? Color.black.opacity(0.18)
                        : Color.black.opacity(0.04))
                }
            }
            .ignoresSafeArea()
        }
    }
}
