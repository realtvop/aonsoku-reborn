import Foundation
import Observation

/// Home page albums: the carousel and the section rows (web `useHomeData`).
/// Pinned items live in `PinnedHomeStore`.
@MainActor
@Observable
public final class HomeStore {
    public private(set) var carousel: [Album] = []
    public private(set) var sections: [HomeSection: [Album]] = [:]
    public private(set) var phase: LoadPhase = .idle

    @ObservationIgnored public let repository: LibraryRepository
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let preferences: PreferencesService?
    @ObservationIgnored private var accountKey: String?
    private static let cacheKey = "home.snapshot.v1"
    public private(set) var hasCarousel = false

    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var generation: UInt64 = 0

    public init(repository: LibraryRepository, preferences: PreferencesService? = nil) {
        self.repository = repository
        self.preferences = preferences
    }

    /// Restore the account's last Home results before its first frame.
    public func restoreCached(accountKey: String) {
        reset()
        self.accountKey = accountKey
        if let snapshot = preferences?.getJSON(Self.cacheKey, as: HomeSnapshot.self),
           snapshot.accountKey == accountKey {
            carousel = snapshot.carousel ?? []
            hasCarousel = snapshot.carousel != nil
            for section in HomeSection.allCases {
                sections[section] = snapshot.sections[section.rawValue]
            }
        }
        // An existing synced library can seed a first launch without a snapshot.
        if !hasCarousel, let albums = try? repository.cachedHomeAlbums(.explore, size: HomeSection.carouselSize),
           !albums.isEmpty {
            carousel = albums
            hasCarousel = true
        }
        for section in HomeSection.allCases where sections[section] == nil {
            if let albums = try? repository.cachedHomeAlbums(section, size: HomeSection.size), !albums.isEmpty {
                sections[section] = albums
            }
        }
    }

    private func persist() {
        guard let accountKey else { return }
        let values = Dictionary(uniqueKeysWithValues: sections.map { ($0.key.rawValue, $0.value) })
        try? preferences?.setJSON(HomeSnapshot(
            accountKey: accountKey, carousel: hasCarousel ? carousel : nil, sections: values
        ), for: Self.cacheKey)
    }

    public func albums(in section: HomeSection) -> [Album] {
        sections[section] ?? []
    }

    /// True when every section and the carousel are empty after loading.
    public var isEmpty: Bool {
        carousel.isEmpty && sections.values.allSatisfy(\.isEmpty)
    }

    /// Loads once; later calls return immediately.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await runRefresh()
    }

    /// Reloads the carousel and every section. Sections that fail keep their
    /// previous albums.
    public func refresh() async {
        await runRefresh()
    }

    /// Reloads only Recently Played; the Home screen calls it every two
    /// minutes while visible and online.
    public func refreshRecentlyPlayed() async {
        let generation = generation
        guard let albums = try? await repository.homeAlbums(
            .recentlyPlayed,
            size: HomeSection.size, fallbackToLocal: sections[.recentlyPlayed] == nil
        ), generation == self.generation else { return }
        sections[.recentlyPlayed] = albums
        persist()
    }

    public func reset() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        hasLoaded = false
        accountKey = nil
        hasCarousel = false
        carousel = []
        sections = [:]
        phase = .idle
    }

    private func runRefresh() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let generation = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(generation: generation)
        }
        loadTask = task
        await task.value
        if generation == self.generation { loadTask = nil }
    }

    private func performRefresh(generation: UInt64) async {
        let hadContent = !isEmpty
        phase = .loading
        var successes = 0
        var firstError: String?
        let needsCarousel = !hasCarousel
        let missingSections = Set(HomeSection.allCases.filter { sections[$0] == nil })

        await withTaskGroup(of: HomeRefreshResult.self) { group in
            group.addTask { [repository] in
                do {
                    return .carousel(try await repository.carouselAlbums(fallbackToLocal: needsCarousel))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
            for section in HomeSection.allCases {
                group.addTask { [repository] in
                    do {
                        return .section(
                            section,
                            try await repository.homeAlbums(section, size: HomeSection.size, fallbackToLocal: missingSections.contains(section))
                        )
                    } catch {
                        return .failure(error.localizedDescription)
                    }
                }
            }

            for await result in group {
                guard generation == self.generation, !Task.isCancelled else { continue }
                switch result {
                case let .carousel(albums):
                    carousel = albums
                    hasCarousel = true
                    successes += 1
                case let .section(section, albums):
                    sections[section] = albums
                    successes += 1
                case let .failure(message):
                    if firstError == nil { firstError = message }
                }
            }
        }

        guard generation == self.generation, !Task.isCancelled else { return }
        persist()
        hasLoaded = true
        if successes == 0, !hadContent {
            phase = .failed(firstError ?? "Unable to load Home")
        } else {
            phase = .loaded
        }
    }
}

private enum HomeRefreshResult: Sendable {
    case carousel([Album])
    case section(HomeSection, [Album])
    case failure(String)
}

private struct HomeSnapshot: Codable {
    let accountKey: String
    let carousel: [Album]?
    let sections: [String: [Album]]
}
