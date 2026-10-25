import AonsokuKit
import SwiftUI

// MARK: - Header

/// The top of an album, playlist or artist page, like the web's image
/// header: the cover over a band of its average color, then the kind of
/// page, the name, a subtitle and the details. Centered on a phone; the
/// cover beside the text on iPad. In a scroll view the header draws its own
/// band; a list draws it with `detailBand` instead.
struct DetailHeader<Cover: View, Subtitle: View>: View {
    /// "Album", "Playlist" or "Artist".
    let kind: String
    let title: String
    var metadata: [MetadataItem] = []
    let palette: ArtworkPalette?
    var drawsBand = true
    @ViewBuilder let cover: Cover
    @ViewBuilder let subtitle: Subtitle

    @Environment(\.themeContext) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let isDark = DetailBand.isDark(palette, theme: theme.palette)
        let link = DetailBand.linkColor(palette, theme: theme.palette)
        Group {
            if sizeClass == .regular {
                HStack(alignment: .bottom, spacing: 28) {
                    framedCover(side: 220)
                    texts(alignment: .leading, isDark: isDark, link: link)
                    Spacer(minLength: 0)
                }
                .padding(.top, 16)
            } else {
                VStack(spacing: 16) {
                    framedCover(side: 200)
                    texts(alignment: .center, isDark: isDark, link: link)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
        }
        .pageMargins()
        .padding(.bottom, 8)
        .foregroundStyle(isDark ? Color.white : Color.black)
        .environment(\.colorScheme, isDark ? .dark : .light)
        .background {
            if drawsBand {
                DetailBand(palette: palette)
                    .padding(.top, -DetailBand.overscroll)
                    .padding(.bottom, -DetailBand.fadeHeight)
            }
        }
    }

    private func framedCover(side: CGFloat) -> some View {
        cover
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
    }

    private func texts(alignment: HorizontalAlignment, isDark: Bool, link: Color) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: 4) {
            Text(kind)
                .font(.caption.weight(.medium))
            Text(title)
                .displayFont(.title)
                .lineLimit(3)
                .multilineTextAlignment(textAlignment)
                .shadow(color: .black.opacity(isDark ? 0.25 : 0), radius: 6, y: 1)
                .accessibilityAddTraits(.isHeader)
            subtitle
                .multilineTextAlignment(textAlignment)
                .tint(link)
            if !metadata.isEmpty {
                MetadataLine(items: metadata, alignment: alignment)
                    .font(.subheadline)
                    .padding(.top, 2)
            }
        }
    }
}

/// The band behind a detail header: the cover's average color washed with
/// the theme's background the way the web header overlays it, reaching up
/// under the navigation bar, so pulling the page down shows more of it,
/// and fading into the page below the header.
struct DetailBand: View {
    let palette: ArtworkPalette?

    @Environment(\.themeContext) private var theme

    /// How far the band reaches above the header, enough for the bars and
    /// a long pull.
    static let overscroll: CGFloat = 1200
    /// The fade from the band into the page.
    static let fadeHeight: CGFloat = 96
    /// Where the title and the lines below it sit on the band, as the share of
    /// the background washed over the cover's color.
    private static let textStops = [0.35, 0.4, 0.45, 0.5]
    /// Where the artist link sits, lower on the band than the title.
    private static let linkStops = [0.45, 0.5]
    /// Large text needs 3:1 against its background.
    private static let largeTextContrast = 3.0

    var body: some View {
        let background = theme.palette.background
        let color = palette?.average.map(Color.init) ?? theme.palette.page
        VStack(spacing: 0) {
            ZStack {
                color
                background.opacity(0.2)
            }
            .frame(height: Self.overscroll)
            ZStack {
                color
                LinearGradient(
                    colors: [background.opacity(0.2), background.opacity(0.35), background.opacity(0.5)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            ZStack {
                color
                LinearGradient(
                    colors: [background.opacity(0.5), theme.palette.page],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: Self.fadeHeight)
        }
        .animation(.smooth(duration: 0.6), value: palette)
        .accessibilityHidden(true)
    }

    /// Whether light text reads better on the band behind a header's text,
    /// the theme's own answer until the cover's colors are known. The band
    /// grows darker or lighter toward the background as it runs down the
    /// header, so each text color is judged by its weakest contrast over the
    /// stops the text sits on, not over the band's average.
    static func isDark(_ palette: ArtworkPalette?, theme: ThemePalette) -> Bool {
        guard let average = palette?.average else { return theme.isDark }
        let bands = bandColors(at: textStops, average: average, theme: theme)
        let white = RGBColor(red: 1, green: 1, blue: 1)
        let black = RGBColor(red: 0, green: 0, blue: 0)
        let lightText = bands.map { white.contrastRatio(with: $0) }.min() ?? 0
        let darkText = bands.map { black.contrastRatio(with: $0) }.min() ?? 0
        return lightText > darkText
    }

    /// The artist link's color: the theme's primary while it reaches large-text
    /// contrast over the band where the link sits, otherwise the primary pulled
    /// toward the header's text color until it does.
    static func linkColor(_ palette: ArtworkPalette?, theme: ThemePalette) -> Color {
        guard let average = palette?.average else { return theme.primary }
        let bands = bandColors(at: linkStops, average: average, theme: theme)
        let text = isDark(palette, theme: theme)
            ? RGBColor(red: 1, green: 1, blue: 1)
            : RGBColor(red: 0, green: 0, blue: 0)
        for step in 0...10 {
            let link = theme.primaryRGB.mixed(with: text, by: Double(step) / 10)
            if bands.allSatisfy({ link.contrastRatio(with: $0) >= largeTextContrast }) {
                return Color(link)
            }
        }
        return Color(text)
    }

    /// The band's colors at `stops`, laid out the way `body` draws them.
    private static func bandColors(
        at stops: [Double],
        average: RGBColor,
        theme: ThemePalette
    ) -> [RGBColor] {
        stops.map { average.mixed(with: theme.backgroundRGB, by: $0) }
    }
}

private extension RGBColor {
    /// The color `fraction` of the way from this one to `other`.
    func mixed(with other: RGBColor, by fraction: Double) -> RGBColor {
        RGBColor(
            red: red * (1 - fraction) + other.red * fraction,
            green: green * (1 - fraction) + other.green * fraction,
            blue: blue * (1 - fraction) + other.blue * fraction
        )
    }
}

extension View {
    /// Draws a `DetailHeader`'s band behind a list whose first row is the
    /// header, moving with the list's scroll. Apply before
    /// `themedBackground`, which paints the page behind it.
    func detailBand(_ palette: ArtworkPalette?, headerHeight: CGFloat) -> some View {
        modifier(ListDetailBand(palette: palette, headerHeight: headerHeight))
    }
}

private struct ListDetailBand: ViewModifier {
    let palette: ArtworkPalette?
    let headerHeight: CGFloat

    private struct Scroll: Equatable {
        var offset: CGFloat = 0
        var inset: CGFloat = 0
    }

    @State private var scroll = Scroll()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Scroll.self) { geometry in
                // Past the band, the value stops changing, so scrolling the
                // rest of the list does not redraw it.
                let limit = headerHeight + DetailBand.fadeHeight + 1
                return Scroll(
                    offset: min(geometry.contentOffset.y + geometry.contentInsets.top, limit),
                    inset: geometry.contentInsets.top
                )
            } action: { _, value in
                scroll = value
            }
            .background(alignment: .top) {
                DetailBand(palette: palette)
                    .frame(height: DetailBand.overscroll + headerHeight + DetailBand.fadeHeight)
                    .offset(y: scroll.inset - scroll.offset - DetailBand.overscroll)
                    .ignoresSafeArea()
            }
    }
}

// MARK: - Title

extension View {
    /// An inline navigation title that appears once the header showing the
    /// page's name has scrolled past `threshold`. Until then the bar and the
    /// status bar follow `headerIsDark`, for a header band that is lighter
    /// or darker than the page.
    func scrollRevealedTitle(_ title: String, threshold: CGFloat, headerIsDark: Bool? = nil) -> some View {
        modifier(ScrollRevealedTitle(title: title, threshold: threshold, headerIsDark: headerIsDark))
    }
}

private struct ScrollRevealedTitle: ViewModifier {
    let title: String
    let threshold: CGFloat
    let headerIsDark: Bool?

    @State private var isRevealed = false

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(barColorScheme, for: .navigationBar)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > threshold
            } action: { _, revealed in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isRevealed = revealed
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .displayFont(.inline)
                        .lineLimit(1)
                        .opacity(isRevealed ? 1 : 0)
                        .accessibilityHidden(!isRevealed)
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }

    private var barColorScheme: ColorScheme? {
        guard !isRevealed, let headerIsDark else { return nil }
        return headerIsDark ? .dark : .light
    }
}

// MARK: - Actions

/// The heart in a toolbar, filled while the item is a favorite.
struct FavoriteToolbarButton: View {
    let kind: FavoriteKind
    let id: String

    @Environment(FavoritesStore.self) private var favorites
    @Environment(Localizer.self) private var t

    var body: some View {
        let isFavorite = favorites.isFavorite(kind, id: id)
        Button {
            Task { await favorites.toggle(kind, id: id) }
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isFavorite)
        }
        .accessibilityLabel(t(isFavorite ? "options.unlike" : "options.like"))
        .haptic(.impact(weight: .light), trigger: isFavorite)
    }
}

/// The heart beside Play: red and filled while the item is a favorite, as
/// on the web.
struct FavoriteActionButton: View {
    let kind: FavoriteKind
    let id: String

    @Environment(FavoritesStore.self) private var favorites
    @Environment(Localizer.self) private var t

    var body: some View {
        let isFavorite = favorites.isFavorite(kind, id: id)
        ActionIconButton(
            systemImage: isFavorite ? "heart.fill" : "heart",
            label: t(isFavorite ? "options.unlike" : "options.like"),
            foreground: isFavorite ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tint)
        ) {
            Task { await favorites.toggle(kind, id: id) }
        }
        .symbolEffect(.bounce, value: isFavorite)
        .haptic(.impact(weight: .light), trigger: isFavorite)
    }
}

/// Downloads a playlist for offline playback beside Play: an arrow, its
/// progress, then a check whose menu removes the download.
struct PlaylistDownloadButton: View {
    let playlistId: String

    @Environment(DownloadsStore.self) private var downloads
    @Environment(Localizer.self) private var t

    var body: some View {
        let _ = downloads.revision
        switch downloads.state(ofPlaylist: playlistId) {
        case .notCached:
            ActionIconButton(systemImage: "arrow.down.circle", label: t("options.downloadPlaylist")) {
                Task { await downloads.download(playlistId: playlistId) }
            }
        case let .downloading(completed, total):
            ProgressRing(progress: total > 0 ? Double(completed) / Double(total) : nil, diameter: 22)
                .frame(width: 48, height: 48)
                .accessibilityElement()
                .accessibilityLabel(t("offline.badge.downloading"))
        case .cached:
            Menu {
                Button(t("options.removeDownload"), systemImage: "trash", role: .destructive) {
                    Task { await downloads.remove(playlistId: playlistId) }
                }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t("offline.badge.downloaded"))
        }
    }
}

// MARK: - About

/// A link under the full notes or biography.
struct AboutLink: Identifiable, Hashable {
    let title: String
    let url: URL

    var id: URL { url }
}

/// A few lines of an album's notes or an artist's biography that open the
/// whole text in a sheet.
struct AboutCard: View {
    let title: String
    let text: AttributedString
    var links: [AboutLink] = []

    @State private var isPresented = false

    @Environment(Localizer.self) private var t

    var body: some View {
        Button {
            isPresented = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .displayFont(.inline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(text.plainText)
                    .font(.subheadline)
                    .foregroundStyle(ThemeColor.mutedForeground)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(t("generic.seeMore"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardSurface()
        }
        .buttonStyle(.pressable)
        .accessibilityHint(t("generic.seeMore"))
        .sheet(isPresented: $isPresented) {
            AboutSheet(title: title, text: text, links: links)
        }
    }
}

private struct AboutSheet: View {
    let title: String
    let text: AttributedString
    let links: [AboutLink]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(text)
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !links.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(links) { link in
                                Link(destination: link.url) {
                                    Label(link.title, systemImage: "arrow.up.forward.app")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                                .controlSize(.large)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
