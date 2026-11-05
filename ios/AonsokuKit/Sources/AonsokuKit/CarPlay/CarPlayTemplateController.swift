import CarPlay
import ImageIO
import UIKit

/// All visible UI is supplied by the public CarPlay template framework.
@MainActor
public final class CarPlayTemplateController: NSObject, @preconcurrency CPNowPlayingTemplateObserver,
    CPInterfaceControllerDelegate
{
    private let library: CarPlayLibraryProvider
    private let playback: AudioService
    private weak var interface: CPInterfaceController?
    private var eventToken: UUID?
    private var notifications: [NSObjectProtocol] = []
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var versions: [ObjectIdentifier: UUID] = [:]
    private var routes: [ObjectIdentifier: (CarPlayLibraryRoute, String, Int)] = [:]
    private var refreshWork: DispatchWorkItem?
    private var snapshot: CarPlayPlaybackSnapshot?
    private var connected = false
    private var queueOffset = 0
    private var queueHistory: [Int] = []
    private var pageHistory: [ObjectIdentifier: [Int]] = [:]
    // Reuse native item identifiers while the same logical rows remain visible.
    private var listItems: [ObjectIdentifier: [String: CPListItem]] = [:]
    private var home: CPListTemplate?
    private var downloads: CPListTemplate?
    private weak var queueTemplate: CPListTemplate?

    public init(library: CarPlayLibraryProvider = CarPlayLibraryProvider(), playback: AudioService = AppServices.shared.audio) {
        self.library = library
        self.playback = playback
        super.init()
    }

    public func connect(_ interface: CPInterfaceController) {
        self.interface = interface
        connected = true
        playback.start()
        interface.delegate = self
        interface.setRootTemplate(makeRootTemplate(), animated: false, completion: nil)
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.add(self)
        nowPlaying.upNextTitle = text("queue")
        nowPlaying.isAlbumArtistButtonEnabled = false
        eventToken = playback.subscribe { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if case .error(_, let message, _) = event, self.snapshot?.isRemote != true {
                    self.showError(NSError(domain: "AonsokuPlayback", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message]))
                }
                self.refreshPlayback()
                self.scheduleLibraryRefresh()
            }
        }
        for name in [Notification.Name.aonsokuNativeLibraryChanged, .aonsokuCredentialsChanged] {
            notifications.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        if name == .aonsokuCredentialsChanged {
                            self.tasks.values.forEach { $0.cancel() }
                            self.versions.removeAll()
                            self.playback.cancelCarPlayRequests()
                            self.pageHistory.removeAll()
                            self.listItems.removeAll()
                            self.queueHistory.removeAll()
                            self.queueOffset = 0
                            self.interface?.popToRootTemplate(animated: false, completion: nil)
                            self.home?.updateSections([])
                            self.downloads?.updateSections([])
                        }
                        self.scheduleLibraryRefresh()
                    }
                })
        }
        refreshPlayback()
        if let downloads { load(downloads, route: .downloaded, title: text("downloaded"), offset: 0) }
    }

    func makeRootTemplate() -> CPTabBarTemplate {
        let home = CPListTemplate(title: text("home"), sections: [])
        home.tabTitle = text("home")
        home.tabImage = UIImage(systemName: "house")
        self.home = home
        let library = CPListTemplate(
            title: text("library"),
            sections: [
                CPListSection(items: [
                    navigation("playlists", route: .playlists), navigation("albums", route: .albums),
                    navigation("artists", route: .artists),
                ])
            ])
        library.tabTitle = text("library")
        library.tabImage = UIImage(systemName: "music.note.list")
        let downloads = CPListTemplate(title: text("downloaded"), sections: [])
        downloads.tabTitle = text("downloaded")
        downloads.tabImage = UIImage(systemName: "arrow.down.circle")
        self.downloads = downloads
        routes[ObjectIdentifier(downloads)] = (.downloaded, text("downloaded"), 0)
        return CPTabBarTemplate(templates: [home, library, downloads])
    }

    public func disconnect() {
        connected = false
        refreshWork?.cancel()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        versions.removeAll()
        routes.removeAll()
        pageHistory.removeAll()
        listItems.removeAll()
        queueHistory.removeAll()
        if let eventToken { playback.unsubscribe(eventToken) }
        eventToken = nil
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        playback.cancelCarPlayRequests()
        CPNowPlayingTemplate.shared.remove(self)
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = false
        interface?.delegate = nil
        interface = nil
        home = nil
        downloads = nil
        snapshot = nil
    }

    public func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        pruneNavigation()
        if let list = aTemplate as? CPListTemplate, let route = routes[ObjectIdentifier(list)] {
            // open() already starts the first load. Do not replace its rows again
            // when the push animation completes or when returning from Now Playing.
            if tasks[ObjectIdentifier(list)] == nil {
                load(list, route: route.0, title: route.1, offset: route.2)
            }
        }
        refreshPlayback()
    }

    private func pruneNavigation() {
        guard let interface else { return }
        var retained = Set(interface.templates.map(ObjectIdentifier.init))
        if let tabs = interface.rootTemplate as? CPTabBarTemplate {
            retained.formUnion(tabs.templates.map(ObjectIdentifier.init))
        }
        for key in Array(listItems.keys) where !retained.contains(key) {
            listItems.removeValue(forKey: key)
        }
        for key in Array(tasks.keys) where !retained.contains(key) {
            tasks.removeValue(forKey: key)?.cancel()
            versions.removeValue(forKey: key)
            routes.removeValue(forKey: key)
            pageHistory.removeValue(forKey: key)
        }
    }

    private func reusableItem(
        _ template: CPListTemplate, key: String, text: String, detail: String? = nil
    ) -> CPListItem {
        let templateKey = ObjectIdentifier(template)
        if let item = listItems[templateKey]?[key] {
            if item.text != text { item.setText(text) }
            if item.detailText != detail { item.setDetailText(detail) }
            return item
        }
        let item = CPListItem(text: text, detailText: detail)
        listItems[templateKey, default: [:]][key] = item
        return item
    }

    private func publish(_ items: [CPListItem], to template: CPListTemplate) {
        let visible = Set(items.map(ObjectIdentifier.init))
        let key = ObjectIdentifier(template)
        listItems[key] = listItems[key]?.filter { visible.contains(ObjectIdentifier($0.value)) }
        let existing = template.sections.flatMap { $0.items }
        let unchanged = existing.count == items.count && zip(existing, items).allSatisfy {
            ($0.0 as? CPListItem) === $0.1
        }
        if !unchanged {
            template.updateSections([CPListSection(items: items)])
            NativeLogger.shared.info("Published list rows=\(items.count)", source: "CarPlay")
        }
    }

    private func navigation(_ key: String, route: CarPlayLibraryRoute) -> CPListItem {
        let item = CPListItem(text: text(key), detailText: nil)
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, done in
            defer { done() }
            self?.open(route, title: self?.text(key) ?? key)
        }
        return item
    }

    private func open(_ route: CarPlayLibraryRoute, title: String, offset: Int = 0) {
        guard connected else { return }
        let template = CPListTemplate(title: title, sections: [])
        routes[ObjectIdentifier(template)] = (route, title, offset)
        push(template)
        load(template, route: route, title: title, offset: offset)
    }

    private func load(_ template: CPListTemplate, route: CarPlayLibraryRoute, title: String, offset: Int) {
        let key = ObjectIdentifier(template)
        tasks[key]?.cancel()
        let version = UUID()
        versions[key] = version
        if template.sections.isEmpty { template.emptyViewTitleVariants = [text("loading")] }
        tasks[key] = Task { [weak self, weak template] in
            guard let self, let template else { return }
            do {
                // Reserve navigation rows before publishing; CarPlay discards overflow.
                let capacity = max(1, CPListTemplate.maximumItemCount)
                let hasPrevious = offset > 0 && capacity >= 3
                let limit = max(1, capacity - (hasPrevious ? 1 : 0))
                let fetched = try await self.library.page(route, offset: offset, limit: limit)
                let hasNext = fetched.nextOffset != nil && capacity >= 2
                let count = max(1, limit - (hasNext ? 1 : 0))
                let page = CarPlayLibraryPage(
                    items: Array(fetched.items.prefix(count)),
                    nextOffset: hasNext ? offset + count : nil)
                try Task.checkCancellation()
                guard self.connected, self.versions[key] == version else { return }
                let items = page.items.map { model -> CPListItem in
                    let item = self.reusableItem(
                        template, key: "content:\(model.songIndex ?? -1):\(model.id)",
                        text: model.title, detail: model.detail)
                    if model.destination != nil { item.accessoryType = .disclosureIndicator }
                    item.isEnabled = model.destination != nil || self.snapshot?.isRemote != true
                    item.handler = { [weak self] _, done in
                        guard let self, self.connected else {
                            done()
                            return
                        }
                        NativeLogger.shared.info("Library item handler entered", source: "CarPlay")
                        if let destination = model.destination {
                            self.open(destination, title: model.title)
                            done()
                        } else if let index = model.songIndex {
                            self.playback.playCarPlayLibrary(
                                route, pageOffset: offset, pageLimit: page.items.count, index: index,
                                expectedId: model.id, sourceName: title
                            ) { [weak self] result in
                                done()
                                guard let self, self.connected else { return }
                                switch result {
                                case .success: self.showNowPlaying()
                                case .failure(let error): if !(error is CancellationError) { self.showError(error) }
                                }
                            }
                        } else {
                            done()
                        }
                    }
                    return item
                }
                var visible = items
                if hasPrevious {
                    let previous = self.reusableItem(template, key: "previous", text: self.text("previousPage"))
                    previous.accessoryType = .disclosureIndicator
                    previous.handler = { [weak self, weak template] _, done in
                        defer { done() }
                        guard let self, let template else { return }
                        let prior = self.pageHistory[key]?.popLast() ?? 0
                        self.routes[key] = (route, title, prior)
                        self.load(template, route: route, title: title, offset: prior)
                    }
                    visible.insert(previous, at: 0)
                }
                if let next = page.nextOffset {
                    let more = self.reusableItem(template, key: "next", text: self.text("more"))
                    more.accessoryType = .disclosureIndicator
                    more.handler = { [weak self, weak template] _, done in
                        defer { done() }
                        guard let self, let template else { return }
                        self.pageHistory[key, default: []].append(offset)
                        self.routes[key] = (route, title, next)
                        self.load(template, route: route, title: title, offset: next)
                    }
                    visible.append(more)
                }
                template.emptyViewTitleVariants = [self.text("empty")]
                self.publish(visible, to: template)
                // Sequential, bounded thumbnail fetches avoid flooding the audio connection pool.
                for (model, item) in zip(page.items, items) {
                    try Task.checkCancellation()
                    guard item.image == nil, let id = model.coverArtId else { continue }
                    guard let data = try? await self.library.coverData(id) else { continue }
                    try Task.checkCancellation()
                    guard self.connected, self.versions[key] == version else { return }
                    if let source = CGImageSourceCreateWithData(data as CFData, nil),
                        let cg = CGImageSourceCreateThumbnailAtIndex(
                            source, 0,
                            [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceThumbnailMaxPixelSize: 128,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                            ] as CFDictionary)
                    {
                        item.setImage(UIImage(cgImage: cg))
                    }
                }
            } catch {
                guard !Task.isCancelled, self.connected, self.versions[key] == version else { return }
                let retry = self.reusableItem(
                    template, key: "retry", text: self.text("retry"), detail: CarPlayText.describe(error))
                retry.handler = { [weak self, weak template] _, done in
                    defer { done() }
                    guard let self, let template else { return }
                    self.load(template, route: route, title: title, offset: offset)
                }
                self.publish([retry], to: template)
            }
        }
    }

    private func refreshPlayback() {
        playback.carPlaySnapshot(
            queueOffset: queueOffset, queueLimit: max(1, CPListTemplate.maximumItemCount)
        ) { [weak self] snapshot in
            guard let self, self.connected else { return }
            if snapshot.queueOffset > 0 && snapshot.queueOffset >= snapshot.queueTotal {
                self.queueOffset = 0
                self.queueHistory.removeAll()
                self.refreshPlayback()
                return
            }
            self.snapshot = snapshot
            self.updateHome(snapshot)
            let nowPlaying = CPNowPlayingTemplate.shared
            nowPlaying.isUpNextButtonEnabled = !snapshot.isRemote && !snapshot.queue.isEmpty
            let shuffle = CPNowPlayingShuffleButton { [weak self] _ in self?.command(.shuffle(!snapshot.shuffle)) }
            let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
                self?.command(
                    .repeatMode(snapshot.repeatMode == "off" ? "all" : snapshot.repeatMode == "all" ? "one" : "off"))
            }
            shuffle.isEnabled = !snapshot.isRemote && !snapshot.queue.isEmpty
            repeatButton.isEnabled = shuffle.isEnabled
            nowPlaying.updateNowPlayingButtons([shuffle, repeatButton])
            self.updateQueue(snapshot)
            if let top = self.interface?.topTemplate as? CPListTemplate,
                self.routes[ObjectIdentifier(top)] != nil
            {
                for section in top.sections {
                    for case let item as CPListItem in section.items {
                        if item.accessoryType == .none { item.isEnabled = !snapshot.isRemote }
                    }
                }
            }
        }
    }

    private func updateHome(_ state: CarPlayPlaybackSnapshot) {
        guard let home else { return }
        guard KeychainManager.exists() else {
            let login = reusableItem(home, key: "login", text: text("login"))
            login.isEnabled = false
            publish([login], to: home)
            return
        }
        let resume = reusableItem(
            home, key: "resume", text: state.isRemote ? text("remote") : text("continue"), detail: state.title)
        resume.isEnabled = !state.isRemote && state.title != nil
        resume.handler = { [weak self] _, done in
            self?.command(.play)
            self?.showNowPlaying()
            done()
        }
        let recent = reusableItem(home, key: "recent", text: text("recent"))
        let favorites = reusableItem(home, key: "favorites", text: text("favorites"))
        for (item, route, title) in [
            (recent, CarPlayLibraryRoute.recent, text("recent")),
            (favorites, CarPlayLibraryRoute.favorites, text("favorites")),
        ] {
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in
                defer { done() }
                self?.open(route, title: title)
            }
        }
        publish([resume, recent, favorites], to: home)
    }

    public func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        queueOffset = 0
        queueHistory.removeAll()
        let template = CPListTemplate(title: text("queue"), sections: [])
        queueTemplate = template
        if let snapshot, snapshot.queueOffset == 0 { updateQueue(snapshot) }
        refreshPlayback()
        push(template)
    }

    private func updateQueue(_ state: CarPlayPlaybackSnapshot) {
        guard let template = queueTemplate else { return }
        let capacity = max(1, CPListTemplate.maximumItemCount)
        let hasPrevious = state.queueOffset > 0 && capacity >= 3
        let available = capacity - (hasPrevious ? 1 : 0)
        let hasNext = state.queueTotal - state.queueOffset > available && capacity >= 2
        let count = max(1, available - (hasNext ? 1 : 0))
        var items = state.queue.prefix(count).map { entry -> CPListItem in
            let item = reusableItem(
                template, key: "queue:\(entry.isUserQueue):\(entry.index):\(entry.id)",
                text: entry.title, detail: entry.artist)
            item.isPlaying = entry.isCurrent
            item.isEnabled = !state.isRemote
            item.handler = { [weak self] _, done in
                guard let self else {
                    done()
                    return
                }
                self.playback.performCarPlay(.queueEntry(entry)) { [weak self] result in
                    done()
                    if case .failure(let error) = result { self?.showError(error) }
                }
            }
            return item
        }
        func pageItem(_ key: String, offset: Int, previous: Bool = false) -> CPListItem {
            let item = reusableItem(template, key: key, text: text(key))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in
                guard let self else {
                    done()
                    return
                }
                if previous {
                    self.queueOffset = self.queueHistory.popLast() ?? 0
                } else {
                    self.queueHistory.append(state.queueOffset)
                    self.queueOffset = offset
                }
                self.refreshPlayback()
                done()
            }
            return item
        }
        if hasPrevious {
            items.insert(pageItem("previousPage", offset: 0, previous: true), at: 0)
        }
        if hasNext {
            items.append(pageItem("more", offset: state.queueOffset + count))
        }
        publish(items, to: template)
    }

    private func command(_ command: CarPlayPlaybackCommand) {
        playback.performCarPlay(command) { [weak self] result in
            Task { @MainActor in
                guard let self, self.connected else { return }
                if case .failure(let error) = result { self.showError(error) }
                self.refreshPlayback()
            }
        }
    }

    private func showNowPlaying() {
        guard interface?.topTemplate !== CPNowPlayingTemplate.shared else { return }
        push(CPNowPlayingTemplate.shared)
    }

    private func push(_ template: CPTemplate) {
        guard let interface else { return }
        // Audio apps have a bounded stack. Return to root before exceeding five levels.
        if interface.templates.count >= 5 {
            interface.popToRootTemplate(animated: false) { [weak self] _, _ in
                guard self?.connected == true else { return }
                interface.pushTemplate(template, animated: true, completion: nil)
            }
        } else {
            interface.pushTemplate(template, animated: true, completion: nil)
        }
    }

    private func showError(_ error: Error) {
        guard connected, interface?.presentedTemplate == nil else { return }
        let close = CPAlertAction(title: text("close"), style: .cancel) { [weak self] _ in
            self?.interface?.dismissTemplate(animated: true, completion: nil)
        }
        interface?.presentTemplate(
            CPAlertTemplate(titleVariants: [CarPlayText.describe(error), text("error")], actions: [close]),
            animated: true,
            completion: nil)
    }

    private func scheduleLibraryRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connected else { return }
            self.refreshPlayback()
            if let downloads = self.downloads {
                self.load(downloads, route: .downloaded, title: self.text("downloaded"), offset: 0)
            }
            if let top = self.interface?.topTemplate as? CPListTemplate,
                let route = self.routes[ObjectIdentifier(top)], top !== self.downloads
            {
                self.load(top, route: route.0, title: route.1, offset: route.2)
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func text(_ key: String) -> String { CarPlayText.text(key) }
}
