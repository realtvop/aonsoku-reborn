import AonsokuKit
import SwiftUI

// MARK: - Artwork glow

extension View {
    /// The background of a page about one album, playlist or artist: the
    /// cover's color glowing down from the top and fading as the page
    /// scrolls, the way Apple Music tints its album pages. List rows on
    /// such a page use a clear background.
    func artworkGlowBackground(_ palette: ArtworkPalette?) -> some View {
        modifier(ArtworkGlowBackground(palette: palette))
    }
}

private struct ArtworkGlowBackground: ViewModifier {
    let palette: ArtworkPalette?

    /// 0 at the top of the page, 1 once it has scrolled a screenful.
    @State private var fade = 0.0

    @Environment(\.themeContext) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .onScrollGeometryChange(for: Double.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                // Steps of 5% keep the fade from redrawing every frame.
                return (min(max(offset / 360, 0), 1) * 20).rounded() / 20
            } action: { _, value in
                fade = value
            }
            .background {
                ZStack(alignment: .top) {
                    theme.palette.background
                    if let color = palette?.dominant {
                        LinearGradient(
                            stops: [
                                .init(color: color.opacity(strength), location: 0),
                                .init(color: color.opacity(strength * 0.4), location: 0.5),
                                .init(color: color.opacity(0), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 560)
                        .opacity(1 - fade)
                        .transition(.opacity)
                    }
                }
                .ignoresSafeArea()
                .animation(.smooth(duration: 0.6), value: palette)
            }
    }

    private var strength: Double {
        colorScheme == .dark ? 0.55 : 0.35
    }
}

// MARK: - Title

extension View {
    /// An inline navigation title that appears once the header showing the
    /// page's name has scrolled past `threshold`.
    func scrollRevealedTitle(_ title: String, threshold: CGFloat) -> some View {
        modifier(ScrollRevealedTitle(title: title, threshold: threshold))
    }
}

private struct ScrollRevealedTitle: ViewModifier {
    let title: String
    let threshold: CGFloat

    @State private var isRevealed = false

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
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
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(isRevealed ? 1 : 0)
                        .accessibilityHidden(!isRevealed)
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }
}

// MARK: - Toolbar

/// The heart in a page's toolbar, filled while the item is a favorite.
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
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(text.plainText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(t("generic.seeMore"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.fill.quinary, in: .rect(cornerRadius: 18, style: .continuous))
            .contentShape(.rect(cornerRadius: 18, style: .continuous))
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
