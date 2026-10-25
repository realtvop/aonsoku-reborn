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
    var metadataEntranceDelay: Double = 0
    var onShowCover: () -> Void = {}
    @ViewBuilder let currentMetadata: CurrentMetadata

    @Environment(PlayerStore.self) private var player
    @Environment(ListeningHistoryStore.self) private var history
    @Environment(Localizer.self) private var t
    @Environment(PlayerPresentationState.self) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewportHeight: CGFloat = 0
    @State private var snapFeedback = 0
    @State private var historyTopPadding: CGFloat = 0
    @State private var snapAnimation = QueueScrollSnapAnimation()

    private let currentID = "current-track"
    private let modesID = "modes"

    var body: some View {
        let queue = player.queue
        ScrollViewReader { proxy in
            List {
                if !history.songs.isEmpty {
                    // Let even a short history occupy the whole viewport,
                    // with the current track completely below its lower edge.
                    Color.clear
                        .frame(height: historyTopPadding)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityHidden(true)
                    Section {
                        // Oldest first, ending right above what plays now.
                        ForEach(Array(history.songs.enumerated().reversed()), id: \.offset) { _, song in
                            QueueSongRow(song: song) {
                                player.playFromHistory(song)
                            }
                            .queueRow(isActive: isActive)
                        }
                    } header: {
                        QueueSectionHeader(title: t("fullscreen.queueHistory")) {
                            Button(t("generic.clear")) { history.clear() }
                        }
                        .queuePinnedHeader(isActive: isActive)
                    }
                }

                if showsCurrentTrack {
                    Section {
                        // Metadata belongs to the native row so drags on its
                        // buttons scroll the List unless this row is pinned
                        // at the top and starts a player dismissal.
                        HStack(spacing: 14) {
                            Button(action: onShowCover) {
                                Color.clear
                                    .frame(width: 64, height: 64)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(t("fullscreen.playing"))
                            currentMetadata
                                .modifier(PlayerPageContent(
                                    isVisible: isActive,
                                    riseDistance: presentation.panel == nil ? 64 : 0,
                                    isMetadata: true,
                                    entranceDelay: metadataEntranceDelay
                                ))
                        }
                        .frame(height: currentHeaderHeight)
                        .background {
                            QueueHeaderTrackingReader(
                                isActive: isActive,
                                reduceMotion: reduceMotion,
                                hasHistory: !history.songs.isEmpty,
                                historyPadding: historyTopPadding,
                                snapAnimation: snapAnimation,
                                onHistoryPadding: { padding in historyTopPadding = padding },
                                onLayout: { owner, frame, visible, pinned in
                                    if let frame {
                                        presentation.queueHeaderOwner = owner
                                        presentation.queueHeaderFrame = frame
                                        presentation.isQueueHeaderVisible = visible
                                        presentation.isQueueHeaderPinned = pinned
                                    } else if presentation.queueHeaderOwner == owner {
                                        presentation.isQueueHeaderVisible = false
                                        presentation.isQueueHeaderPinned = false
                                    }
                                },
                                onSnap: { snapFeedback += 1 }
                            )
                            .allowsHitTesting(false)
                        }
                        .id(currentID)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
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
                            .queueRow(isActive: isActive)
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
                                .queueHeaderRow(isActive: isActive)
                        }
                        ForEach(queue.upNext) { entry in
                            QueueSongRow(song: entry.song, isMovable: true) {
                                player.play(entry: entry)
                            }
                            .contextMenu {
                                SongMenuItems(song: entry.song, context: .queue(entry))
                            }
                            .queueRow(isActive: isActive)
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
                            .queueRow(isActive: isActive)
                    }
                    if player.repeatMode != .off {
                        QueueModeNote(
                            title: t("fullscreen.queueRepeating"),
                            systemImage: player.repeatMode == .one ? "repeat.1" : "repeat"
                        )
                        .queueRow(isActive: isActive)
                    }
                    if player.isShuffleActive {
                        QueueModeNote(title: t("fullscreen.queueShuffling"), systemImage: "shuffle")
                            .queueRow(isActive: isActive)
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
                    .queuePinnedHeader(isActive: isActive)
                }
            }
            .listStyle(.plain)
            // The leading history spacer must also support zero height.
            // queueRow retains the ordinary 44pt minimum including insets.
            .environment(\.defaultMinListRowHeight, 0)
            .listSectionSpacing(0)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            // iOS 26 adds its own material at scroll edges, independently
            // of the List background and our opaque section headers.
            .scrollEdgeEffectHidden()
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(PlayerArtworkLocation.containerCoordinateSpace))
            } action: { frame in
                if showsCurrentTrack { presentation.queueGestureViewportFrame = frame }
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(PlayerArtworkLocation.coordinateSpace))
            } action: { frame in
                viewportHeight = frame.height
                if showsCurrentTrack { presentation.queueViewportFrame = frame }
            }
            .haptic(.selection, trigger: snapFeedback)
            .onAppear { registerPreparation(proxy) }
            .onChange(of: currentHeaderHeight) { registerPreparation(proxy) }
            .onChange(of: historyTopPadding) {
                if presentation.isQueueHeaderPinned { presentation.prepareQueueForPresentation?() }
            }
            .onDisappear {
                snapAnimation.cancel()
                presentation.prepareQueueForPresentation = nil
            }
            .onChange(of: isActive) { _, active in
                // Also handles reopening fullscreen while Queue is selected.
                if active { presentation.prepareQueueForPresentation?() }
                else { snapAnimation.cancel() }
            }
            .task(id: history.songs.isEmpty) {
                // Prepare the initial offset when history finishes loading.
                guard !history.songs.isEmpty else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                presentation.prepareQueueForPresentation?()
            }
        }
        .mask(EdgeFade(top: 24, bottom: 28))
    }

    private func registerPreparation(_ proxy: ScrollViewProxy) {
        let target = showsCurrentTrack ? currentID : modesID
        let showsCurrentTrack = showsCurrentTrack
        let headerHeight = currentHeaderHeight
        presentation.prepareQueueForPresentation = { [weak presentation] in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(target, anchor: .top)
                guard showsCurrentTrack, let presentation,
                      let viewport = presentation.queueViewportFrame else { return }
                // scrollTo lays out on the next pass. Supply its destination
                // immediately so the sole artwork doesn't visit the old row
                // position, even if that cell has been recycled offscreen.
                presentation.queueHeaderOwner = nil
                presentation.queueHeaderFrame = CGRect(
                    x: 0, y: 8, width: max(viewport.width, 0), height: headerHeight
                )
                presentation.isQueueHeaderVisible = true
                presentation.isQueueHeaderPinned = false
            }
        }
    }
}

private extension View {
    func queueRow(isActive: Bool) -> some View {
        frame(minHeight: 32)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            .modifier(PlayerPageContent(isVisible: isActive))
    }

    func queuePinnedHeader(isActive: Bool) -> some View {
        textCase(nil)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .background {
                NowPlayingBackground()
                    .padding(.horizontal, 0)
                    .padding(.vertical, -10)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .modifier(PlayerPageContent(isVisible: isActive))
    }

    func queueHeaderRow(isActive: Bool) -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 14, leading: 0, bottom: 2, trailing: 0))
            .modifier(PlayerPageContent(isVisible: isActive))
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
                    .displayFont(.inline)
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
