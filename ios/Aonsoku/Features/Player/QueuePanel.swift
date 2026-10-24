import AonsokuKit
import SwiftUI

/// What played and what plays next, like the web queue: the listening
/// history, shuffle and repeat, the songs the user queued, then the rest
/// of the album or playlist. Rows play on tap, move by dragging and leave
/// with a swipe.
struct QueuePanel<CurrentMetadata: View>: View {
    var isActive = true
    var showsCurrentTrack = true
    var currentHeaderHeight: CGFloat = 64
    var palette: ArtworkPalette? = nil
    var onShowCover: () -> Void = {}
    @ViewBuilder let currentMetadata: CurrentMetadata

    @Environment(PlayerStore.self) private var player
    @Environment(ListeningHistoryStore.self) private var history
    @Environment(Localizer.self) private var t
    @Environment(PlayerPresentationState.self) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var didPositionInitially = false
    @State private var viewportHeight: CGFloat = 0
    @State private var snapFeedback = 0

    private let currentID = "current-track"
    private let modesID = "modes"

    var body: some View {
        let queue = player.queue
        ScrollViewReader { proxy in
            List {
                if !history.songs.isEmpty {
                    Section {
                        // Oldest first, ending right above what plays now.
                        ForEach(Array(history.songs.enumerated().reversed()), id: \.offset) { _, song in
                            QueueSongRow(song: song) {
                                player.playFromHistory(song)
                            }
                            .queueRow()
                        }
                    } header: {
                        QueueSectionHeader(title: t("fullscreen.queueHistory")) {
                            Button(t("generic.clear")) { history.clear() }
                        }
                        .queuePinnedHeader(palette: palette)
                    }
                }

                if showsCurrentTrack {
                    Section {
                        // Metadata belongs to the native row so drags on its
                        // buttons still scroll the List. Artwork remains sole.
                        HStack(spacing: 14) {
                            Button(action: onShowCover) {
                                Color.clear
                                    .frame(width: 64, height: 64)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(t("fullscreen.playing"))
                            currentMetadata
                        }
                        .frame(height: currentHeaderHeight)
                        .background {
                            QueueHeaderTrackingReader(
                                isActive: isActive,
                                reduceMotion: reduceMotion,
                                onLayout: { owner, frame, visible in
                                    if let frame {
                                        presentation.queueHeaderOwner = owner
                                        presentation.queueHeaderFrame = frame
                                        presentation.isQueueHeaderVisible = visible
                                    } else if presentation.queueHeaderOwner == owner {
                                        presentation.isQueueHeaderVisible = false
                                    }
                                },
                                onSnap: { snapFeedback += 1 }
                            )
                            .allowsHitTesting(false)
                        }
                        .id(currentID)
                        .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

                Section {
                    if !queue.userQueue.isEmpty {
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
                    if !queue.upNext.isEmpty {
                        if !queue.userQueue.isEmpty {
                            QueueSectionHeader(
                                title: t("fullscreen.queueContinue"),
                                subtitle: queue.sourceName.map { t("fullscreen.queueFromSource", ["source": $0]) }
                            ) { EmptyView() }
                                .queueHeaderRow()
                        }
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
                    // Even an empty/short queue can rest at the current-song
                    // boundary instead of exposing history on initial entry.
                    if showsCurrentTrack {
                        Color.clear
                            .frame(height: max(
                                viewportHeight - currentHeaderHeight - 16 - 80
                                    - CGFloat(queue.remainingCount) * 56, 0
                            ))
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .accessibilityHidden(true)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 12) {
                        QueueModeButtons()
                            .frame(maxWidth: .infinity)
                            .id(modesID)
                        QueueSectionHeader(
                            title: t(queue.userQueue.isEmpty ? "fullscreen.queueContinue" : "fullscreen.queue"),
                            subtitle: queue.userQueue.isEmpty
                                ? queue.sourceName.map { t("fullscreen.queueFromSource", ["source": $0]) } : nil
                        ) {
                            if !queue.userQueue.isEmpty {
                                Button(t("generic.clear")) { player.remove(entries: queue.userQueue) }
                            }
                        }
                    }
                    .queuePinnedHeader(palette: palette)
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(0)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always)
            .mask(EdgeFade(length: 20))
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(PlayerArtworkLocation.coordinateSpace))
            } action: { frame in
                viewportHeight = frame.height
                if showsCurrentTrack { presentation.queueViewportFrame = frame }
            }
            .haptic(.selection, trigger: snapFeedback)
            .task(id: isActive) {
                guard isActive else { return }
                presentation.isQueueHeaderVisible = true
                guard !history.songs.isEmpty, !didPositionInitially else {
                    didPositionInitially = true
                    return
                }
                await Task.yield()
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(showsCurrentTrack ? currentID : modesID, anchor: .top)
                }
                didPositionInitially = true
            }
        }
    }
}

private extension View {
    func queueRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
    }

    func queuePinnedHeader(palette: ArtworkPalette?) -> some View {
        textCase(nil)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .background {
                QueuePinnedHeaderBackground(palette: palette)
                    .padding(.horizontal, -20)
                    .padding(.vertical, -10)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    func queueHeaderRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 2, trailing: 20))
    }
}

/// A completely solid backdrop for pinned headers that directly matches the player's
/// background without radial vignette or palette transition delays.
private struct QueuePinnedHeaderBackground: View {
    let palette: ArtworkPalette?
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ZStack {
            settings.settings.appearance.darkTheme.palette.background
            if let color = palette?.average ?? palette?.colors.first {
                Color(color)
                    .opacity(min(max(settings.settings.appearance.nowPlayingColorIntensity, 0), 1))
            }
        }
    }
}

/// Shared titles for pinned history/upcoming headers and the user/context
/// boundary. Pinned headers use the same completely solid backdrop over the scrolling rows.
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
    @State private var feedback = 0

    var body: some View {
        Button {
            feedback += 1
            action()
        } label: {
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
        .animation(.smooth(duration: 0.25), value: isOn)
        .haptic(.selection, trigger: feedback)
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
