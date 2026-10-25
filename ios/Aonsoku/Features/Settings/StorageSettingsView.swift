import AonsokuKit
import SwiftUI

/// Library sync, smart downloads, cache quotas and the cache manager, like
/// the web Offline Experience settings. Library caching is always on, as
/// in the former iOS app.
struct StorageSettingsView: View {
    @State private var pendingClear: ClearTarget?

    @Environment(SettingsStore.self) private var settings
    @Environment(LibrarySyncStore.self) private var sync
    @Environment(DownloadsStore.self) private var downloads
    @Environment(NetworkMonitor.self) private var network
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t
    @Environment(\.locale) private var locale

    /// What a Clear button empties, waiting for confirmation.
    private enum ClearTarget: Hashable {
        case source(CacheSource)
        case covers
        case all
    }

    var body: some View {
        let cache = settings.settings.cache
        ThemedForm {
            librarySync(cache)
            Section {
                Picker(selection: settings.binding(\.cache.downloadConcurrency)) {
                    ForEach(CacheSettings.downloadConcurrencyOptions, id: \.self) { count in
                        Text(String(count)).tag(count)
                    }
                } label: {
                    Text(t("native.settings.downloadConcurrency.label"))
                }
            } footer: {
                Text(t("native.settings.downloadConcurrency.info"))
            }
            smartDownloads(cache.smartRules)
            limits(cache)
            Section {
                NavigationLink(value: SettingsPage.cacheManager) {
                    Text(t("settings.storage.cacheManager.group"))
                }
            } footer: {
                Text(t("settings.storage.cacheManager.description"))
            }
        }
        .navigationTitle(t("settings.options.storage"))
        .task(id: downloads.revision) {
            await downloads.refreshUsage()
        }
        .confirmationDialog(
            pendingClear.map { clearTitle($0) } ?? "",
            isPresented: isConfirmingClear,
            titleVisibility: .visible,
            presenting: pendingClear
        ) { target in
            Button(clearTitle(target), role: .destructive) {
                clear(target)
            }
            Button(t("generic.cancel"), role: .cancel) {}
        }
    }

    // MARK: - Library sync

    private func librarySync(_ cache: CacheSettings) -> some View {
        Section {
            SettingsToggle(
                title: t("settings.storage.sync.libraryCaching"),
                info: t("settings.storage.sync.libraryCachingInfoIos"),
                isOn: .constant(true)
            )
            .disabled(true)
            SettingsToggle(
                title: t("settings.storage.sync.coverArt"),
                info: t("settings.storage.sync.coverArtInfo"),
                isOn: settings.binding(\.cache.syncCoverArt)
            )
            Picker(selection: settings.binding(\.cache.coverArtConcurrency)) {
                ForEach(Array(CacheSettings.coverArtConcurrencyRange), id: \.self) { count in
                    Text(count == 1 ? t("settings.storage.sync.coverArtConcurrencyOff") : String(count))
                        .tag(count)
                }
            } label: {
                Text(t("settings.storage.sync.coverArtConcurrency"))
                Text(t("settings.storage.sync.coverArtConcurrencyInfo"))
            }
            .disabled(!cache.syncCoverArt)
            LabeledContent(t("settings.storage.sync.lastSynced")) {
                if let date = sync.lastSyncedAt {
                    Text(Formatters.relative(date, locale: locale))
                } else {
                    Text(t("settings.storage.sync.never"))
                }
            }
            if sync.isSyncing {
                VStack(alignment: .leading, spacing: 6) {
                    Text(SyncPhaseText.text(sync.phase, t) ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let fraction = sync.phase.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button(t("settings.storage.sync.cancel"), role: .destructive) {
                    sync.cancel()
                }
            } else {
                Button(t("settings.storage.sync.syncNow")) {
                    sync.syncNow()
                }
                .disabled(!network.isOnline)
            }
        } header: {
            Text(t("settings.storage.sync.group"))
        } footer: {
            Text(t("settings.storage.sync.description"))
        }
    }

    // MARK: - Smart downloads

    private func smartDownloads(_ rules: SmartDownloadRules) -> some View {
        Section {
            Toggle(t("settings.storage.smart.enabled"), isOn: settings.binding(\.cache.smartRules.enabled))
            Toggle(t("settings.storage.smart.rule.favoriteSongs"), isOn: settings.binding(\.cache.smartRules.favoriteSongs))
                .disabled(!rules.enabled)
            Toggle(t("settings.storage.smart.rule.favoritePlaylists"), isOn: settings.binding(\.cache.smartRules.favoritePlaylists))
                .disabled(!rules.enabled)
        } header: {
            Text(t("settings.storage.smart.group"))
        } footer: {
            Text(t("settings.storage.smart.description"))
        }
    }

    // MARK: - Limits

    private func limits(_ cache: CacheSettings) -> some View {
        let usage = downloads.usage
        return Section {
            PoolRow(
                title: t(CacheSource.explicit.labelKey),
                description: t(CacheSource.explicit.descriptionKey),
                usage: usage.explicit,
                entries: t("settings.storage.limits.songEntries", ["count": String(usage.explicit.count)])
            ) {
                pendingClear = .source(.explicit)
            }
            PoolRow(
                title: t(CacheSource.smart.labelKey),
                description: t(CacheSource.smart.descriptionKey),
                usage: usage.smart,
                entries: t("settings.storage.limits.songEntries", ["count": String(usage.smart.count)])
            ) {
                pendingClear = .source(.smart)
            }
            PoolRow(
                title: t(CacheSource.lru.labelKey),
                description: t(CacheSource.lru.descriptionKey),
                usage: usage.lru,
                entries: t("settings.storage.limits.songEntries", ["count": String(usage.lru.count)]),
                quota: settings.binding(\.cache.lruQuota)
            ) {
                pendingClear = .source(.lru)
            }
            PoolRow(
                title: t("settings.storage.limits.pool.assets.label"),
                description: t("settings.storage.limits.pool.assets.description"),
                usage: usage.assets,
                entries: t("settings.storage.limits.imageEntries", ["count": String(usage.assets.count)]),
                quota: settings.binding(\.cache.assetsQuota),
                allowsEmptyClear: true
            ) {
                pendingClear = .covers
            }
            Button(t("settings.storage.limits.clearAll"), role: .destructive) {
                pendingClear = .all
            }
        } header: {
            Text(t("settings.storage.limits.group"))
        } footer: {
            Text(t("settings.storage.limits.description"))
        }
    }

    private var isConfirmingClear: Binding<Bool> {
        Binding(
            get: { pendingClear != nil },
            set: { if !$0 { pendingClear = nil } }
        )
    }

    private func clearTitle(_ target: ClearTarget) -> String {
        switch target {
        case let .source(source):
            "\(t("settings.storage.limits.clearAudio")) · \(t(source.labelKey))"
        case .covers:
            "\(t("settings.storage.limits.clearCovers")) · \(t("settings.storage.limits.pool.assets.label"))"
        case .all:
            t("settings.storage.limits.clearAll")
        }
    }

    private func clear(_ target: ClearTarget) {
        pendingClear = nil
        Task {
            switch target {
            case let .source(source):
                await downloads.clear(source: source)
            case .covers:
                await downloads.clearAssets()
            case .all:
                for source in CacheSource.allCases {
                    await downloads.clear(source: source)
                }
                await downloads.clearAssets()
            }
            await downloads.refreshUsage()
            toasts.success(target == .all ? "settings.storage.limits.clearAll" : "settings.storage.limits.clearAudio")
        }
    }
}

/// One cache pool: what it holds, its size, its quota when it has one,
/// and Clear.
private struct PoolRow: View {
    let title: String
    let description: String
    let usage: CachePoolUsage
    let entries: String
    var quota: Binding<Int64>?
    var allowsEmptyClear = false
    let clear: () -> Void

    @Environment(Localizer.self) private var t
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.body.weight(.medium))
                Spacer()
                Button(t("settings.storage.limits.clearAudio"), role: .destructive, action: clear)
                    .buttonStyle(.borderless)
                    .disabled(usage.count == 0 && !allowsEmptyClear)
            }
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("\(Formatters.cacheSize(usage.sizeBytes, locale: locale)) · \(entries)")
                .font(.footnote.weight(.medium))
                .monospacedDigit()
            if let quota {
                Picker(t("settings.storage.limits.quota"), selection: quota) {
                    ForEach(CacheSettings.quotaOptions, id: \.self) { option in
                        Text(option == 0 ? t("settings.storage.limits.unlimited") : Formatters.cacheSize(option, locale: locale))
                            .tag(option)
                    }
                }
                .font(.subheadline)
            } else {
                LabeledContent(t("settings.storage.limits.quota"), value: t("settings.storage.limits.unlimited"))
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Cache manager

/// Every cached file and download marker, filterable and deletable one by
/// one, like the web cache manager.
struct CacheManagerView: View {
    @State private var filter = CacheFilter.all
    @State private var items: [CachedItem] = []
    @State private var phase = LoadPhase.idle
    @State private var pendingDeletion: CachedItem?

    @Environment(DownloadsStore.self) private var downloads
    @Environment(Localizer.self) private var t
    @Environment(\.locale) private var locale

    var body: some View {
        ThemedList {
            if !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        CachedItemRow(item: item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    pendingDeletion = item
                                } label: {
                                    Label(t("settings.storage.cacheManager.list.delete"), systemImage: "trash")
                                }
                                .tint(.red)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDeletion = item
                                } label: {
                                    Label(t("settings.storage.cacheManager.list.delete"), systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(t(
                        "settings.storage.cacheManager.list.total",
                        ["count": Formatters.number(items.count, locale: locale), "size": Formatters.cacheSize(totalBytes, locale: locale)]
                    ))
                }
            }
        }
        .loadStates(phase, isEmpty: items.isEmpty) {
            Task { await load() }
        } empty: {
            EmptyStateView(title: t("settings.storage.cacheManager.list.empty"), systemImage: "internaldrive")
        }
        .navigationTitle(t("settings.storage.cacheManager.group"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(t("album.list.filter.label"), selection: $filter) {
                        ForEach(CacheFilter.allCases) { filter in
                            Text(t(filter.labelKey))
                                .tag(filter)
                        }
                    }
                } label: {
                    Label(t("album.list.filter.label"), systemImage: "line.3.horizontal.decrease")
                }
            }
        }
        .task(id: LoadKey(filter: filter, revision: downloads.revision)) {
            await load()
        }
        .alert(
            t("settings.storage.cacheManager.confirmDelete.title"),
            isPresented: isConfirmingDeletion,
            presenting: pendingDeletion
        ) { item in
            Button(t("settings.storage.cacheManager.list.delete"), role: .destructive) {
                delete(item)
            }
            Button(t("generic.cancel"), role: .cancel) {}
        } message: { item in
            Text(t("settings.storage.cacheManager.confirmDelete.description", ["name": item.name]))
        }
    }

    private struct LoadKey: Equatable {
        var filter: CacheFilter
        var revision: Int
    }

    private var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    private func load() async {
        if items.isEmpty {
            phase = .loading
        }
        items = await downloads.items(filter: filter)
        phase = .loaded
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func delete(_ item: CachedItem) {
        pendingDeletion = nil
        items.removeAll { $0.id == item.id }
        Task { await downloads.delete([item]) }
    }
}

private struct CachedItemRow: View {
    let item: CachedItem

    @Environment(Localizer.self) private var t
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if item.removedFromServer {
                    Label(t("settings.storage.cacheManager.list.removedFromServer"), systemImage: "exclamationmark.icloud")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var symbol: String {
        switch item.type {
        case .audio: "music.note"
        case .cover: "photo"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        }
    }

    /// "Audio · Explicit downloads · 4.2 MB · 3 days ago".
    private var details: String {
        var parts = [t(item.type.labelKey), t(item.source.labelKey)]
        if item.sizeBytes > 0 {
            parts.append(Formatters.cacheSize(item.sizeBytes, locale: locale))
        }
        parts.append(Formatters.relative(item.cachedAt, locale: locale))
        return parts.joined(separator: " · ")
    }
}
