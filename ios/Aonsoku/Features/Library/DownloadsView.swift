import AonsokuKit
import Perception
import SwiftUI

/// Everything downloaded to the device, which plays without a connection:
/// albums, playlists or songs under a segmented control, with the
/// downloads still in progress above them.
struct DownloadsView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case albums
        case playlists
        case songs

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .albums: "sidebar.albums"
            case .playlists: "sidebar.playlists"
            case .songs: "sidebar.songs"
            }
        }
    }

    @State private var kind = Kind.albums

    @Environment(DownloadsStore.self) private var downloads
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            Group {
                switch kind {
                case .albums: DownloadedAlbums()
                case .playlists: DownloadedPlaylists()
                case .songs: DownloadedSongs()
                }
            }
            .safeAreaBar(edge: .top) {
                VStack(spacing: 10) {
                    Picker(t("offline.badge.downloaded"), selection: $kind) {
                        ForEach(Kind.allCases) { kind in
                            WithPerceptionTracking {
                                Text(t(kind.titleKey)).tag(kind)
                            }
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if !downloads.activeDownloads.isEmpty {
                        ActiveDownloadsBar(summary: downloads.activeDownloads) {
                            downloads.cancelAll()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .pageMargins()
                .padding(.bottom, 8)
                .animation(.smooth, value: downloads.activeDownloads.isEmpty)
            }
            .themedBackground()
            .navigationTitle(t("offline.badge.downloaded"))
            // A large title would sit under the blur of the bar holding the
            // picker, so the title stays inline.
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Progress of the downloads in flight, with a button to stop them all.
private struct ActiveDownloadsBar: View {
    let summary: ActiveDownloadsSummary
    let cancel: () -> Void

    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 12) {
                ProgressRing(progress: summary.overallProgress, diameter: 22)
                    .foregroundStyle(.tint)
                Text(t("settings.storage.sync.downloading", count: summary.activeCount))
                    .font(.subheadline.weight(.medium))
                    .appNumericTransition()
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(t("generic.cancel"), action: cancel)
                    .appGlassButtonStyle()
                    .controlSize(.small)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .appGlass(in: .capsule)
            .animation(.smooth, value: summary.activeCount)
        }
    }
}

private struct DownloadedAlbums: View {
    @Environment(DownloadsStore.self) private var downloads
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            DownloadedItems(emptyTitle: t("native.downloads.noAlbums"), systemImage: "square.stack") {
                await downloads.downloadedAlbums()
            } content: { albums in
                ScrollView {
                    TileGrid {
                        WithPerceptionTracking {
                            ForEach(albums) { album in
                                WithPerceptionTracking {
                                    AlbumTile(album: album)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
        }
    }
}

private struct DownloadedPlaylists: View {
    @Environment(DownloadsStore.self) private var downloads
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            DownloadedItems(emptyTitle: t("native.downloads.noPlaylists"), systemImage: "music.note.list") {
                await downloads.downloadedPlaylists()
            } content: { playlists in
                ScrollView {
                    TileGrid {
                        WithPerceptionTracking {
                            ForEach(playlists) { playlist in
                                WithPerceptionTracking {
                                    PlaylistTile(playlist: playlist)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
        }
    }
}

private struct DownloadedSongs: View {
    @Environment(PlayerStore.self) private var player
    @Environment(DownloadsStore.self) private var downloads
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            DownloadedItems(emptyTitle: t("native.downloads.noSongs"), systemImage: "music.note") {
                await downloads.downloadedSongs()
            } content: { songs in
                List {
                    if !songs.isEmpty {
                        PlayShuffleButtons {
                            player.play(songs, sourceName: title)
                        } shuffle: {
                            player.play(songs, shuffle: true, sourceName: title)
                        }
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)
                        .themedRow(plain: true)
                    }
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        WithPerceptionTracking {
                            SongRow(song: song, isFirst: index == 0, isLast: index == songs.count - 1) {
                                player.play(songs, startingAt: index, sourceName: title)
                            }
                            .swipeActions(edge: .trailing) {
                                // The row leaves when the download index changes.
                                Button {
                                    Task { await downloads.remove(songIds: [song.id]) }
                                } label: {
                                    Label(t("options.removeDownload"), systemImage: "trash")
                                }
                                .tint(.red)
                            }
                            .themedRow(plain: true)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var title: String {
        t("offline.badge.downloaded")
    }
}

/// Loads a list from the download index, again whenever the index changes,
/// and shows `content` with the loading and empty states over it.
private struct DownloadedItems<Item: Sendable, Content: View>: View {
    let emptyTitle: String
    let systemImage: String
    let load: () async -> [Item]
    @ViewBuilder let content: ([Item]) -> Content

    @State private var items: [Item]?

    @Environment(DownloadsStore.self) private var downloads
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            content(items ?? [])
                .loadStates(items == nil ? .loading : .loaded, isEmpty: items?.isEmpty ?? true) {
                    // Reading the index does not fail.
                } empty: {
                    EmptyStateView(
                        title: emptyTitle,
                        systemImage: systemImage,
                        description: t("native.downloads.description")
                    )
                }
                .task(id: downloads.revision) {
                    items = await load()
                }
        }
    }
}
