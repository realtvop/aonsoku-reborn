import AonsokuKit
import Perception
import SwiftUI

/// What the inspector beside the content shows.
enum MacInspectorPanel: String {
    case lyrics
    case queue

    static let storageKey = "mac.inspector.panel"
}

/// The player along the bottom of the window, with the controls of the iOS
/// full-screen player: what plays and its links, the favorite and the song's
/// menu on the left; shuffle, transport and repeat over the scrubber in the
/// middle; the sleep timer, lyrics, queue, devices, AirPlay and volume on the
/// right. Lyrics and the queue open in the window's inspector.
struct MacPlayerBar: View {
    @Environment(PlayerStore.self) private var player

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 16) {
                    MacNowPlayingSummary()
                        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 2) {
                        MacTransportControls()
                        MacScrubber()
                    }
                    .frame(minWidth: 320, idealWidth: 460, maxWidth: 520)
                    .layoutPriority(1)
                    MacPlayerAccessories()
                        .frame(minWidth: 200, maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(height: 72)
            }
            .appGlass(in: Rectangle())
        }
    }
}

// MARK: - Now playing

/// The cover, which opens Now Playing, the title and artist as links, the
/// favorite and the song's menu, and what the player is doing besides playing
/// here: controlling another device or counting down to sleep.
private struct MacNowPlayingSummary: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t
    @AppStorage(MacInspectorPanel.storageKey) private var panel = MacInspectorPanel.lyrics

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 10) {
                Button {
                    router.isNowPlayingPresented.toggle()
                } label: {
                    PlayerArtwork(cornerRadius: 5, size: .small)
                        .frame(width: 52, height: 52)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .disabled(!player.hasMedia)
                .help(t(router.isNowPlayingPresented ? "native.mac.player.hideNowPlaying" : "native.mac.player.showNowPlaying"))
                .accessibilityLabel(t(router.isNowPlayingPresented ? "native.mac.player.hideNowPlaying" : "native.mac.player.showNowPlaying"))

                // The heart and the menu follow the text; the text gives way
                // before them when the column is narrow.
                VStack(alignment: .leading, spacing: 2) {
                    title
                    subtitle
                    status
                }
                .layoutPriority(1)

                if let song = player.currentSong {
                    MacFavoriteButton(songId: song.id)
                }
                if player.hasMedia {
                    Menu {
                        NowPlayingMenuItems()
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 22, height: 22)
                            .contentShape(.rect)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(t("playlist.buttons.options", ["name": NowPlayingText.title(player, t)]))
                    .accessibilityLabel(t("playlist.buttons.options", ["name": NowPlayingText.title(player, t)]))
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var title: some View {
        let text = NowPlayingText.title(player, t)
        if let song = player.currentSong, let albumId = song.albumId {
            Button(text) {
                router.navigate(to: .album(id: albumId, preview: nil))
            }
            .buttonStyle(MacLinkStyle(font: .callout.weight(.semibold), color: .primary))
            .lineLimit(1)
            .help(t("options.goto.album"))
        } else {
            Text(text)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(player.hasMedia ? .primary : .secondary)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let song = player.currentSong {
            let credits = Self.credits(of: song)
            if credits.count > 1 {
                Menu {
                    ForEach(credits, id: \.id) { credit in
                        Button(credit.name) {
                            router.navigate(to: .artist(id: credit.id, name: credit.name))
                        }
                    }
                } label: {
                    Text(song.artistLine)
                        .font(.caption)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help(t("options.goto.artist"))
            } else if let credit = credits.first {
                Button(song.artistLine) {
                    router.navigate(to: .artist(id: credit.id, name: credit.name))
                }
                .buttonStyle(MacLinkStyle(font: .caption, color: .secondary))
                .lineLimit(1)
                .help(t("options.goto.artist"))
            } else {
                Text(song.artistLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if let subtitle = NowPlayingText.subtitle(player, t) {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Another device under control, the sleep timer or a playback error.
    @ViewBuilder
    private var status: some View {
        if case let .remote(_, deviceName) = player.target {
            MacRemoteControlStatus(deviceName: deviceName)
        } else if player.sleepTimer.isActive {
            Label {
                SleepTimerStatus()
            } icon: {
                Image(systemName: "moon.zzz.fill")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tint)
            .lineLimit(1)
        } else if let message = player.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(message)
        }
    }

    private struct Credit {
        let id: String
        let name: String
    }

    /// The song's credited artists with ids, or its main artist.
    private static func credits(of song: Song) -> [Credit] {
        let credited = song.artists.compactMap { artist in
            artist.id.flatMap { $0.isEmpty ? nil : Credit(id: $0, name: artist.name) }
        }
        if !credited.isEmpty { return credited }
        if let id = song.artistId, !id.isEmpty { return [Credit(id: id, name: song.artist)] }
        return []
    }
}

/// Text that reads as a link on hover: underlined, in its own color.
private struct MacLinkStyle: ButtonStyle {
    let font: Font
    let color: Color

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(color)
            .underline(isHovered)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { isHovered = $0 }
    }
}

/// Which device is being controlled, with a way back to this one.
private struct MacRemoteControlStatus: View {
    let deviceName: String

    @Environment(CoordinationStore.self) private var coordination
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 6) {
                Label(
                    t("settings.crossDevice.playback.controllingDevice", ["name": deviceName]),
                    systemImage: "hifispeaker.fill"
                )
                .lineLimit(1)
                Button(t("settings.crossDevice.playback.exitControl")) {
                    coordination.stopControlling()
                }
                .buttonStyle(.link)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tint)
        }
    }
}

/// The current song's heart, red while it is a favorite.
struct MacFavoriteButton: View {
    let songId: String

    @Environment(FavoritesStore.self) private var favorites
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            let isFavorite = favorites.isFavorite(.song, id: songId)
            Button {
                Task { await player.toggleFavoriteCurrent() }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
                    .appSymbolTransition()
            }
            .buttonStyle(.borderless)
            .help(t(isFavorite ? "options.unlike" : "options.like"))
            .accessibilityLabel(t(isFavorite ? "options.unlike" : "options.like"))
        }
    }
}

// MARK: - Transport

/// Shuffle, Previous, Play/Pause, Next and Repeat.
private struct MacTransportControls: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 18) {
                toggle(
                    systemImage: "shuffle",
                    isOn: player.isShuffleActive,
                    label: t(player.isShuffleActive ? "player.tooltips.shuffle.disable" : "player.tooltips.shuffle.enable")
                ) {
                    player.toggleShuffle()
                }
                .disabled(player.isRadio)
                transport("backward.fill", size: 15, label: t("player.tooltips.previous")) {
                    player.previous()
                }
                transport(player.isPlaying ? "pause.fill" : "play.fill", size: 22, label: t(player.isPlaying ? "player.tooltips.pause" : "player.tooltips.play")) {
                    player.togglePlayPause()
                }
                .overlay(alignment: .topTrailing) {
                    PlayerBufferingIndicator(tint: .secondary)
                        .offset(x: 10, y: -4)
                }
                transport("forward.fill", size: 15, label: t("player.tooltips.next")) {
                    player.next()
                }
                toggle(
                    systemImage: player.repeatMode == .one ? "repeat.1" : "repeat",
                    isOn: player.repeatMode != .off,
                    label: t(repeatLabelKey)
                ) {
                    player.cycleRepeat()
                }
                .disabled(player.isRadio)
            }
            .disabled(!player.hasMedia)
        }
    }

    private var repeatLabelKey: String {
        switch player.repeatMode {
        case .off: "player.tooltips.repeat.enable"
        case .all: "player.tooltips.repeat.enableOne"
        case .one: "player.tooltips.repeat.disable"
        }
    }

    private func transport(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 14, height: 26)
                .contentShape(.rect)
                .appSymbolTransition()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .help(label)
        .accessibilityLabel(label)
    }

    private func toggle(systemImage: String, isOn: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .background(isOn ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
                .contentShape(.rect)
                .appSymbolTransition()
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Scrubber

/// The time played, a slider that seeks when released, the time left and
/// the audio quality. Radio shows that it is live.
private struct MacScrubber: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    /// 0...1 while dragging.
    @State private var dragProgress: Double?
    /// The position just sought to, shown until playback reports it.
    @State private var pendingSeek: (position: TimeInterval, at: Date)?

    var body: some View {
        WithPerceptionTracking {
            if player.isRadio {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(t("radios.label"))
                        .textCase(.uppercase)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(height: 18)
            } else {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    scrubber(position: displayedPosition, duration: player.clock.duration)
                }
            }
        }
    }

    private var displayedPosition: TimeInterval {
        let duration = player.clock.duration
        if let dragProgress { return dragProgress * duration }
        let position = player.clock.position()
        if let pendingSeek, Date.now.timeIntervalSince(pendingSeek.at) < 1.5, abs(position - pendingSeek.position) > 1 {
            return pendingSeek.position
        }
        return position
    }

    private func scrubber(position: TimeInterval, duration: TimeInterval) -> some View {
        let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0
        return HStack(spacing: 8) {
            Text(Formatters.clock(position))
                .frame(minWidth: 36, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { dragProgress ?? progress },
                    set: { dragProgress = $0 }
                ),
                in: 0...1
            ) { editing in
                if editing {
                    dragProgress = dragProgress ?? progress
                } else {
                    if let dragProgress, duration > 0 {
                        seek(to: dragProgress * duration)
                    }
                    dragProgress = nil
                }
            }
            .controlSize(.mini)
            .disabled(duration <= 0)
            .accessibilityLabel(t("player.tooltips.progress"))
            .accessibilityValue("\(Formatters.clock(position)) / \(Formatters.clock(duration))")
            Text("-\(Formatters.clock(max(duration - position, 0)))")
                .frame(minWidth: 40, alignment: .leading)
            if let quality = player.currentSong.flatMap({ Formatters.quality(of: $0) }) {
                Text(quality)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
                    .lineLimit(1)
                    .fixedSize()
                    .help(quality)
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private func seek(to position: TimeInterval) {
        pendingSeek = (position, .now)
        player.seek(to: position)
    }
}

// MARK: - Accessories

/// The sleep timer, lyrics, queue, devices, AirPlay and volume.
private struct MacPlayerAccessories: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t
    @AppStorage(MacInspectorPanel.storageKey) private var panel = MacInspectorPanel.lyrics

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 6) {
                SleepTimerMenu {
                    Image(systemName: player.sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz")
                        .foregroundStyle(player.sleepTimer.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!player.hasMedia)
                .help(t("player.sleepTimer.tooltip"))
                .accessibilityLabel(t("player.sleepTimer.tooltip"))

                panelButton(.lyrics, systemImage: "quote.bubble", label: t("fullscreen.lyrics"))
                    .disabled(player.isRadio || !player.hasMedia)
                panelButton(.queue, systemImage: "list.bullet", label: t("fullscreen.queue"))
                    .disabled(player.isRadio)

                MacDevicesButton()

                if !player.target.isRemote {
                    MacRoutePicker(label: t("native.mac.player.airPlay"))
                        .frame(width: 24, height: 24)
                        .help(t("native.mac.player.airPlay"))
                }

                MacVolumeControl()
            }
        }
    }

    private func panelButton(_ target: MacInspectorPanel, systemImage: String, label: String) -> some View {
        let isOn = router.isNowPlayingPresented && panel == target
        return Button {
            if isOn {
                router.isNowPlayingPresented = false
            } else {
                panel = target
                router.isNowPlayingPresented = true
            }
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .background(isOn ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Opens the devices sheet; lit while another device is controlled.
private struct MacDevicesButton: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            let isRemote = player.target.isRemote
            Button {
                router.present(.devices)
            } label: {
                Image(systemName: isRemote ? "hifispeaker.and.homepod.fill" : "hifispeaker.and.homepod")
                    .foregroundStyle(isRemote ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help(t("settings.crossDevice.title"))
            .accessibilityLabel(t("settings.crossDevice.title"))
        }
    }
}

/// The app's own volume, or the controlled device's: a speaker that mutes
/// and unmutes, and a slider.
struct MacVolumeControl: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    @State private var dragValue: Double?
    @AppStorage("mac.player.unmutedVolume") private var unmutedVolume = 1.0

    var body: some View {
        WithPerceptionTracking {
            let value = dragValue ?? player.volume
            HStack(spacing: 4) {
                Button {
                    if value > 0 {
                        unmutedVolume = value
                        player.setVolume(0)
                    } else {
                        player.setVolume(max(unmutedVolume, 0.1))
                    }
                } label: {
                    Image(systemName: Self.symbol(for: value))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help(t(value > 0 ? "player.tooltips.volume.mute" : "player.tooltips.volume.unmute"))
                .accessibilityLabel(t(value > 0 ? "player.tooltips.volume.mute" : "player.tooltips.volume.unmute"))

                Slider(
                    value: Binding(
                        get: { value },
                        set: { newValue in
                            dragValue = newValue
                            player.setVolume(newValue)
                        }
                    ),
                    in: 0...1
                ) { editing in
                    if !editing { dragValue = nil }
                }
                .controlSize(.mini)
                .frame(width: 84)
                .accessibilityLabel(t("player.tooltips.volume.label"))
                .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
            }
        }
    }

    static func symbol(for volume: Double) -> String {
        switch volume {
        case ..<0.01: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}
