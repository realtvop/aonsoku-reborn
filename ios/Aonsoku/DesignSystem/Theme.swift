import AonsokuKit
import SwiftUI

// MARK: - Tokens

/// An HSL color in the web theme notation (`src/themes.css`): hue in
/// degrees, saturation and lightness in percent.
struct HSL: Hashable, Sendable {
    var hue: Double
    var saturation: Double
    var lightness: Double

    init(_ hue: Double, _ saturation: Double, _ lightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }

    /// The HSL color of an sRGB color.
    init(_ color: RGBColor) {
        let high = max(color.red, color.green, color.blue)
        let low = min(color.red, color.green, color.blue)
        let chroma = high - low
        var sector = 0.0
        if chroma > 0 {
            sector = switch high {
            case color.red: (color.green - color.blue) / chroma
            case color.green: (color.blue - color.red) / chroma + 2
            default: (color.red - color.green) / chroma + 4
            }
        }
        let lightness = (high + low) / 2
        let saturation = chroma > 0 ? chroma / (1 - abs(2 * lightness - 1)) : 0
        self.init(
            (sector < 0 ? sector + 6 : sector) * 60,
            saturation * 100,
            lightness * 100
        )
    }

    var rgb: (red: Double, green: Double, blue: Double) {
        let s = saturation / 100
        let l = lightness / 100
        let chroma = (1 - abs(2 * l - 1)) * s
        let sector = hue.truncatingRemainder(dividingBy: 360) / 60
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch sector {
        case ..<1: (chroma, x, 0)
        case ..<2: (x, chroma, 0)
        case ..<3: (0, chroma, x)
        case ..<4: (0, x, chroma)
        case ..<5: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        let m = l - chroma / 2
        return (r + m, g + m, b + m)
    }

    var color: Color {
        let (r, g, b) = rgb
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    /// Moves `fraction` of the way toward `other` in RGB space.
    func mixed(with other: HSL, _ fraction: Double) -> Color {
        let a = rgb
        let b = other.rgb
        return Color(
            .sRGB,
            red: a.red + (b.red - a.red) * fraction,
            green: a.green + (b.green - a.green) * fraction,
            blue: a.blue + (b.blue - a.blue) * fraction
        )
    }
}

/// The color tokens of one theme. The names follow the web theme
/// variables; `groupedBackground` and `elevated` are derived for iOS
/// grouped lists, where rows sit on a slightly different surface.
struct ThemePalette: Hashable {
    /// Bars, cards and menus: the web `--background`.
    let background: Color
    /// Behind every page: the web `--background-foreground`, which the web
    /// paints on its body.
    let page: Color
    let foreground: Color
    let card: Color
    let primary: Color
    let primaryForeground: Color
    let secondary: Color
    let secondaryForeground: Color
    let muted: Color
    let mutedForeground: Color
    let accent: Color
    let accentForeground: Color
    let destructive: Color
    let border: Color
    /// Behind grouped lists and forms.
    let groupedBackground: Color
    /// Grouped rows, cards and other raised surfaces.
    let elevated: Color
    let isDark: Bool

    init(
        background: HSL,
        page: HSL,
        foreground: HSL,
        card: HSL,
        primary: HSL,
        primaryForeground: HSL,
        secondary: HSL,
        secondaryForeground: HSL,
        muted: HSL,
        mutedForeground: HSL,
        accent: HSL,
        accentForeground: HSL,
        destructive: HSL,
        border: HSL
    ) {
        self.background = background.color
        self.page = page.color
        self.foreground = foreground.color
        self.card = card.color
        self.primary = primary.color
        self.primaryForeground = primaryForeground.color
        self.secondary = secondary.color
        self.secondaryForeground = secondaryForeground.color
        self.muted = muted.color
        self.mutedForeground = mutedForeground.color
        self.accent = accent.color
        self.accentForeground = accentForeground.color
        self.destructive = destructive.color
        self.border = border.color
        isDark = background.lightness < 50
        // Dark themes raise rows toward the foreground; light themes sink
        // the page instead, so rows keep the theme's own background.
        if isDark {
            groupedBackground = page.color
            elevated = page.mixed(with: foreground, 0.06)
        } else {
            groupedBackground = page.mixed(with: foreground, 0.035)
            elevated = background.color
        }
    }
}

/// A theme color as a shape style, resolved from the environment, so views
/// can write `.foregroundStyle(ThemeColor.mutedForeground)`.
enum ThemeColor: ShapeStyle {
    case page
    case background
    case foreground
    case card
    case primary
    case secondary
    case muted
    case mutedForeground
    case accent
    case border
    case elevated

    func resolve(in environment: EnvironmentValues) -> Color {
        let palette = environment.themeContext.palette
        return switch self {
        case .page: palette.page
        case .background: palette.background
        case .foreground: palette.foreground
        case .card: palette.card
        case .primary: palette.primary
        case .secondary: palette.secondary
        case .muted: palette.muted
        case .mutedForeground: palette.mutedForeground
        case .accent: palette.accent
        case .border: palette.border
        case .elevated: palette.elevated
        }
    }
}

// MARK: - Environment

/// The theme in effect for the current color scheme. Every theme, the
/// default light and dark ones included, paints its own backgrounds, so the
/// app wears the same colors as the web app.
struct ThemeContext: Equatable {
    var theme: AppTheme
    var palette: ThemePalette

    init(theme: AppTheme) {
        self.theme = theme
        palette = theme.palette
    }
}

extension EnvironmentValues {
    @Entry var themeContext = ThemeContext(theme: .dark)
}

/// Applies the user's appearance settings: the color scheme, the active
/// theme and its accent.
private struct ThemeRootModifier: ViewModifier {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let appearance = settings.settings.appearance
        let preferred: ColorScheme? = switch appearance.themeMode {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
        let scheme = preferred ?? systemScheme
        let theme = scheme == .dark ? appearance.darkTheme : appearance.lightTheme
        let context = ThemeContext(theme: theme)
        content
            .environment(\.themeContext, context)
            .tint(context.palette.primary)
            .preferredColorScheme(preferred)
    }
}

extension View {
    /// Applies the appearance settings. Use once per window root.
    func themeRoot() -> some View {
        modifier(ThemeRootModifier())
    }

    /// Paints the theme's background behind a scroll view or list.
    func themedBackground(grouped: Bool = false) -> some View {
        modifier(ThemedBackgroundModifier(grouped: grouped))
    }

    /// Gives list rows the theme's surface: raised in a grouped list, the
    /// page's own background in a plain one, with separators in the theme's
    /// border color. Apply to a `Section` or row.
    func themedRow(plain: Bool = false) -> some View {
        modifier(ThemedRowModifier(plain: plain))
    }
}

private struct ThemedBackgroundModifier: ViewModifier {
    @Environment(\.themeContext) private var theme
    let grouped: Bool

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background {
                (grouped ? theme.palette.groupedBackground : theme.palette.page)
                    .ignoresSafeArea()
            }
    }
}

private struct ThemedRowModifier: ViewModifier {
    @Environment(\.themeContext) private var theme
    let plain: Bool

    func body(content: Content) -> some View {
        content
            .listRowBackground(plain ? Color.clear : theme.palette.elevated)
            .listRowSeparatorTint(theme.palette.border)
    }
}

// MARK: - Palettes

extension AppTheme {
    /// Mirrors the HSL variables in `src/themes.css`.
    var palette: ThemePalette {
        switch self {
        case .light:
            ThemePalette(
                background: HSL(0, 0, 100),
                page: HSL(210, 20, 98),
                foreground: HSL(224, 10, 15),
                card: HSL(0, 0, 100),
                primary: HSL(161, 94, 30),
                primaryForeground: HSL(210, 20, 98),
                secondary: HSL(220, 14.3, 95.9),
                secondaryForeground: HSL(220.9, 39.3, 11),
                muted: HSL(220, 14.3, 95.9),
                mutedForeground: HSL(220, 8.9, 46.1),
                accent: HSL(220, 14.3, 92.9),
                accentForeground: HSL(220.9, 39.3, 11),
                destructive: HSL(0, 84.2, 60.2),
                border: HSL(220, 13, 91)
            )
        case .dark:
            ThemePalette(
                background: HSL(224, 71.4, 8.1),
                page: HSL(222, 47, 11),
                foreground: HSL(210, 20, 95),
                card: HSL(224, 71.4, 8.1),
                primary: HSL(160, 84, 39),
                primaryForeground: HSL(210, 20, 95),
                secondary: HSL(215, 27.9, 19.9),
                secondaryForeground: HSL(210, 20, 95),
                muted: HSL(215, 27.9, 14.9),
                mutedForeground: HSL(217.9, 10.6, 64.9),
                accent: HSL(215, 27.9, 19.9),
                accentForeground: HSL(210, 20, 95),
                destructive: HSL(0, 62.8, 30.6),
                border: HSL(215, 27.9, 19.9)
            )
        case .black:
            ThemePalette(
                background: HSL(240, 10, 3.9),
                page: HSL(240, 5.9, 10),
                foreground: HSL(0, 0, 98),
                card: HSL(240, 10, 3.9),
                primary: HSL(0, 0, 98),
                primaryForeground: HSL(240, 5.9, 10),
                secondary: HSL(240, 3.7, 15.9),
                secondaryForeground: HSL(0, 0, 98),
                muted: HSL(240, 3.7, 15.9),
                mutedForeground: HSL(240, 5, 64.9),
                accent: HSL(240, 3.7, 15.9),
                accentForeground: HSL(0, 0, 98),
                destructive: HSL(0, 62.8, 30.6),
                border: HSL(240, 3.7, 15.9)
            )
        case .oneDark:
            ThemePalette(
                background: HSL(220, 13, 16),
                page: HSL(220, 13, 18),
                foreground: HSL(219, 14, 84),
                card: HSL(220, 13, 16),
                primary: HSL(220, 13, 86),
                primaryForeground: HSL(220, 13, 26),
                secondary: HSL(220, 3, 25),
                secondaryForeground: HSL(220, 3, 85),
                muted: HSL(220, 12, 22),
                mutedForeground: HSL(220, 12, 72),
                accent: HSL(220, 13, 33),
                accentForeground: HSL(220, 13, 93),
                destructive: HSL(3, 89, 50),
                border: HSL(220, 3, 23)
            )
        case .nightOwlLight:
            ThemePalette(
                background: HSL(0, 0, 98),
                page: HSL(0, 0, 96),
                foreground: HSL(243, 14, 29),
                card: HSL(0, 0, 96),
                primary: HSL(243, 14, 29),
                primaryForeground: HSL(243, 14, 89),
                secondary: HSL(243, 4, 75),
                secondaryForeground: HSL(243, 4, 15),
                muted: HSL(0, 12, 90),
                mutedForeground: HSL(0, 12, 30),
                accent: HSL(0, 0, 83),
                accentForeground: HSL(0, 0, 23),
                destructive: HSL(8, 94, 20),
                border: HSL(0, 0, 93)
            )
        case .marmaladeBeaver:
            ThemePalette(
                background: HSL(233, 18, 17),
                page: HSL(233, 18, 19),
                foreground: HSL(173, 24, 93),
                card: HSL(233, 18, 17),
                primary: HSL(44, 100, 71),
                primaryForeground: HSL(44, 100, 11),
                secondary: HSL(44, 30, 25),
                secondaryForeground: HSL(44, 30, 85),
                muted: HSL(233, 12, 23),
                mutedForeground: HSL(233, 12, 73),
                accent: HSL(233, 18, 34),
                accentForeground: HSL(233, 18, 94),
                destructive: HSL(10, 90, 57),
                border: HSL(233, 8, 24)
            )
        case .noctisLilac:
            ThemePalette(
                background: HSL(249, 33, 96),
                page: HSL(250, 100, 97.6),
                foreground: HSL(247, 100, 21),
                card: HSL(249, 33, 94),
                primary: HSL(247, 78, 65),
                primaryForeground: HSL(0, 0, 100),
                secondary: HSL(247, 30, 75),
                secondaryForeground: HSL(247, 30, 15),
                muted: HSL(249, 12, 90),
                mutedForeground: HSL(249, 12, 30),
                accent: HSL(249, 33, 81),
                accentForeground: HSL(249, 33, 21),
                destructive: HSL(3, 93, 20),
                border: HSL(249, 23, 91)
            )
        case .materialTheme:
            ThemePalette(
                background: HSL(200, 19, 16),
                page: HSL(200, 19, 18),
                foreground: HSL(180, 100, 97),
                card: HSL(200, 19, 16),
                primary: HSL(180, 100, 97),
                primaryForeground: HSL(180, 100, 17),
                secondary: HSL(180, 30, 25),
                secondaryForeground: HSL(180, 30, 85),
                muted: HSL(200, 12, 22),
                mutedForeground: HSL(200, 12, 72),
                accent: HSL(200, 19, 33),
                accentForeground: HSL(200, 19, 93),
                destructive: HSL(8, 94, 48),
                border: HSL(200, 9, 23)
            )
        case .monokaiPro:
            ThemePalette(
                background: HSL(285, 5, 15),
                page: HSL(285, 5, 17),
                foreground: HSL(60, 25, 98),
                card: HSL(285, 5, 15),
                primary: HSL(45, 100, 70),
                primaryForeground: HSL(45, 100, 10),
                secondary: HSL(45, 30, 25),
                secondaryForeground: HSL(45, 30, 85),
                muted: HSL(285, 12, 21),
                mutedForeground: HSL(285, 12, 71),
                accent: HSL(285, 5, 32),
                accentForeground: HSL(285, 5, 92),
                destructive: HSL(10, 97, 48),
                border: HSL(0, 0, 22)
            )
        case .githubDark:
            ThemePalette(
                background: HSL(216, 28, 5),
                page: HSL(216, 28, 7),
                foreground: HSL(210, 17, 82),
                card: HSL(216, 28, 5),
                primary: HSL(210, 17, 82),
                primaryForeground: HSL(210, 17, 22),
                secondary: HSL(210, 7, 25),
                secondaryForeground: HSL(210, 7, 85),
                muted: HSL(216, 12, 15),
                mutedForeground: HSL(216, 12, 65),
                accent: HSL(216, 28, 22),
                accentForeground: HSL(216, 28, 82),
                destructive: HSL(1, 86, 57),
                border: HSL(216, 18, 12)
            )
        case .shadesOfPurple:
            ThemePalette(
                background: HSL(243, 33, 23),
                page: HSL(243, 33, 25),
                foreground: HSL(0, 0, 100),
                card: HSL(243, 33, 23),
                primary: HSL(50, 100, 49),
                primaryForeground: HSL(50, 100, 9),
                secondary: HSL(50, 30, 25),
                secondaryForeground: HSL(50, 30, 85),
                muted: HSL(243, 12, 29),
                mutedForeground: HSL(243, 12, 79),
                accent: HSL(243, 33, 40),
                accentForeground: HSL(0, 0, 100),
                destructive: HSL(3, 82, 47),
                border: HSL(243, 23, 30)
            )
        case .beardedSolarized:
            ThemePalette(
                background: HSL(195, 46, 12),
                page: HSL(195, 46, 14),
                foreground: HSL(194, 37, 84),
                card: HSL(195, 46, 12),
                primary: HSL(175, 59, 55),
                primaryForeground: HSL(175, 59, 15),
                secondary: HSL(175, 30, 25),
                secondaryForeground: HSL(175, 30, 85),
                muted: HSL(195, 12, 18),
                mutedForeground: HSL(195, 12, 68),
                accent: HSL(195, 46, 29),
                accentForeground: HSL(195, 46, 89),
                destructive: HSL(2, 91, 53),
                border: HSL(195, 36, 19)
            )
        case .catppuccinMocha:
            ThemePalette(
                background: HSL(240, 21, 13),
                page: HSL(240, 21, 15),
                foreground: HSL(226, 64, 88),
                card: HSL(240, 21, 13),
                primary: HSL(267, 84, 81),
                primaryForeground: HSL(267, 84, 21),
                secondary: HSL(267, 30, 25),
                secondaryForeground: HSL(267, 30, 85),
                muted: HSL(240, 12, 19),
                mutedForeground: HSL(240, 12, 69),
                accent: HSL(240, 21, 30),
                accentForeground: HSL(240, 21, 90),
                destructive: HSL(8, 96, 56),
                border: HSL(240, 11, 20)
            )
        case .nuclearDark:
            ThemePalette(
                background: HSL(213, 30.3, 10.94),
                page: HSL(213, 30.3, 12.94),
                foreground: HSL(90, 40, 98.04),
                card: HSL(213.91, 26.44, 17.06),
                primary: HSL(331.18, 100, 55.1),
                primaryForeground: HSL(0, 0, 100),
                secondary: HSL(213.91, 26.44, 17.06),
                secondaryForeground: HSL(90, 40, 98.04),
                muted: HSL(218.82, 17.89, 18.63),
                mutedForeground: HSL(0, 0, 82.35),
                accent: HSL(220.91, 39.29, 20.98),
                accentForeground: HSL(90, 40, 98.04),
                destructive: HSL(344.15, 100, 46.54),
                border: HSL(213.75, 9.2, 22)
            )
        case .achiever:
            ThemePalette(
                background: HSL(18, 51, 98),
                page: HSL(33.3, 100, 98),
                foreground: HSL(18, 50, 0),
                card: HSL(18, 51, 98),
                primary: HSL(18, 83, 58),
                primaryForeground: HSL(0, 0, 0),
                secondary: HSL(18, 5, 87),
                secondaryForeground: HSL(18, 5, 27),
                muted: HSL(18, 10, 87),
                mutedForeground: HSL(18, 15, 32),
                accent: HSL(18, 14, 80),
                accentForeground: HSL(18, 14, 20),
                destructive: HSL(20, 87, 25),
                border: HSL(220, 13, 91)
            )
        case .dracula:
            ThemePalette(
                background: HSL(231, 15, 18),
                page: HSL(231, 15, 20),
                foreground: HSL(60, 30, 96),
                card: HSL(232, 14, 31),
                primary: HSL(265, 89, 78),
                primaryForeground: HSL(60, 30, 96),
                secondary: HSL(232, 14, 31),
                secondaryForeground: HSL(60, 30, 96),
                muted: HSL(232, 14, 31),
                mutedForeground: HSL(60, 30, 96),
                accent: HSL(225, 27, 31),
                accentForeground: HSL(60, 30, 96),
                destructive: HSL(0, 100, 67),
                border: HSL(232, 14, 31)
            )
        case .discord:
            ThemePalette(
                background: HSL(221, 4, 15),
                page: HSL(217.5, 9.09, 17.25),
                foreground: HSL(334, 34, 98),
                card: HSL(210, 9.09, 12.94),
                primary: HSL(226.73, 58.43, 65.1),
                primaryForeground: HSL(334, 34, 98),
                secondary: HSL(214.29, 5.04, 27.25),
                secondaryForeground: HSL(334, 34, 98),
                muted: HSL(210, 9.09, 12.94),
                mutedForeground: HSL(334, 0, 60.77),
                accent: HSL(217.5, 3.22, 22.19),
                accentForeground: HSL(334, 34, 98),
                destructive: HSL(358.16, 68.78, 53.53),
                border: HSL(218, 3, 22)
            )
        case .tinaciousDesign:
            ThemePalette(
                background: HSL(240, 100, 99),
                page: HSL(240, 100, 98),
                foreground: HSL(244, 18, 21),
                card: HSL(240, 100, 97),
                primary: HSL(330, 100, 60),
                primaryForeground: HSL(0, 0, 100),
                secondary: HSL(330, 30, 65),
                secondaryForeground: HSL(330, 30, 15),
                muted: HSL(240, 12, 90),
                mutedForeground: HSL(240, 12, 30),
                accent: HSL(240, 90, 94),
                accentForeground: HSL(240, 100, 24),
                destructive: HSL(5, 89, 27),
                border: HSL(240, 90, 94)
            )
        case .vueDark:
            ThemePalette(
                background: HSL(192, 100, 10),
                page: HSL(192, 100, 12),
                foreground: HSL(0, 0, 90),
                card: HSL(192, 100, 8),
                primary: HSL(171, 82, 43),
                primaryForeground: HSL(171, 82, 3),
                secondary: HSL(171, 30, 25),
                secondaryForeground: HSL(171, 30, 85),
                muted: HSL(192, 12, 15),
                mutedForeground: HSL(192, 12, 65),
                accent: HSL(192, 90, 18),
                accentForeground: HSL(0, 0, 100),
                destructive: HSL(2, 95, 56),
                border: HSL(192, 90, 15)
            )
        case .vimDarkSoft:
            ThemePalette(
                background: HSL(20, 3, 17),
                page: HSL(20, 3, 19),
                foreground: HSL(43, 59, 81),
                card: HSL(20, 3, 17),
                primary: HSL(43, 59, 81),
                primaryForeground: HSL(43, 59, 21),
                secondary: HSL(43, 30, 25),
                secondaryForeground: HSL(43, 30, 85),
                muted: HSL(20, 12, 23),
                mutedForeground: HSL(20, 12, 73),
                accent: HSL(20, 3, 34),
                accentForeground: HSL(20, 3, 94),
                destructive: HSL(6, 85, 47),
                border: HSL(0, 0, 24)
            )
        }
    }
}

// MARK: - Grouped containers

/// A `Form` in the theme's grouped colors: rows on the raised surface over
/// the grouped background. Rows can still set their own background.
struct ThemedForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            Group {
                content
            }
            .themedRow()
        }
        .themedBackground(grouped: true)
    }
}

/// A grouped `List` in the theme's colors, like `ThemedForm`.
struct ThemedList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        List {
            Group {
                content
            }
            .themedRow()
        }
        .themedBackground(grouped: true)
    }
}
