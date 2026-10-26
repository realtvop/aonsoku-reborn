import AonsokuKit
import Perception
import SwiftUI

/// All albums in a grid, or one slice of them: a genre, an artist's
/// discography or search results. The full list can be re-sorted from the
/// toolbar, and the order is remembered like the web album list.
struct AlbumsListView: View {
    @State private var filter: AlbumListFilter
    @State private var searchText = ""

    @Environment(AppModel.self) private var app
    @Environment(Localizer.self) private var t

    init(filter: AlbumListFilter) {
        _filter = State(initialValue: filter)
    }

    var body: some View {
        WithPerceptionTracking {
            QueriedCollection(query: query, debounce: isSearching ? .milliseconds(300) : .zero) { repository, filter, offset, limit in
                WithPerceptionTracking {
                    try await repository.albums(filter, offset: offset, limit: limit)
                }
            } content: { collection in
                ScrollView {
                    AlbumGrid(collection: collection, caption: caption)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                }
                .pagedStates(collection) {
                    if isSearching {
                        EmptyStateView(title: t("command.noResults"), systemImage: "magnifyingglass")
                    } else {
                        EmptyStateView(
                            title: t("album.list.empty.title"),
                            systemImage: "square.stack",
                            description: t("album.list.empty.info")
                        )
                    }
                }
                .refreshable { await collection.refresh() }
            }
            .offlineBanner()
            .themedBackground()
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.large)
            .searchable(isSortable, text: $searchText, prompt: t("album.list.search.placeholder"))
            .toolbar {
                if isSortable {
                    ToolbarItem(placement: .topBarTrailing) {
                        WithPerceptionTracking {
                            sortMenu
                        }
                    }
                } else if case let .byGenre(genre) = filter {
                    ToolbarItem(placement: .topBarTrailing) {
                        WithPerceptionTracking {
                            NavigationLink(value: AppRoute.songs(SongListQuery(scope: .genre(genre)))) {
                                Label(t("sidebar.songs"), systemImage: "music.note")
                            }
                        }
                    }
                }
            }
            .onChange(of: filter) {
                AlbumListPreference.save(filter, to: app.services.preferences)
            }
        }
    }

    /// The whole library in a chosen order, as opposed to a fixed slice.
    private var isSortable: Bool {
        AlbumSortOption(filter) != nil
    }

    private var isSearching: Bool {
        !trimmedSearch.isEmpty
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var query: AlbumListFilter {
        isSortable && isSearching ? .search(trimmedSearch) : filter
    }

    private var caption: AlbumTile.Caption {
        switch query {
        case .byYear, .discography: .year
        default: .artist
        }
    }

    private var title: String {
        switch filter {
        case let .byGenre(genre): genre
        case .discography: t("album.list.filter.discography")
        default: t("sidebar.albums")
        }
    }

    private var subtitle: String {
        switch filter {
        case .byGenre, .discography: ""
        case let .search(text): "“\(text)”"
        default: filter.title(t)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker(t("album.list.filter.label"), selection: sortOption) {
                ForEach(AlbumSortOption.allCases) { option in
                    WithPerceptionTracking {
                        Label(t(option.labelKey), systemImage: option.symbol)
                            .tag(option)
                    }
                }
            }
            .pickerStyle(.inline)
            if case .byYear = filter {
                Picker(t("album.list.filter.releaseYear"), selection: newestFirst) {
                    Text(t("album.list.filter.year.oldest")).tag(false)
                    Text(t("album.list.filter.year.newest")).tag(true)
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label(t("album.list.filter.label"), systemImage: "line.3.horizontal.decrease")
        }
    }

    private var sortOption: Binding<AlbumSortOption> {
        Binding(
            get: { AlbumSortOption(filter) ?? .recentlyAdded },
            set: { option in
                let newestFirst = AlbumListPreference.savedNewestFirst(app.services.preferences)
                withAnimation(.smooth) {
                    filter = option.filter(newestFirst: newestFirst)
                }
            }
        )
    }

    private var newestFirst: Binding<Bool> {
        Binding(
            get: {
                if case let .byYear(newestFirst) = filter { return newestFirst }
                return false
            },
            set: { filter = .byYear(newestFirst: $0) }
        )
    }
}

/// The orders the album list offers, which are the web mobile album
/// filters without genre, discography and search.
enum AlbumSortOption: String, CaseIterable, Identifiable {
    case recentlyAdded
    case recentlyPlayed
    case mostPlayed
    case name
    case artist
    case releaseYear
    case favorites
    case random

    var id: String { rawValue }

    init?(_ filter: AlbumListFilter) {
        switch filter {
        case .recentlyAdded: self = .recentlyAdded
        case .recentlyPlayed: self = .recentlyPlayed
        case .mostPlayed: self = .mostPlayed
        case .alphabeticalByName: self = .name
        case .alphabeticalByArtist: self = .artist
        case .byYear: self = .releaseYear
        case .favorites: self = .favorites
        case .random: self = .random
        case .byGenre, .discography, .search: return nil
        }
    }

    /// The web's stored value (`AlbumsFilters`).
    init?(webValue: String) {
        switch webValue {
        case "newest": self = .recentlyAdded
        case "recent": self = .recentlyPlayed
        case "frequent": self = .mostPlayed
        case "alphabeticalByName": self = .name
        case "alphabeticalByArtist": self = .artist
        case "byYear": self = .releaseYear
        case "starred": self = .favorites
        case "random": self = .random
        default: return nil
        }
    }

    var webValue: String {
        switch self {
        case .recentlyAdded: "newest"
        case .recentlyPlayed: "recent"
        case .mostPlayed: "frequent"
        case .name: "alphabeticalByName"
        case .artist: "alphabeticalByArtist"
        case .releaseYear: "byYear"
        case .favorites: "starred"
        case .random: "random"
        }
    }

    func filter(newestFirst: Bool) -> AlbumListFilter {
        switch self {
        case .recentlyAdded: .recentlyAdded
        case .recentlyPlayed: .recentlyPlayed
        case .mostPlayed: .mostPlayed
        case .name: .alphabeticalByName
        case .artist: .alphabeticalByArtist
        case .releaseYear: .byYear(newestFirst: newestFirst)
        case .favorites: .favorites
        case .random: .random
        }
    }

    var labelKey: String {
        switch self {
        case .recentlyAdded: "album.list.filter.recentlyAdded"
        case .recentlyPlayed: "album.list.filter.recentlyPlayed"
        case .mostPlayed: "album.list.filter.mostPlayed"
        case .name: "album.list.filter.name"
        case .artist: "album.list.filter.artist"
        case .releaseYear: "album.list.filter.releaseYear"
        case .favorites: "album.list.filter.favorites"
        case .random: "album.list.filter.random"
        }
    }

    var symbol: String {
        switch self {
        case .recentlyAdded: "clock.badge.plus"
        case .recentlyPlayed: "clock.arrow.circlepath"
        case .mostPlayed: "chart.bar"
        case .name: "textformat"
        case .artist: "music.mic"
        case .releaseYear: "calendar"
        case .favorites: "heart"
        case .random: "shuffle"
        }
    }
}

/// The album list order the user picked, stored under the web's
/// preference keys (`PersistedAlbumListKeys`) so it carries over from the
/// previous app.
enum AlbumListPreference {
    static let filterKey = "albums-list-filter"
    static let yearKey = "albums-list-year"

    /// The saved order, or Recently Added. Like the web mobile list, a saved
    /// genre or discography filter is not restored.
    static func load(_ preferences: PreferencesService) -> AlbumListFilter {
        let option = preferences.getString(filterKey).flatMap { AlbumSortOption(webValue: $0) }
        return (option ?? .recentlyAdded).filter(newestFirst: savedNewestFirst(preferences))
    }

    /// The saved release year order; the web defaults to oldest first.
    static func savedNewestFirst(_ preferences: PreferencesService) -> Bool {
        preferences.getString(yearKey) == "newest"
    }

    static func save(_ filter: AlbumListFilter, to preferences: PreferencesService) {
        guard let option = AlbumSortOption(filter) else { return }
        preferences.setString(option.webValue, for: filterKey)
        if case let .byYear(newestFirst) = filter {
            preferences.setString(newestFirst ? "newest" : "oldest", for: yearKey)
        }
    }
}
