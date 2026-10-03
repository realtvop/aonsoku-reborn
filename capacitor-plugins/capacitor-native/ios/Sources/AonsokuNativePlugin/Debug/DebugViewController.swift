import UIKit
import AVFoundation

public final class DebugViewController: UIViewController {
    private let dataProvider: DebugDataProvider
    private var refreshTimer: Timer?
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let segmentedControl = UISegmentedControl(items: ["Playback", "Info", "Logs"])
    private let searchBar = UISearchBar()
    private let filterStack = UIStackView()
    private var filterScrollView: UIScrollView!

    private var tableTopToSegment: NSLayoutConstraint!
    private var tableTopToFilter: NSLayoutConstraint!

    private enum Tab: Int { case playback, info, logs }
    private var currentTab: Tab = .playback

    private var audioSnapshot: AudioDebugSnapshot?
    private var connectionSnapshot: ConnectionDebugSnapshot?
    private var sessionSnapshot: AudioSessionSnapshot?
    private var memoryMB: Double = 0
    private var logEntries: [NativeLogger.Entry] = []
    private var filteredLogEntries: [NativeLogger.Entry] = []

    private var searchText: String = ""
    private var activeLevels: Set<NativeLogger.Entry.Level> = [.debug, .info, .warn, .error]
    private var activeSources: Set<String> = []
    private var allSources: [String] = []
    private var isSelectingLogs = false
    private var selectedLogIndices: Set<Int> = []

    public init(audioService: AudioService = AppServices.shared.audio) {
        self.dataProvider = DebugDataProvider(audioService: audioService)
        super.init(nibName: nil, bundle: nil)
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Debug"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(closeTapped)
        )

        setupSegmentedControl()
        setupSearchAndFilter()
        setupTableView()
        updateNavBarForTab()
        refreshData()
        startAutoRefresh()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    private func setupSegmentedControl() {
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(segmentedControl)
        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            segmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            segmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }

    private func setupSearchAndFilter() {
        searchBar.placeholder = "Search logs..."
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.isHidden = true
        view.addSubview(searchBar)

        filterStack.axis = .horizontal
        filterStack.spacing = 6
        filterStack.translatesAutoresizingMaskIntoConstraints = false

        filterScrollView = UIScrollView()
        filterScrollView.translatesAutoresizingMaskIntoConstraints = false
        filterScrollView.showsHorizontalScrollIndicator = false
        filterScrollView.addSubview(filterStack)
        filterScrollView.isHidden = true
        view.addSubview(filterScrollView)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 4),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            filterScrollView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            filterScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            filterScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            filterScrollView.heightAnchor.constraint(equalToConstant: 32),

            filterStack.topAnchor.constraint(equalTo: filterScrollView.topAnchor),
            filterStack.leadingAnchor.constraint(equalTo: filterScrollView.leadingAnchor),
            filterStack.trailingAnchor.constraint(equalTo: filterScrollView.trailingAnchor),
            filterStack.bottomAnchor.constraint(equalTo: filterScrollView.bottomAnchor),
            filterStack.heightAnchor.constraint(equalTo: filterScrollView.heightAnchor),
        ])
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "kv")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "log")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "controls")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 32
        tableView.sectionHeaderTopPadding = 4
        tableView.keyboardDismissMode = .onDrag
        view.addSubview(tableView)

        tableTopToSegment = tableView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8)
        tableTopToFilter = tableView.topAnchor.constraint(equalTo: filterScrollView.bottomAnchor, constant: 4)
        tableTopToSegment.isActive = true

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
    }

    private func refreshData() {
        audioSnapshot = dataProvider.audioSnapshot()
        connectionSnapshot = dataProvider.connectionSnapshot()
        sessionSnapshot = dataProvider.audioSessionSnapshot()
        memoryMB = dataProvider.memoryUsageMB()
        logEntries = NativeLogger.shared.getEntries().reversed()
        updateSources()
        applyLogFilter()
        tableView.reloadData()
    }

    @objc private func closeTapped() { dismiss(animated: true) }
    @objc private func refreshTapped() { refreshData() }

    @objc private func tabChanged() {
        currentTab = Tab(rawValue: segmentedControl.selectedSegmentIndex) ?? .playback
        let showLogFilters = currentTab == .logs
        searchBar.isHidden = !showLogFilters
        filterScrollView.isHidden = !showLogFilters
        tableTopToSegment.isActive = !showLogFilters
        tableTopToFilter.isActive = showLogFilters
        exitSelectionMode()
        updateNavBarForTab()
        tableView.reloadData()
    }

    private func updateNavBarForTab() {
        if currentTab == .logs && isSelectingLogs {
            let count = selectedLogIndices.count
            navigationItem.rightBarButtonItems = [
                UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(exitSelectMode)),
            ]
            title = count > 0 ? "Selected \(count)" : "Select Entries"
        } else {
            navigationItem.rightBarButtonItems = [
                UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(refreshTapped)),
            ]
            title = "Debug"
        }
    }

    @objc private func exitSelectMode() {
        exitSelectionMode()
        updateNavBarForTab()
        tableView.reloadData()
    }

    private func enterSelectionMode() {
        isSelectingLogs = true
        selectedLogIndices.removeAll()
        tableView.allowsMultipleSelection = true
        updateNavBarForTab()
        tableView.reloadData()
    }

    private func exitSelectionMode() {
        isSelectingLogs = false
        selectedLogIndices.removeAll()
        tableView.allowsMultipleSelection = false
    }

    private func copyEntries(_ indices: [Int]) {
        let text = indices.sorted().map { idx -> String in
            let entry = filteredLogEntries[idx]
            let time = Self.copyTimeFormatter.string(from: entry.timestamp)
            let src = entry.source.isEmpty ? "" : "[\(entry.source)] "
            return "\(time) \(entry.level.rawValue.uppercased()) \(src)\(entry.message)"
        }.joined(separator: "\n")
        UIPasteboard.general.string = text
    }

    private func formatEntryForCopy(_ entry: NativeLogger.Entry) -> String {
        let time = Self.copyTimeFormatter.string(from: entry.timestamp)
        let src = entry.source.isEmpty ? "" : "[\(entry.source)] "
        return "\(time) \(entry.level.rawValue.uppercased()) \(src)\(entry.message)"
    }

    private static let copyTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private func updateSources() {
        let sources = Set(logEntries.compactMap { $0.source.isEmpty ? nil : $0.source })
        let sorted = sources.sorted()
        if sorted != allSources {
            allSources = sorted
            if activeSources.isEmpty { activeSources = sources }
            rebuildFilterChips()
        }
    }

    private func applyLogFilter() {
        filteredLogEntries = logEntries.filter { entry in
            guard activeLevels.contains(entry.level) else { return false }
            if !activeSources.isEmpty && !entry.source.isEmpty {
                guard activeSources.contains(entry.source) else { return false }
            }
            if !searchText.isEmpty {
                let haystack = "\(entry.source) \(entry.message)".lowercased()
                guard haystack.contains(searchText.lowercased()) else { return false }
            }
            return true
        }
    }

    private func rebuildFilterChips() {
        filterStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for level in NativeLogger.Entry.Level.allCases {
            let btn = makeChip(title: level.rawValue.uppercased(), isActive: activeLevels.contains(level))
            btn.tag = level.hashValue
            btn.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if self.activeLevels.contains(level) {
                    self.activeLevels.remove(level)
                } else {
                    self.activeLevels.insert(level)
                }
                self.rebuildFilterChips()
                self.applyLogFilter()
                self.tableView.reloadData()
            }, for: .touchUpInside)
            filterStack.addArrangedSubview(btn)
        }

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.backgroundColor = .separator
        filterStack.addArrangedSubview(separator)

        for source in allSources {
            let btn = makeChip(title: source, isActive: activeSources.contains(source))
            btn.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if self.activeSources.contains(source) {
                    self.activeSources.remove(source)
                } else {
                    self.activeSources.insert(source)
                }
                self.rebuildFilterChips()
                self.applyLogFilter()
                self.tableView.reloadData()
            }, for: .touchUpInside)
            filterStack.addArrangedSubview(btn)
        }
    }

    private func makeChip(title: String, isActive: Bool) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .capsule
        config.buttonSize = .mini
        config.baseBackgroundColor = isActive ? .systemBlue : .systemGray5
        config.baseForegroundColor = isActive ? .white : .secondaryLabel
        config.contentInsets = .init(top: 4, leading: 8, bottom: 4, trailing: 8)
        let btn = UIButton(configuration: config)
        return btn
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func kvCell(_ tableView: UITableView, key: String, value: String, color: UIColor = .label) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "kv")!
        var config = UIListContentConfiguration.valueCell()
        config.text = key
        config.secondaryText = value
        config.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        config.textProperties.color = .secondaryLabel
        config.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        config.secondaryTextProperties.color = color
        config.directionalLayoutMargins = .init(top: 6, leading: 16, bottom: 6, trailing: 16)
        cell.contentConfiguration = config
        cell.selectionStyle = .none
        return cell
    }
}

// MARK: - UITableViewDataSource

extension DebugViewController: UITableViewDataSource, UITableViewDelegate {
    public func numberOfSections(in tableView: UITableView) -> Int {
        switch currentTab {
        case .playback: return 3
        case .info: return 3
        case .logs: return 1
        }
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch currentTab {
        case .playback:
            switch section {
            case 0: return "NOW PLAYING"
            case 1: return "QUEUE (\(audioSnapshot?.queueItemCount ?? 0))"
            case 2: return audioSnapshot?.userQueue.isEmpty == false ? "USER QUEUE (\(audioSnapshot?.userQueue.count ?? 0))" : nil
            default: return nil
            }
        case .info:
            switch section {
            case 0: return "BUFFER"
            case 1: return "CONNECTION"
            case 2: return "AUDIO SESSION"
            default: return nil
            }
        case .logs:
            return "LOGS (\(filteredLogEntries.count)/\(logEntries.count))"
        }
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch currentTab {
        case .playback:
            switch section {
            case 0: return 4
            case 1: return max(audioSnapshot?.queue.count ?? 0, 1)
            case 2: return audioSnapshot?.userQueue.count ?? 0
            default: return 0
            }
        case .info:
            switch section {
            case 0: return 3
            case 1: return connectionSnapshot != nil ? 4 : 1
            case 2: return 4
            default: return 0
            }
        case .logs:
            return max(filteredLogEntries.count, 1)
        }
    }
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch currentTab {
        case .playback: return playbackTabCell(tableView, section: indexPath.section, row: indexPath.row)
        case .info: return infoTabCell(tableView, section: indexPath.section, row: indexPath.row)
        case .logs: return logCell(tableView, row: indexPath.row)
        }
    }

    // MARK: - Playback Tab

    private func playbackTabCell(_ tableView: UITableView, section: Int, row: Int) -> UITableViewCell {
        switch section {
        case 0: return nowPlayingCell(tableView, row: row)
        case 1: return queueCell(tableView, row: row, items: audioSnapshot?.queue ?? [])
        case 2: return queueCell(tableView, row: row, items: audioSnapshot?.userQueue ?? [])
        default: return kvCell(tableView, key: "", value: "")
        }
    }

    private func nowPlayingCell(_ tableView: UITableView, row: Int) -> UITableViewCell {
        let snap = audioSnapshot
        switch row {
        case 0:
            let title = snap?.title ?? "(idle)"
            let artist = snap?.artist ?? ""
            let display = artist.isEmpty ? title : "\(title) — \(artist)"
            return kvCell(tableView, key: "Track", value: display)
        case 1:
            let cur = formatTime(snap?.currentTime ?? 0)
            let dur = formatTime(snap?.duration ?? 0)
            let buf = formatTime(snap?.bufferedTime ?? 0)
            return kvCell(tableView, key: "Time", value: "\(cur) / \(dur)  buf:\(buf)")
        case 2:
            let kind = snap?.sourceKind ?? "none"
            let r = snap?.repeatMode ?? "off"
            let s = snap?.shuffleEnabled == true ? "on" : "off"
            return kvCell(tableView, key: "Mode", value: "\(kind) repeat:\(r) shuffle:\(s)")
        case 3:
            return controlsCell(tableView)
        default:
            return kvCell(tableView, key: "", value: "")
        }
    }

    private func controlsCell(_ tableView: UITableView) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "controls")!
        cell.selectionStyle = .none
        for v in cell.contentView.subviews { v.removeFromSuperview() }

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        let prev = UIButton(type: .system)
        prev.setImage(UIImage(systemName: "backward.fill"), for: .normal)
        prev.addTarget(self, action: #selector(prevTapped), for: .touchUpInside)

        let playPause = UIButton(type: .system)
        let isPlaying = audioSnapshot?.isPlaying == true
        playPause.setImage(UIImage(systemName: isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        playPause.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)

        let next = UIButton(type: .system)
        next.setImage(UIImage(systemName: "forward.fill"), for: .normal)
        next.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)

        for btn in [prev, playPause, next] {
            btn.configuration = .plain()
            btn.configuration?.preferredSymbolConfigurationForImage = .init(pointSize: 22)
        }

        stack.addArrangedSubview(prev)
        stack.addArrangedSubview(playPause)
        stack.addArrangedSubview(next)

        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: cell.contentView.centerXAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
            stack.widthAnchor.constraint(equalToConstant: 180),
        ])
        return cell
    }

    private func queueCell(_ tableView: UITableView, row: Int, items: [QueueItemInfo]) -> UITableViewCell {
        guard !items.isEmpty else {
            return kvCell(tableView, key: "", value: "empty", color: .secondaryLabel)
        }
        let item = items[row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "kv")!
        var config = UIListContentConfiguration.valueCell()
        let prefix = item.isCurrent ? "▶ " : "  "
        config.text = "\(prefix)\(item.title)"
        config.secondaryText = formatTime(item.duration)
        config.textProperties.font = .systemFont(ofSize: 13, weight: item.isCurrent ? .semibold : .regular)
        config.textProperties.color = item.isCurrent ? .systemBlue : .label
        config.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        config.secondaryTextProperties.color = .secondaryLabel
        config.directionalLayoutMargins = .init(top: 4, leading: 16, bottom: 4, trailing: 16)
        cell.contentConfiguration = config
        cell.selectionStyle = .none
        return cell
    }

    @objc private func prevTapped() { dataProvider.skipPrevious(); refreshData() }
    @objc private func playPauseTapped() { dataProvider.playPause(); refreshData() }
    @objc private func nextTapped() { dataProvider.skipNext(); refreshData() }
    // MARK: - Info Tab

    private func infoTabCell(_ tableView: UITableView, section: Int, row: Int) -> UITableViewCell {
        switch section {
        case 0: return bufferCell(tableView, row: row)
        case 1: return connectionCell(tableView, row: row)
        case 2: return audioSessionCell(tableView, row: row)
        default: return kvCell(tableView, key: "", value: "")
        }
    }

    private func bufferCell(_ tableView: UITableView, row: Int) -> UITableViewCell {
        let snap = audioSnapshot
        switch row {
        case 0:
            let empty = snap?.bufferEmpty == true
            let keepUp = snap?.likelyToKeepUp == true
            let status = empty ? "EMPTY" : (keepUp ? "OK" : "LOW")
            let color: UIColor = empty ? .systemRed : (keepUp ? .systemGreen : .systemOrange)
            return kvCell(tableView, key: "Status", value: status, color: color)
        case 1:
            return kvCell(tableView, key: "Buffered", value: formatTime(snap?.bufferedTime ?? 0))
        case 2:
            let state = snap?.recoveryState ?? "idle"
            let color: UIColor = state == "idle" ? .label : .systemOrange
            return kvCell(tableView, key: "Recovery", value: state, color: color)
        default:
            return kvCell(tableView, key: "", value: "")
        }
    }

    private func connectionCell(_ tableView: UITableView, row: Int) -> UITableViewCell {
        guard let snap = connectionSnapshot else {
            return kvCell(tableView, key: "Status", value: "no credentials", color: .secondaryLabel)
        }
        switch row {
        case 0: return kvCell(tableView, key: "Server", value: snap.serverUrl)
        case 1: return kvCell(tableView, key: "User", value: snap.username)
        case 2: return kvCell(tableView, key: "Auth", value: "\(snap.authType) · \(snap.protocolVersion)")
        case 3: return kvCell(tableView, key: "Type", value: "\(snap.serverType)\(snap.hasFallbackUrl ? " +fallback" : "")")
        default: return kvCell(tableView, key: "", value: "")
        }
    }

    private func audioSessionCell(_ tableView: UITableView, row: Int) -> UITableViewCell {
        let snap = sessionSnapshot ?? dataProvider.audioSessionSnapshot()
        switch row {
        case 0: return kvCell(tableView, key: "Category", value: "\(snap.category) / \(snap.mode)")
        case 1:
            let vol = String(format: "%.0f%%", snap.outputVolume * 100)
            let rate = String(format: "%.0fHz", snap.sampleRate)
            return kvCell(tableView, key: "Output", value: "\(vol) · \(rate)")
        case 2:
            let latency = String(format: "%.1fms", snap.outputLatency * 1000)
            let buf = String(format: "%.1fms", snap.ioBufferDuration * 1000)
            return kvCell(tableView, key: "Latency", value: "\(latency) buf:\(buf)")
        case 3: return kvCell(tableView, key: "Memory", value: String(format: "%.1f MB", memoryMB))
        default: return kvCell(tableView, key: "", value: "")
        }
    }

    // MARK: - Logs Tab

    private func logCell(_ tableView: UITableView, row: Int) -> UITableViewCell {
        guard !filteredLogEntries.isEmpty else {
            return kvCell(tableView, key: "", value: "no entries", color: .secondaryLabel)
        }
        let entry = filteredLogEntries[row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "log")!
        var config = UIListContentConfiguration.subtitleCell()
        let time = Self.timeFormatter.string(from: entry.timestamp)
        let src = entry.source.isEmpty ? "" : "[\(entry.source)] "
        config.text = "\(time) \(entry.level.rawValue.uppercased()) \(src)"
        config.textProperties.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        config.secondaryText = entry.message
        config.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        config.secondaryTextProperties.numberOfLines = 2
        config.directionalLayoutMargins = .init(top: 4, leading: 16, bottom: 4, trailing: 16)

        switch entry.level {
        case .error: config.textProperties.color = .systemRed
        case .warn: config.textProperties.color = .systemOrange
        case .debug: config.textProperties.color = .tertiaryLabel
        case .info: config.textProperties.color = .secondaryLabel
        }
        config.secondaryTextProperties.color = .label

        cell.contentConfiguration = config
        cell.selectionStyle = isSelectingLogs ? .default : .none
        cell.accessoryType = (isSelectingLogs && selectedLogIndices.contains(row)) ? .checkmark : .none
        return cell
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard currentTab == .logs, !filteredLogEntries.isEmpty, !isSelectingLogs else { return nil }
        let button = UIButton(type: .system)
        button.setTitle("Clear", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13)
        button.addTarget(self, action: #selector(clearLogsTapped), for: .touchUpInside)
        let container = UIView()
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return container
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard currentTab == .logs, !filteredLogEntries.isEmpty, isSelectingLogs else { return }

        if selectedLogIndices.contains(indexPath.row) {
            selectedLogIndices.remove(indexPath.row)
        } else {
            selectedLogIndices.insert(indexPath.row)
        }
        updateNavBarForTab()
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    public func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard currentTab == .logs, !filteredLogEntries.isEmpty else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }

            if self.isSelectingLogs && self.selectedLogIndices.contains(indexPath.row) {
                let count = self.selectedLogIndices.count
                let copySelected = UIAction(
                    title: "Copy \(count) Selected",
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    self.copyEntries(Array(self.selectedLogIndices))
                    self.exitSelectionMode()
                    self.updateNavBarForTab()
                    self.tableView.reloadData()
                }
                let selectAll = UIAction(
                    title: "Select All",
                    image: UIImage(systemName: "checkmark.circle")
                ) { _ in
                    self.selectedLogIndices = Set(0..<self.filteredLogEntries.count)
                    self.updateNavBarForTab()
                    self.tableView.reloadData()
                }
                let deselect = UIAction(
                    title: "Cancel Selection",
                    image: UIImage(systemName: "xmark.circle"),
                    attributes: .destructive
                ) { _ in
                    self.exitSelectionMode()
                    self.updateNavBarForTab()
                    self.tableView.reloadData()
                }
                return UIMenu(children: [copySelected, selectAll, deselect])
            } else {
                let copy = UIAction(
                    title: "Copy",
                    image: UIImage(systemName: "doc.on.clipboard")
                ) { _ in
                    let entry = self.filteredLogEntries[indexPath.row]
                    UIPasteboard.general.string = self.formatEntryForCopy(entry)
                }
                let selectMultiple = UIAction(
                    title: "Select Multiple",
                    image: UIImage(systemName: "checkmark.circle")
                ) { _ in
                    self.enterSelectionMode()
                    self.selectedLogIndices.insert(indexPath.row)
                    self.updateNavBarForTab()
                    self.tableView.reloadData()
                }
                return UIMenu(children: [copy, selectMultiple])
            }
        }
    }

    public func tableView(
        _ tableView: UITableView,
        previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        return nil
    }

    public func tableView(
        _ tableView: UITableView,
        previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        return nil
    }

    @objc private func clearLogsTapped() {
        NativeLogger.shared.clear()
        refreshData()
    }
}

// MARK: - UISearchBarDelegate

extension DebugViewController: UISearchBarDelegate {
    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.searchText = searchText
        applyLogFilter()
        tableView.reloadData()
    }

    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
