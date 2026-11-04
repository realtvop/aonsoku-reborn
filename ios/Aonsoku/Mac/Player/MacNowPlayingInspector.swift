import AonsokuKit
import Perception
import SwiftUI

/// Now Playing beside the content, as the window's inspector: the playing
/// song's lyrics or the queue, over the player background tinted with the
/// cover, as in the iOS full-screen player. Radio has neither, so a station
/// shows its badge instead.
struct MacNowPlayingInspector: View {
    @Environment(PlayerStore.self) private var player
    @Environment(LyricsStore.self) private var lyrics
    @Environment(SettingsStore.self) private var settings
    @Environment(Router.self) private var router

    @AppStorage(MacInspectorPanel.storageKey) private var panel = MacInspectorPanel.lyrics
    @State private var palette: ArtworkPalette?

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                NowPlayingBackground()
                VStack(spacing: 0) {
                    MacInspectorHeader(panel: $panel)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .environment(\.nowPlayingPalette, palette)
            .artworkPalette(coverArtId, into: $palette)
            .task(id: router.isNowPlayingPresented ? player.currentSong?.id : nil) {
                guard router.isNowPlayingPresented else { return }
                await lyrics.load(for: player.currentSong)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if player.isRadio {
            MacRadioNowPlaying()
        } else {
            switch panel {
            case .lyrics:
                LyricsPanel(isActive: router.isNowPlayingPresented)
            case .queue:
                MacQueueList()
            }
        }
    }

    private var coverArtId: String? {
        player.currentSong?.coverArtId(preferAlbum: settings.settings.playback.useAlbumCoverForSongs)
    }
}

/// Lyrics or Queue, and the playing song's lyrics settings.
private struct MacInspectorHeader: View {
    @Binding var panel: MacInspectorPanel

    @Environment(PlayerStore.self) private var player
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            Picker(t("native.mac.inspector.title"), selection: $panel) {
                Text(t("fullscreen.lyrics")).tag(MacInspectorPanel.lyrics)
                Text(t("fullscreen.queue")).tag(MacInspectorPanel.queue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(player.isRadio)
            .accessibilityLabel(t("native.mac.inspector.title"))
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                if panel == .lyrics, player.currentSong != nil, !player.isRadio {
                    Button {
                        router.present(.lyricsSettings)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: AppMetrics.iconButton, height: AppMetrics.iconButton)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.75))
                    .help(t("fullscreen.selectLyrics"))
                    .accessibilityLabel(t("fullscreen.selectLyrics"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

/// A station: its badge, its name and that it is live.
private struct MacRadioNowPlaying: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 18) {
                PlayerArtwork(cornerRadius: 12, size: .large)
                    .frame(maxWidth: 220, maxHeight: 220)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                VStack(spacing: 6) {
                    Text(NowPlayingText.title(player, t))
                        .displayFont(.inline)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text(t("radios.label"))
                            .textCase(.uppercase)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(28)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Queue

/// A row of the queue list, as its selection tag.
private enum MacQueueRowID: Hashable {
    /// Index in the listening history, most recent first.
    case history(Int)
    case current
    /// A `QueueEntry.id`.
    case entry(String)
}

/// The queue as a Mac list: the listening history, what plays now, the
/// songs the user queued and the rest of the album or playlist. A click
/// selects, a double-click or Return plays, Delete removes, rows drag to a
/// new place in their section and a right-click opens the song's menu. It
/// opens scrolled to the current song, with the history above it, as on
/// iOS; the player decides whether a choice asks before replacing songs the
/// user queued.
private struct MacQueueList: View {
    @Environment(PlayerStore.self) private var player
    @Environment(ListeningHistoryStore.self) private var history
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    @State private var selection: Set<MacQueueRowID> = []

    private let currentAnchor = "mac-queue-current"

    var body: some View {
        WithPerceptionTracking {
            let queue = player.queue
            ScrollViewReader { proxy in
                WithPerceptionTracking {
                    List(selection: $selection) {
                        historySection
                        if let current = queue.current {
                            Section {
                                MacQueueSongRow(song: current.song, isCurrent: true)
                                    .tag(MacQueueRowID.current)
                                    .id(currentAnchor)
                            } header: {
                                MacQueueSectionHeader(title: t("fullscreen.playing")) { EmptyView() }
                            }
                        }
                        if !queue.userQueue.isEmpty {
                            Section {
                                ForEach(queue.userQueue) { entry in
                                    MacQueueSongRow(song: entry.song)
                                        .tag(MacQueueRowID.entry(entry.id))
                                }
                                .onMove { source, destination in
                                    player.move(in: .user, from: source, to: destination)
                                }
                            } header: {
                                MacQueueSectionHeader(title: t("fullscreen.queue")) {
                                    Button(t("generic.clear")) {
                                        player.remove(entries: queue.userQueue)
                                    }
                                }
                            }
                        }
                        Section {
                            ForEach(queue.upNext) { entry in
                                MacQueueSongRow(song: entry.song)
                                    .tag(MacQueueRowID.entry(entry.id))
                            }
                            .onMove { source, destination in
                                player.move(in: .context, from: source, to: destination)
                            }
                            notes(for: queue)
                        } header: {
                            MacQueueSectionHeader(
                                title: t("fullscreen.queueContinue"),
                                subtitle: queue.sourceName.map { t("fullscreen.queueFromSource", ["source": $0]) }
                            ) { EmptyView() }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: MacQueueRowID.self) { ids in
                        WithPerceptionTracking {
                            menu(for: ids)
                        }
                    } primaryAction: { ids in
                        play(ids)
                    }
                    .onDeleteCommand {
                        remove(selection)
                    }
                    .onAppear {
                        proxy.scrollTo(currentAnchor, anchor: .top)
                    }
                    .appOnChange(of: queue.current?.id) {
                        selection = []
                        withAnimation(.smooth(duration: 0.3)) {
                            proxy.scrollTo(currentAnchor, anchor: .top)
                        }
                    }
                }
            }
            .mask(EdgeFade(top: 10, bottom: 18))
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !history.songs.isEmpty {
            Section {
                // Oldest first, ending right above what plays now.
                ForEach(Array(history.songs.enumerated().reversed()), id: \.offset) { index, song in
                    MacQueueSongRow(song: song, isHistory: true)
                        .tag(MacQueueRowID.history(index))
                }
            } header: {
                MacQueueSectionHeader(title: t("fullscreen.queueHistory")) {
                    Button(t("generic.clear")) { history.clear() }
                }
            }
        }
    }

    @ViewBuilder
    private func notes(for queue: PlayerQueue) -> some View {
        if queue.remainingCount == 0 {
            Text(t("fullscreen.emptyQueue"))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        if player.repeatMode != .off {
            MacQueueModeNote(
                title: t("fullscreen.queueRepeating"),
                systemImage: player.repeatMode == .one ? "repeat.1" : "repeat"
            )
        }
        if player.isShuffleActive {
            MacQueueModeNote(title: t("fullscreen.queueShuffling"), systemImage: "shuffle")
        }
    }

    // MARK: Rows and actions

    private enum Resolved {
        case history(index: Int, song: Song)
        case current(QueueEntry)
        case entry(QueueEntry)

        var song: Song {
            switch self {
            case let .history(_, song): song
            case let .current(entry), let .entry(entry): entry.song
            }
        }
    }

    /// The rows of `ids` that still exist, in the order the list shows them.
    private func resolve(_ ids: Set<MacQueueRowID>) -> [Resolved] {
        let queue = player.queue
        var rows: [Resolved] = []
        for (index, song) in history.songs.enumerated().reversed() where ids.contains(.history(index)) {
            rows.append(.history(index: index, song: song))
        }
        if let current = queue.current, ids.contains(.current) {
            rows.append(.current(current))
        }
        for entry in queue.userQueue + queue.upNext where ids.contains(.entry(entry.id)) {
            rows.append(.entry(entry))
        }
        return rows
    }

    /// Plays the first chosen row: a queue row is jumped to, a history song
    /// plays next, and the current song starts over.
    private func play(_ ids: Set<MacQueueRowID>) {
        guard let first = resolve(ids).first else { return }
        switch first {
        case let .history(_, song):
            player.playFromHistory(song)
        case .current:
            player.seek(to: 0)
            if !player.isPlaying { player.resume() }
        case let .entry(entry):
            player.play(entry: entry)
        }
    }

    /// Removes queued rows from the queue and history rows from the history.
    private func remove(_ ids: Set<MacQueueRowID>) {
        let rows = resolve(ids)
        let entries = rows.compactMap { row -> QueueEntry? in
            if case let .entry(entry) = row { return entry }
            return nil
        }
        let historyIndexes = rows.compactMap { row -> Int? in
            if case let .history(index, _) = row { return index }
            return nil
        }
        if !entries.isEmpty { player.remove(entries: entries) }
        for index in historyIndexes.sorted(by: >) {
            history.remove(at: index)
        }
        selection = []
    }

    @ViewBuilder
    private func menu(for ids: Set<MacQueueRowID>) -> some View {
        let rows = resolve(ids)
        if rows.count == 1, let row = rows.first {
            switch row {
            case let .history(index, song):
                Button(t("options.play")) { player.playFromHistory(song) }
                Button(t("native.mac.queue.removeFromHistory"), role: .destructive) {
                    history.remove(at: index)
                }
                SongMenuItems(song: song)
            case let .current(entry):
                SongMenuItems(song: entry.song, context: .nowPlaying)
            case let .entry(entry):
                Button(t("options.play")) { player.play(entry: entry) }
                SongMenuItems(song: entry.song, context: .queue(entry))
            }
        } else if !rows.isEmpty {
            Button(t("options.play")) { play(ids) }
            Button(t("options.playlist.add")) {
                router.present(.addToPlaylist(rows.map(\.song)))
            }
            if rows.contains(where: { if case .entry = $0 { true } else { false } }) {
                Button(t("options.removeFromQueue"), role: .destructive) { remove(ids) }
            }
            if rows.contains(where: { if case .history = $0 { true } else { false } }) {
                Button(t("native.mac.queue.removeFromHistory"), role: .destructive) { remove(ids) }
            }
        }
    }
}

/// A section's title, with what it is from and its actions.
private struct MacQueueSectionHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        WithPerceptionTracking {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer()
                actions
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.trailing, 8)
            }
            .textCase(nil)
            .padding(.top, 6)
        }
    }
}

/// A queue row: cover, title and artist, and the length; the current song
/// shows that it plays.
private struct MacQueueSongRow: View {
    let song: Song
    var isCurrent = false
    var isHistory = false

    @Environment(PlayerStore.self) private var player

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 10) {
                SongArtwork(song: song, cornerRadius: 4)
                    .frame(width: AppMetrics.rowArtwork, height: AppMetrics.rowArtwork)
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.black.opacity(0.45))
                            Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(song.title)
                            .font(.callout.weight(isCurrent ? .semibold : .regular))
                            .lineLimit(1)
                        if song.explicitStatus == .explicit {
                            ExplicitBadge()
                        }
                    }
                    .foregroundStyle(.white)
                    Text(song.artistLine)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if song.duration > 0 {
                    Text(Formatters.clock(TimeInterval(song.duration)))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .opacity(isHistory ? 0.75 : 1)
            .padding(.vertical, 2)
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
        }
    }
}

private struct MacQueueModeNote: View {
    let title: String
    let systemImage: String

    var body: some View {
        WithPerceptionTracking {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
        }
    }
}
