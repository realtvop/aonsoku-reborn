import AonsokuKit
import SwiftUI

/// Adds songs to one of the user's playlists, or to a new one.
struct AddToPlaylistView: View {
    let songs: [Song]

    @State private var searchText = ""
    /// The playlist being added to, while the server works.
    @State private var addingTo: String?

    @Environment(Router.self) private var router
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(SessionStore.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !isSearching {
                    NewPlaylistRow {
                        router.present(.createPlaylist(songs: songs))
                    }
                }
                ForEach(filtered) { playlist in
                    Button {
                        add(to: playlist)
                    } label: {
                        PlaylistChoiceRow(playlist: playlist, isAdding: addingTo == playlist.id)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .disabled(addingTo != nil)
            .overlay {
                if owned.isEmpty {
                    switch playlists.phase {
                    case .idle, .loading:
                        LoadingStateView()
                    case let .failed(message):
                        ErrorStateView(message: message) {
                            Task { await playlists.reload() }
                        }
                    case .loaded:
                        EmptyView()
                    }
                } else if isSearching, filtered.isEmpty {
                    EmptyStateView(title: t("options.playlist.notFound"), systemImage: "magnifyingglass")
                }
            }
            .themedBackground()
            .navigationTitle(t("options.playlist.add"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(t("options.playlist.search"))
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await playlists.loadIfNeeded()
        }
    }

    /// Only the user's own playlists can be changed.
    private var owned: [Playlist] {
        playlists.playlists.filter { $0.isOwned(by: session.account?.username) }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedSearch.isEmpty
    }

    private var filtered: [Playlist] {
        guard isSearching else { return owned }
        return owned.filter { $0.name.localizedStandardContains(trimmedSearch) }
    }

    private func add(to playlist: Playlist) {
        let ids = songs.map(\.id)
        guard !ids.isEmpty, addingTo == nil else { return }
        addingTo = playlist.id
        Task {
            defer { addingTo = nil }
            do {
                let skipped = Set(try await playlists.add(songIds: ids, to: playlist.id))
                let name = ["name": playlist.name]
                if skipped.isSuperset(of: ids) {
                    toasts.show(
                        .key("native.playlist.alreadyAdded", name),
                        style: .info,
                        systemImage: "checkmark.circle"
                    )
                } else if !skipped.isEmpty {
                    toasts.success("native.playlist.addedSkipped", name)
                } else {
                    toasts.success("native.playlist.added", name)
                }
                dismiss()
            } catch {
                toasts.show(error: error, fallbackKey: "native.playlist.addFailed")
            }
        }
    }
}

/// A playlist to add to: cover, name and length.
private struct PlaylistChoiceRow: View {
    let playlist: Playlist
    let isAdding: Bool

    @Environment(Localizer.self) private var t

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(id: playlist.coverArt, size: .small, cornerRadius: 6, placeholder: "music.note.list")
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(t("playlist.songCount", count: playlist.songCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isAdding {
                ProgressView()
            }
        }
        .contentShape(.rect)
    }
}
