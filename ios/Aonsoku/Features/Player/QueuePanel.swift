import AonsokuKit
import SwiftUI

/// What played and what plays next, like the web queue: the listening
/// history, shuffle and repeat, the songs the user queued, then the rest
/// of the album or playlist. Rows play on tap, move by dragging and leave
/// with a swipe.
struct QueuePanel: View {
    @Environment(PlayerStore.self) private var player
    @Environment(ListeningHistoryStore.self) private var history
    @Environment(Localizer.self) private var t

    /// Scrolled to on appear, so the history stays above.
    private let modesID = "modes"

    var body: some View {
        let queue = player.queue
        ScrollViewReader { proxy in
            List {
                if !history.songs.isEmpty {
                    Section {
                        QueueSectionHeader(title: t("fullscreen.queueHistory")) {
                            Button(t("generic.clear")) {
                                history.clear()
                            }
                        }
                        .queueHeaderRow()
                        // Oldest first, ending right above what plays now.
                        ForEach(Array(history.songs.enumerated().reversed()), id: \.offset) { _, song in
                            QueueSongRow(song: song) {
                                player.playFromHistory(song)
                            }
                            .queueRow()
                        }
                    }
                }

                Section {
                    QueueModeButtons()
                        .frame(maxWidth: .infinity)
                        .id(modesID)
                        .queueRow()
                }

                if !queue.userQueue.isEmpty {
                    Section {
                        QueueSectionHeader(title: t("fullscreen.queue")) {
                            Button(t("generic.clear")) {
                                player.remove(entries: queue.userQueue)
                            }
                        }
                        .queueHeaderRow()
                        ForEach(queue.userQueue) { entry in
                            QueueSongRow(song: entry.song, isMovable: true) {
                                player.play(entry: entry)
                            }
                            .contextMenu {
                                SongMenuItems(song: entry.song, context: .queue(entry))
                            }
                            .queueRow()
                        }
                        .onMove { source, destination in
                            player.move(in: .user, from: source, to: destination)
                        }
                        .onDelete { offsets in
                            player.remove(entries: offsets.map { queue.userQueue[$0] })
                        }
                    }
                }

                if !queue.upNext.isEmpty {
                    Section {
                        QueueSectionHeader(
                            title: t("fullscreen.queueContinue"),
                            subtitle: queue.sourceName.map { t("fullscreen.queueFromSource", ["source": $0]) }
                        ) {
                            EmptyView()
                        }
                        .queueHeaderRow()
                        ForEach(queue.upNext) { entry in
                            QueueSongRow(song: entry.song, isMovable: true) {
                                player.play(entry: entry)
                            }
                            .contextMenu {
                                SongMenuItems(song: entry.song, context: .queue(entry))
                            }
                            .queueRow()
                        }
                        .onMove { source, destination in
                            player.move(in: .context, from: source, to: destination)
                        }
                        .onDelete { offsets in
                            player.remove(entries: offsets.map { queue.upNext[$0] })
                        }
                    }
                }

                Section {
                    if queue.remainingCount == 0 {
                        Text(t("fullscreen.emptyQueue"))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .queueRow()
                    }
                    if player.repeatMode != .off {
                        QueueModeNote(
                            title: t("fullscreen.queueRepeating"),
                            systemImage: player.repeatMode == .one ? "repeat.1" : "repeat"
                        )
                        .queueRow()
                    }
                    if player.isShuffleActive {
                        QueueModeNote(title: t("fullscreen.queueShuffling"), systemImage: "shuffle")
                            .queueRow()
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .mask(EdgeFade(length: 20))
            .onAppear {
                proxy.scrollTo(modesID, anchor: .top)
            }
        }
    }
}

private extension View {
    func queueRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparatorTint(.white.opacity(0.1))
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
    }

    func queueHeaderRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 2, trailing: 20))
    }
}

/// A section's title, as the section's first row rather than a plain
/// list's pinned header: pinned headers have no background over the
/// artwork colors, so the rows scrolling under them showed through.
private struct QueueSectionHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer()
            actions
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .buttonStyle(.plain)
        }
    }
}

/// A queue row: cover, title and artist, and a handle on rows that move.
private struct QueueSongRow: View {
    let song: Song
    var isMovable = false
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                SongArtwork(song: song, cornerRadius: 5)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(song.title)
                            .lineLimit(1)
                        if song.explicitStatus == .explicit {
                            ExplicitBadge()
                        }
                    }
                    .foregroundStyle(.white)
                    Text(song.artistLine)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isMovable {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.white.opacity(0.4))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Shuffle and Repeat, as toggles at the top of what plays next.
private struct QueueModeButtons: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    var body: some View {
        HStack(spacing: 10) {
            QueueModeToggle(
                title: t("shortcuts.playback.shuffle"),
                systemImage: "shuffle",
                isOn: player.isShuffleActive,
                hint: t(player.isShuffleActive ? "player.tooltips.shuffle.disable" : "player.tooltips.shuffle.enable")
            ) {
                player.toggleShuffle()
            }
            QueueModeToggle(
                title: t("shortcuts.playback.repeat"),
                systemImage: player.repeatMode == .one ? "repeat.1" : "repeat",
                isOn: player.repeatMode != .off,
                hint: t(repeatHintKey)
            ) {
                player.cycleRepeat()
            }
        }
        .padding(.vertical, 4)
    }

    private var repeatHintKey: String {
        switch player.repeatMode {
        case .off: "player.tooltips.repeat.enable"
        case .all: "player.tooltips.repeat.enableOne"
        case .one: "player.tooltips.repeat.disable"
        }
    }
}

private struct QueueModeToggle: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isOn ? .black : .white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minWidth: 120)
                .background(.white.opacity(isOn ? 0.92 : 0.12), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(hint)
        .haptic(.selection, trigger: isOn)
        .animation(.smooth(duration: 0.25), value: isOn)
    }
}

private struct QueueModeNote: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity)
    }
}
