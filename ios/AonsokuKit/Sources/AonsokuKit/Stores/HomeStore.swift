import Foundation
import Perception

/// Home page albums: the carousel and the section rows (web `useHomeData`).
/// Pinned items live in `PinnedHomeStore`.
@MainActor
@Perceptible
public final class HomeStore {
    public private(set) var carousel: [Album] = []
    public private(set) var sections: [HomeSection: [Album]] = [:]
    public private(set) var phase: LoadPhase = .idle

    @PerceptionIgnored public let repository: LibraryRepository
    @PerceptionIgnored private var loadTask: Task<Void, Never>?
    @PerceptionIgnored private let preferences: PreferencesService?
    @PerceptionIgnored private var accountKey: String?
    static let cacheKey = "home.snapshot.v1"
    public private(set) var hasCarousel = false
    @PerceptionIgnored private let now: () -> Date
    @PerceptionIgnored private var carouselUpdatedAt: Date?
    private static let randomCacheLifetime: TimeInterval = 24 * 60 * 60

    @PerceptionIgnored private var loadRevision: UInt64 = 0
    @PerceptionIgnored private var taskRefreshesRandom = false
    @PerceptionIgnored private var hasLoaded = false
    @PerceptionIgnored private var generation: UInt64 = 0

    public init(
        repository: LibraryRepository, preferences: PreferencesService? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.preferences = preferences
        self.now = now
    }

    /// Restore the account's last Home results before its first frame.
    public func restoreCached(accountKey: String) {
        reset()
        self.accountKey = accountKey
        if let snapshot = preferences?.getJSON(Self.cacheKey, as: HomeSnapshot.self),
           snapshot.accountKey == accountKey {
            carousel = snapshot.carousel ?? []
            hasCarousel = snapshot.carousel != nil
            carouselUpdatedAt = snapshot.carouselUpdatedAt ?? now()
            for section in HomeSection.allCases {
                sections[section] = snapshot.sections[section.rawValue]
            }
        }
        // An existing synced library can seed a first launch without a snapshot.
        if !hasCarousel, let albums = try? repository.cachedHomeAlbums(.explore, size: HomeSection.carouselSize),
           !albums.isEmpty {
            carousel = albums
            hasCarousel = true
            carouselUpdatedAt = now()
        }
        for section in HomeSection.allCases where sections[section] == nil {
            if let albums = try? repository.cachedHomeAlbums(section, size: HomeSection.size), !albums.isEmpty {
                sections[section] = albums
            }
        }
        persist()
    }

    private func persist() {
        guard let accountKey else { return }
        let values = Dictionary(uniqueKeysWithValues: sections.map { ($0.key.rawValue, $0.value) })
        try? preferences?.setJSON(HomeSnapshot(
            accountKey: accountKey, carousel: hasCarousel ? carousel : nil, sections: values,
            carouselUpdatedAt: carouselUpdatedAt
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
        await runRefresh(refreshRandom: false)
    }

    /// Refreshes automatically without replacing fresh random recommendations.
    public func refreshAutomatically() async {
        await runRefresh(refreshRandom: false)
    }

    /// Reloads the carousel and every section. Sections that fail keep their
    /// previous albums.
    public func refresh() async {
        await runRefresh(refreshRandom: true)
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
        carouselUpdatedAt = nil
        carousel = []
        sections = [:]
        phase = .idle
    }

    private func runRefresh(refreshRandom: Bool) async {
        let generation = generation
        if let loadTask {
            let revision = loadRevision
            let needsManualRefresh = refreshRandom && !taskRefreshesRandom
            await loadTask.value
            guard generation == self.generation else { return }
            if revision == loadRevision { self.loadTask = nil }
            if needsManualRefresh { await runRefresh(refreshRandom: true) }
            return
        }
        loadRevision &+= 1
        let revision = loadRevision
        taskRefreshesRandom = refreshRandom
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(generation: generation, refreshRandom: refreshRandom)
        }
        loadTask = task
        await task.value
        if generation == self.generation, revision == loadRevision { loadTask = nil }
    }

    private func isExpired(_ date: Date?) -> Bool {
        guard let date else { return true }
        return now().timeIntervalSince(date) >= Self.randomCacheLifetime
    }

    private func performRefresh(generation: UInt64, refreshRandom: Bool) async {
        let hadContent = !isEmpty
        phase = .loading
        var successes = 0
        var firstError: String?
        let needsCarousel = !hasCarousel
        let missingSections = Set(HomeSection.allCases.filter { sections[$0] == nil })

        let refreshCarousel = refreshRandom || carousel.isEmpty || isExpired(carouselUpdatedAt)

        await withTaskGroup(of: HomeRefreshResult.self) { group in
            if refreshCarousel {
                group.addTask { [repository] in
                    do {
                        return .carousel(try await repository.carouselAlbums(fallbackToLocal: needsCarousel))
                    } catch {
                        return .failure(error.localizedDescription)
                    }
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
                    carouselUpdatedAt = now()
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
    var carouselUpdatedAt: Date?
}
