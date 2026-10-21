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
        guard let albums = try? await repository.homeAlbums(
            .recentlyPlayed,
            size: HomeSection.size
        ) else { return }
        sections[.recentlyPlayed] = albums
    }

    private func runRefresh() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performRefresh() async {
        let hadContent = !isEmpty
        phase = .loading
        var successes = 0
        var firstError: String?

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
                    carousel = albums
                    successes += 1
                case let .section(section, albums):
                    sections[section] = albums
                    successes += 1
                case let .failure(message):
                    if firstError == nil { firstError = message }
                }
            }
        }

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
