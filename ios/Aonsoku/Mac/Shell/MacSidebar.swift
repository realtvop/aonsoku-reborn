import AonsokuKit
import Perception
import SwiftUI

/// The Mac window's sidebar: Home and Search, the library's sections, what
/// is pinned to Home and the user's playlists, with the library sync's
/// progress at the bottom while it runs.
struct MacSidebar: View {
    @Environment(Router.self) private var router
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(PinnedHomeStore.self) private var pinned
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            List(selection: selection) {
                Section {
                    row(.home, t("sidebar.home"), systemImage: "house")
                    row(.search, t("sidebar.miniSearch"), systemImage: "magnifyingglass")
                }
                Section(t("sidebar.library")) {
                    row(.albums, t("sidebar.albums"), systemImage: "square.stack")
                    row(.artists, t("sidebar.artists"), systemImage: "music.mic")
                    row(.songs, t("sidebar.songs"), systemImage: "music.note")
                    row(.playlists, t("sidebar.playlists"), systemImage: "music.note.list")
                    row(.genres, t("table.columns.genres"), systemImage: "guitars")
                    row(.favorites, t("sidebar.favorites"), systemImage: "heart")
                    if !settings.settings.content.hideRadiosSection {
                        row(.radios, t("sidebar.radios"), systemImage: "dot.radiowaves.left.and.right")
                    }
                    row(.downloads, t("offline.badge.downloaded"), systemImage: "arrow.down.circle")
                }
                if !pinned.resolved.isEmpty {
                    Section(t("home.pinned")) {
                        ForEach(pinned.resolved) { content in
                            WithPerceptionTracking {
                                SidebarPinnedRow(content: content)
                            }
                        }
                    }
                }
                Section {
                    ForEach(playlists.playlists) { playlist in
                        WithPerceptionTracking {
                            SidebarPlaylistRow(playlist: playlist)
                        }
                    }
                } header: {
                    HStack {
                        Text(t("sidebar.playlists"))
                        Spacer()
                        Button {
                            router.present(.createPlaylist(songs: []))
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help(t("options.playlist.create"))
                        .accessibilityLabel(t("options.playlist.create"))
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                WithPerceptionTracking {
                    SidebarSyncFooter()
                }
            }
        }
    }

    /// Clicking a row selects its section; the section keeps its pages.
    private var selection: Binding<SidebarSection?> {
        Binding(
            get: { router.section },
            set: { if let section = $0 { router.section = section } }
        )
    }

    private func row(_ section: SidebarSection, _ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .tag(section)
    }
}

/// An album or playlist pinned to Home.
private struct SidebarPinnedRow: View {
    let content: PinnedContent

    var body: some View {
        WithPerceptionTracking {
            switch content {
            case let .album(album):
                label(album.name, coverArt: album.coverArt, placeholder: "square.stack")
                    .tag(SidebarSection.pinned(PinnedItem(itemId: album.id, kind: .album)))
                    .contextMenu { AlbumMenuItems(album: album) }
            case let .playlist(playlist):
                label(playlist.name, coverArt: playlist.coverArt, placeholder: "music.note.list")
                    .tag(SidebarSection.pinned(PinnedItem(itemId: playlist.id, kind: .playlist)))
                    .contextMenu { PlaylistMenuItems(playlist: playlist) }
            }
        }
    }

    private func label(_ title: String, coverArt: String?, placeholder: String) -> some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            ArtworkImage(id: coverArt, size: .small, cornerRadius: 3, placeholder: placeholder)
                .frame(width: 18, height: 18)
        }
    }
}

/// One of the user's playlists. Songs dropped on it are added to it.
private struct SidebarPlaylistRow: View {
    let playlist: Playlist

    @Environment(PlaylistsStore.self) private var playlists
    @Environment(SessionStore.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @State private var isTargeted = false

    var body: some View {
        WithPerceptionTracking {
            Label(playlist.name, systemImage: "music.note.list")
                .lineLimit(1)
                .tag(SidebarSection.playlist(id: playlist.id))
                .contextMenu { PlaylistMenuItems(playlist: playlist) }
                .dropDestination(for: MacSongTransfer.self) { items, _ in
                    guard playlist.isOwned(by: session.account?.username) else { return false }
                    let ids = items.flatMap(\.songIds)
                    guard !ids.isEmpty else { return false }
                    Task { await add(ids) }
                    return true
                } isTargeted: { isTargeted = $0 }
                .listRowBackground(
                    isTargeted ? RoundedRectangle(cornerRadius: 5).fill(.tint.opacity(0.25)) : nil
                )
        }
    }

    /// Adds the songs, saying which were already in the playlist, as Add
    /// to Playlist does.
    private func add(_ ids: [String]) async {
        do {
            let skipped = Set(try await playlists.add(songIds: ids, to: playlist.id))
            let name = ["name": playlist.name]
            if skipped.isSuperset(of: ids) {
                toasts.show(.key("native.playlist.alreadyAdded", name), style: .info, systemImage: "checkmark.circle")
            } else if !skipped.isEmpty {
                toasts.success("native.playlist.addedSkipped", name)
            } else {
                toasts.success("native.playlist.added", name)
            }
        } catch {
            toasts.show(error: error, fallbackKey: "native.playlist.addFailed")
        }
    }
}

/// The library sync's progress while it runs.
private struct SidebarSyncFooter: View {
    @Environment(LibrarySyncStore.self) private var sync
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            if sync.isSyncing, let text = SyncPhaseText.text(sync.phase, t, operation: sync.operation) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let fraction = sync.phase.fraction {
                        ProgressView(value: fraction)
                            .controlSize(.small)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
