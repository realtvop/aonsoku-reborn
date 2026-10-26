import AonsokuKit
import Perception
import SwiftUI

/// Every genre as a colored card. A genre opens its albums.
struct GenresView: View {
    @State private var genres: [Genre] = []
    @State private var phase = LoadPhase.idle
    @State private var searchText = ""

    @Environment(AppModel.self) private var app
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                TileGrid(minimumWidth: 160) {
                    WithPerceptionTracking {
                        ForEach(filtered) { genre in
                            WithPerceptionTracking {
                                GenreLink(genre: genre)
                            }
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .loadStates(phase, isEmpty: genres.isEmpty) {
                Task { await load() }
            } empty: {
                EmptyStateView(title: t("album.list.genre.notFound"), systemImage: "guitars")
            }
            .overlay {
                WithPerceptionTracking {
                    if isSearching, filtered.isEmpty, !genres.isEmpty {
                        EmptyStateView(title: t("album.list.genre.notFound"), systemImage: "magnifyingglass")
                    }
                }
            }
            .offlineBanner()
            .themedBackground()
            .navigationTitle(t("table.columns.genres"))
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: Text(t("album.list.genre.search")))
            .refreshable { await load() }
            .task {
                guard phase == .idle else { return }
                await load()
            }
        }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedSearch.isEmpty
    }

    private var filtered: [Genre] {
        guard isSearching else { return genres }
        return genres.filter { $0.name.localizedStandardContains(trimmedSearch) }
    }

    /// Loads the genres A to Z. A failed refresh keeps the ones shown.
    private func load() async {
        if genres.isEmpty { phase = .loading }
        do {
            genres = try await app.repository.genres()
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            phase = .loaded
        } catch is CancellationError {
            if genres.isEmpty { phase = .idle }
        } catch {
            if genres.isEmpty {
                phase = .failed(error.localizedDescription)
            } else {
                toasts.show(error: error)
            }
        }
    }
}

/// A genre card that opens the genre's albums.
struct GenreLink: View {
    let genre: Genre

    var body: some View {
        WithPerceptionTracking {
            NavigationLink(value: AppRoute.albums(.byGenre(genre.name))) {
                GenreTile(genre: genre)
            }
            .buttonStyle(.pressable)
        }
    }
}

/// A genre as a colored card. The color comes from the name, so a genre
/// looks the same everywhere and on every launch.
struct GenreTile: View {
    let genre: Genre

    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            let hue = Self.hue(for: genre.name)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hue: hue, saturation: 0.58, brightness: 0.8),
                            Color(hue: (hue + 0.06).truncatingRemainder(dividingBy: 1), saturation: 0.72, brightness: 0.46),
                        ],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                )
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    WithPerceptionTracking {
                        Image(systemName: "music.note")
                            .font(.system(size: 56, weight: .bold))
                            .foregroundStyle(.white.opacity(0.16))
                            .rotationEffect(.degrees(16))
                            .offset(x: 8, y: -6)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    WithPerceptionTracking {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(genre.name)
                                .displayFont(.inline)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if genre.albumCount > 0 {
                                Text(t("artist.info.albumsCount", count: genre.albumCount))
                                    .font(.caption)
                                    .opacity(0.8)
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(12)
                    }
                }
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .contentShape(.rect(cornerRadius: 14, style: .continuous))
                .accessibilityElement(children: .combine)
        }
    }

    /// A hue in 0..<1 from the name. `hashValue` is seeded per launch, so
    /// this is FNV-1a over the lowercased UTF-8 bytes.
    static func hue(for name: String) -> Double {
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Double(hash % 360) / 360
    }
}
