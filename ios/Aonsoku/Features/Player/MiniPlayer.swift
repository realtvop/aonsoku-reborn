import AonsokuKit
import SwiftUI

/// The player in the tab bar accessory, as in Apple Music: the cover, the
/// song, Play/Pause and Next. A tap opens Now Playing. Beside the minimized
/// tab bar it keeps the cover, title, artist and Play/Pause. Swipe the pill
/// horizontally to move through the queue.
struct MiniPlayer: View {
    var compactProgress: CGFloat = 0

    @ScaledMetric(relativeTo: .footnote) private var expandedTitleSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var compactTitleSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var expandedSubtitleSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var compactSubtitleSize: CGFloat = 11
    @ScaledMetric(relativeTo: .title3) private var expandedControlSize: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var compactControlSize: CGFloat = 21

    @Environment(PlayerStore.self) private var player
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    @State private var swipeContext: MiniPlayerSwipeContext?
    @State private var swipeOffset: CGFloat = 0
    @State private var titlesWidth: CGFloat = 0
    @State private var armedSwipe: MiniPlayerSwipeDirection?
    @State private var swipeHapticTrigger = 0
    @State private var settleTask: Task<Void, Never>?

    private let trackSpacing: CGFloat = 32

    var body: some View {
        HStack(spacing: mix(10, 7)) {
            Color.clear
                .frame(width: mix(34, 26), height: mix(34, 26))
            titles
            Spacer(minLength: 4)
            controls
        }
        .padding(.leading, mix(10, 7))
        .padding(.trailing, mix(7, 3))
        .foregroundStyle(.primary)
        .contentShape(.rect)
        .onTapGesture {
            open()
        }
        .simultaneousGesture(trackSwipeGesture)
        .haptic(.selection, trigger: swipeHapticTrigger)
        .onDisappear {
            settleTask?.cancel()
            settleTask = nil
        }
        .onChange(of: player.currentSong?.id) {
            guard settleTask == nil, swipeContext != nil else { return }
            resetSwipe(animated: false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: t("fullscreen.switchButton")) {
            open()
        }
    }

    private func open() {
        guard player.hasMedia else { return }
        router.presentNowPlaying()
    }

    private var titles: some View {
        let context = swipeContext ?? makeSwipeContext()
        return GeometryReader { proxy in
            let viewportWidth = max(proxy.size.width, 1)
            let pageStride = viewportWidth + trackSpacing
            ZStack(alignment: .leading) {
                metadata(context.current, isActive: swipeContext == nil)
                    .frame(width: viewportWidth, alignment: .leading)
                    .offset(x: swipeOffset)
                if let previous = context.previous {
                    metadata(previous.metadata, isActive: false)
                        .frame(width: viewportWidth, alignment: .leading)
                        .offset(x: swipeOffset - pageStride)
                }
                if let next = context.next {
                    metadata(next.metadata, isActive: false)
                        .frame(width: viewportWidth, alignment: .leading)
                        .offset(x: swipeOffset + pageStride)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: mix(32, 28))
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { titlesWidth = $0 }
        .clipped()
        .layoutPriority(1)
    }

    @ViewBuilder
    private func metadata(_ metadata: MiniPlayerMetadata, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: mix(1, 0)) {
            MarqueeText(text: metadata.title, respectsReduceMotion: false, isActive: isActive)
                .font(.system(size: mix(expandedTitleSize, compactTitleSize), weight: .semibold))
            if let subtitle = metadata.subtitle {
                subtitleView(subtitle, isActive: isActive)
                    .font(.system(size: mix(expandedSubtitleSize, compactSubtitleSize)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func subtitleView(_ subtitle: MiniPlayerMetadata.Subtitle, isActive: Bool) -> some View {
        switch subtitle {
        case let .device(name):
            HStack(spacing: 4) {
                Image(systemName: "hifispeaker.fill")
                MarqueeText(text: name, respectsReduceMotion: false, isActive: isActive)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
        case let .text(text):
            MarqueeText(text: text, respectsReduceMotion: false, isActive: isActive)
        }
    }

    private func makeSwipeContext() -> MiniPlayerSwipeContext {
        let queue = player.queue
        let currentSubtitle: MiniPlayerMetadata.Subtitle? =
            if case let .remote(_, deviceName) = player.target {
                .device(deviceName)
            } else if let subtitle = NowPlayingText.subtitle(player, t) {
                .text(subtitle)
            } else {
                nil
            }
        let previous = queue.history.last.map(destination)
        let nextEntry = queue.userQueue.first
            ?? queue.upNext.first
            ?? repeatAllEntry(in: queue)
        return MiniPlayerSwipeContext(
            current: MiniPlayerMetadata(
                title: NowPlayingText.title(player, t),
                subtitle: currentSubtitle
            ),
            previous: previous,
            next: nextEntry.map(destination)
        )
    }

    private func destination(_ entry: QueueEntry) -> MiniPlayerSwipeDestination {
        MiniPlayerSwipeDestination(
            entry: entry,
            metadata: MiniPlayerMetadata(
                title: entry.song.title,
                subtitle: .text(entry.song.artistLine)
            )
        )
    }

    private func repeatAllEntry(in queue: PlayerQueue) -> QueueEntry? {
        guard player.repeatMode == .all, !player.isShuffleActive else { return nil }
        return queue.history.first
    }

    private var trackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard settleTask == nil,
                      abs(value.translation.width) > abs(value.translation.height)
                else { return }
                let context = swipeContext ?? makeSwipeContext()
                swipeContext = context
                let direction = MiniPlayerSwipeDirection(translation: value.translation.width)
                let width = max(titlesWidth, 1) + trackSpacing
                let limited = min(max(value.translation.width, -width), width)
                swipeOffset = context.destination(in: direction) == nil
                    ? limited * 0.12
                    : limited
                updateSwipeHaptic(
                    direction: direction,
                    translation: value.translation.width,
                    context: context
                )
            }
            .onEnded { value in
                guard settleTask == nil, let context = swipeContext,
                      abs(value.translation.width) > abs(value.translation.height)
                else {
                    resetSwipe(animated: true)
                    return
                }
                let direction = MiniPlayerSwipeDirection(translation: value.translation.width)
                guard let destination = context.destination(in: direction) else {
                    resetSwipe(animated: true)
                    return
                }
                let distance = abs(value.translation.width)
                let projectedDistance = abs(value.predictedEndTranslation.width)
                let commits = distance >= swipeThreshold
                    || (distance >= 12 && projectedDistance >= max(titlesWidth * 0.65, 60))
                guard commits else {
                    resetSwipe(animated: true)
                    return
                }
                if armedSwipe != direction {
                    swipeHapticTrigger += 1
                }
                armedSwipe = nil
                settle(on: destination, direction: direction)
            }
    }

    private var swipeThreshold: CGFloat {
        min(max(titlesWidth * 0.24, 36), 72)
    }

    private func updateSwipeHaptic(
        direction: MiniPlayerSwipeDirection,
        translation: CGFloat,
        context: MiniPlayerSwipeContext
    ) {
        let crossed = abs(translation) >= swipeThreshold
            && context.destination(in: direction) != nil
        guard crossed else {
            armedSwipe = nil
            return
        }
        guard armedSwipe != direction else { return }
        armedSwipe = direction
        swipeHapticTrigger += 1
    }

    private func settle(
        on destination: MiniPlayerSwipeDestination,
        direction: MiniPlayerSwipeDirection
    ) {
        let width = max(titlesWidth, 1) + trackSpacing
        withAnimation(.spring(duration: 0.24, bounce: 0.05)) {
            swipeOffset = direction == .next ? -width : width
        }
        let targetSongID = destination.entry.song.id
        settleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(0.24))
                if player.currentSong?.id != targetSongID {
                    try await Task.sleep(for: .seconds(0.6))
                }
            } catch {
                return
            }
            resetSwipe(animated: false)
            settleTask = nil
        }
        if direction == .next {
            player.next()
        } else {
            player.play(entry: destination.entry)
        }
    }

    private func resetSwipe(animated: Bool) {
        armedSwipe = nil
        if animated {
            withAnimation(.spring(duration: 0.22, bounce: 0.08)) {
                swipeOffset = 0
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                swipeOffset = 0
            }
        }
        swipeContext = nil
    }

    private func mix(_ expanded: CGFloat, _ compact: CGFloat) -> CGFloat {
        expanded + (compact - expanded) * compactProgress
    }

    private var controls: some View {
        HStack(spacing: mix(10, 0)) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: mix(expandedControlSize, compactControlSize)))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel(t(player.isPlaying ? "player.tooltips.pause" : "player.tooltips.play"))
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: expandedControlSize))
                    .frame(width: 40, height: 36)
                    .contentShape(.rect)
            }
            .frame(width: mix(40, 0))
            .opacity(1 - compactProgress)
            .clipped()
            .allowsHitTesting(compactProgress == 0)
            .accessibilityHidden(compactProgress > 0)
            .accessibilityLabel(t("player.tooltips.next"))
        }
    }
}

private enum MiniPlayerSwipeDirection {
    case previous
    case next

    init(translation: CGFloat) {
        self = translation < 0 ? .next : .previous
    }
}

private struct MiniPlayerMetadata {
    enum Subtitle {
        case device(String)
        case text(String)
    }

    let title: String
    let subtitle: Subtitle?
}

private struct MiniPlayerSwipeDestination {
    let entry: QueueEntry
    let metadata: MiniPlayerMetadata
}

private struct MiniPlayerSwipeContext {
    let current: MiniPlayerMetadata
    let previous: MiniPlayerSwipeDestination?
    let next: MiniPlayerSwipeDestination?

    func destination(in direction: MiniPlayerSwipeDirection) -> MiniPlayerSwipeDestination? {
        switch direction {
        case .previous: previous
        case .next: next
        }
    }
}

// MARK: - Shared pieces

/// The cover of what is playing: the song's, a radio badge, or a note
/// while nothing plays.
struct PlayerArtwork: View {
    var cornerRadius: CGFloat = 8
    var size: ArtworkSize = .medium

    @Environment(PlayerStore.self) private var player

    var body: some View {
        if let song = player.currentSong {
            SongArtwork(song: song, size: size, cornerRadius: cornerRadius)
        } else if player.isRadio {
            RadioBadge(name: player.radio?.current?.name ?? "")
                .overlay {
                    GeometryReader { proxy in
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: proxy.size.width * 0.32, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
                .aspectRatio(1, contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.fill.tertiary)
                .overlay {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
                .aspectRatio(1, contentMode: .fit)
        }
    }
}

/// Titles for what is playing, shared by the mini player and Now Playing.
enum NowPlayingText {
    static func title(_ player: PlayerStore, _ t: Localizer) -> String {
        if let song = player.currentSong {
            return song.title
        }
        if player.isRadio, let station = player.radio?.current {
            return station.name
        }
        return t("player.noSongPlaying")
    }

    /// The artist, or Radio for a station.
    static func subtitle(_ player: PlayerStore, _ t: Localizer) -> String? {
        if let song = player.currentSong {
            return song.artistLine
        }
        if player.isRadio {
            return t("radios.label")
        }
        return nil
    }
}
