import KVoiceCore
import SwiftUI

/// The Appearance section of Settings: a light/dark/system control and a grid
/// of theme cards, each one painted with the theme's own tokens.
///
/// The cards render for the appearance currently in force, so ⌘O flips the
/// whole gallery between its light and dark faces at once — the gallery *is*
/// the preview.
struct AppearanceSection: View {

    @Environment(AppServices.self) private var services
    @Environment(\.colorScheme) private var colorScheme

    private var mode: Binding<AppearanceMode> {
        Binding(
            get: { services.theme.appearanceMode },
            set: { services.theme.setAppearanceMode($0) }
        )
    }

    var body: some View {
        Section {
            Picker("Appearance", selection: mode) {
                Text("System").tag(AppearanceMode.system)
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
            }
            .pickerStyle(.segmented)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                spacing: 12
            ) {
                ForEach(ThemeCatalog.all) { spec in
                    ThemePreviewCard(
                        spec: spec,
                        isDark: colorScheme == .dark,
                        isSelected: services.theme.themeID == spec.id
                    ) {
                        services.theme.setTheme(spec.id)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Appearance")
        } footer: {
            Text(
                """
                Every theme has a light and a dark face — ⌘O flips between them from \
                anywhere. System follows macOS until you toggle; “Match System Appearance” \
                in the View menu goes back to following it.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview card

/// One theme, painted in its own tokens: its background, its surface, its
/// accent, its display face, its corner radii. A card has to *be* a swatch of
/// the theme, not a description of one.
private struct ThemePreviewCard: View {

    let spec: ThemeSpec
    let isDark: Bool
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovering = false

    private var palette: ThemePalette? { spec.palette(dark: isDark) }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                swatch
                caption
            }
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: spec.radius.large))
            .overlay {
                RoundedRectangle(cornerRadius: spec.radius.large)
                    .strokeBorder(
                        isSelected ? accent : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, accent)
                        .padding(6)
                }
            }
            .scaleEffect(isHovering ? 1.02 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovering)
            .contentShape(RoundedRectangle(cornerRadius: spec.radius.large))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(spec.tagline)
        .accessibilityLabel("\(spec.name) theme\(isSelected ? ", selected" : "")")
    }

    /// The upper two-thirds: the theme's background with a miniature of the
    /// app on it — a surface chip and an accent "button".
    private var swatch: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Aa")
                    .font(.system(.title2, design: Font.Design(spec.displayDesign)))
                    .fontWeight(.medium)
                    .foregroundStyle(primaryText)
                Spacer()
                Circle()
                    .fill(accent)
                    .frame(width: 10, height: 10)
            }

            Spacer(minLength: 2)

            RoundedRectangle(cornerRadius: spec.radius.small)
                .fill(surface)
                .frame(height: 14)
                .overlay {
                    if let border = palette?.surfaceBorder {
                        RoundedRectangle(cornerRadius: spec.radius.small)
                            .strokeBorder(Color(border))
                    }
                }

            Capsule()
                .fill(accent)
                .frame(width: 44, height: 10)
        }
        .padding(10)
        .frame(height: 84)
    }

    /// The lower band: name and tagline on the theme's surface color, so the
    /// text sits on the theme rather than on the settings form.
    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(spec.name)
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(primaryText)
            Text(spec.tagline)
                .font(.caption)
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface)
    }

    // MARK: - Token fallbacks

    // The System card has no palette of its own — it borrows native styles,
    // which is exactly the point: it previews the absence of a theme.

    @ViewBuilder
    private var cardBackground: some View {
        if let palette {
            LinearGradient(
                colors: palette.backgroundStops.map(Color.init),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    private var accent: Color {
        palette.map { Color($0.accent) } ?? .accentColor
    }

    private var surface: AnyShapeStyle {
        palette.map { AnyShapeStyle(Color($0.surface)) } ?? AnyShapeStyle(.quinary)
    }

    private var primaryText: Color {
        guard palette != nil else { return .primary }
        return isDark ? .white.opacity(0.92) : .black.opacity(0.85)
    }

    private var secondaryText: Color {
        palette.map { Color($0.secondaryText) } ?? .secondary
    }
}
