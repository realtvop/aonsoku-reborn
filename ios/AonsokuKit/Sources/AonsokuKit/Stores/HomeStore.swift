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
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var generation: UInt64 = 0

    public init(repository: LibraryRepository) {
        self.repository = repository
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
            size: HomeSection.size
        ), generation == self.generation else { return }
        sections[.recentlyPlayed] = albums
    }

    public func reset() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        hasLoaded = false
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
        loadTask = nil
    }

    private func performRefresh(generation: UInt64) async {
        let hadContent = !isEmpty
        phase = .loading
        var successes = 0
        var firstError: String?
        var nextCarousel: [Album]?
        var nextSections: [HomeSection: [Album]] = [:]

        await withTaskGroup(of: HomeRefreshResult.self) { group in
            group.addTask { [repository] in
                do {
                    return .carousel(try await repository.carouselAlbums())
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
            for section in HomeSection.allCases {
                group.addTask { [repository] in
                    do {
                        return .section(
                            section,
                            try await repository.homeAlbums(section, size: HomeSection.size)
                        )
                    } catch {
                        return .failure(error.localizedDescription)
                    }
                }
            }

            for await result in group {
                switch result {
                case let .carousel(albums):
                    nextCarousel = albums
                    successes += 1
                case let .section(section, albums):
                    nextSections[section] = albums
                    successes += 1
                case let .failure(message):
                    if firstError == nil { firstError = message }
                }
            }
        }

        guard generation == self.generation, !Task.isCancelled else { return }
        if let nextCarousel { carousel = nextCarousel }
        for (section, albums) in nextSections { sections[section] = albums }
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
