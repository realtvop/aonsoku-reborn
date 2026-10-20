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
    public func loadIfNeeded() async {}

    /// Reloads the carousel and every section. Sections that fail keep their
    /// previous albums.
    public func refresh() async {}

    /// Reloads only Recently Played; the Home screen calls it every two
    /// minutes while visible and online.
    public func refreshRecentlyPlayed() async {}
}
