import AonsokuKit
import SwiftUI

/// Now Playing, modeled on Apple Music: the cover over its own colors,
/// shrinking while paused, the song with Favorite and More, the scrubber,
/// transport and volume, and a bar for lyrics, AirPlay, Aonsoku devices
/// and the queue. Lyrics and the queue move the cover into a compact
/// header; on a wide iPad they open beside it.
struct NowPlayingView: View {
    enum Panel: Hashable {
        case lyrics
        case queue
    }

    @State private var panel: Panel?
    @State private var loadedPanels: Set<Panel> = []
    @State private var lyricsControlsHidden = false
    @State private var bottomControlsHeight: CGFloat?

    @Environment(PlayerStore.self) private var player
    @Environment(LyricsStore.self) private var lyrics
    @Environment(Localizer.self) private var t
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(Router.self) private var router
    @Environment(PlayerPresentationState.self) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let isWide = sizeClass == .regular && proxy.size.width > proxy.size.height
                && proxy.size.width >= 900
            Group {
                if isWide {
                    wideLayout
                } else {
                    compactLayout
                        .frame(maxWidth: 600)
                        .frame(maxWidth: .infinity)
                }
            }
            .animation(panelAnimation, value: panel)
            .animation(panelAnimation, value: bottomControlsHidden)
            .onChange(of: isWide || panel == nil, initial: true) { _, usesLargeCover in
                withAnimation(panelAnimation) {
                    presentation.artworkLocation = usesLargeCover ? .cover : .header
                }
            }
        }
        .foregroundStyle(.white)
        .scrollDisabled(presentation.dragOffset > 0)
        .environment(\.colorScheme, .dark)
        .task(id: router.isNowPlayingPresented ? player.currentSong?.id : nil) {
            guard router.isNowPlayingPresented else { return }
            await lyrics.load(for: player.currentSong)
        }
        .onChange(of: player.hasMedia) { _, hasMedia in
            if !hasMedia {
                router.isNowPlayingPresented = false
            }
        }
        .onChange(of: player.isRadio) { _, isRadio in
            if isRadio {
                panel = nil
            }
        }
        .onChange(of: panel) { lyricsControlsHidden = false }
        .onChange(of: router.isNowPlayingPresented) { lyricsControlsHidden = false }
        .onChange(of: player.currentSong?.id) { lyricsControlsHidden = false }
        .onChange(of: bottomControlsHidden, initial: true) {
            presentation.arePlaybackControlsVisible = !bottomControlsHidden
        }
        .accessibilityAction(.escape) {
            router.isNowPlayingPresented = false
        }
        .globalPresentations(.nowPlaying)
    }

    // MARK: - Layouts

    private var compactLayout: some View {
        VStack(spacing: 0) {
            grabber
            statusCapsules
            PlayerContentLayout(showsPanel: panel != nil) {
                largeArtwork
                headerArtwork
                    .opacity(panel == nil ? 0 : 1)
                    .allowsHitTesting(panel != nil)
                    .accessibilityHidden(panel == nil)
                titleRow
                    .modifier(PlayerPanelTransition(
                        progress: panel == nil ? 0 : 1, element: .metadata, reduceMotion: reduceMotion
                    ))
                panels
            }
            .frame(maxHeight: .infinity)
            bottomControls
        }
    }

    private var wideLayout: some View {
        HStack(spacing: 56) {
            VStack(spacing: 0) {
                grabber
                statusCapsules
                largeArtwork
                    .padding(.vertical, 20)
                    .frame(maxHeight: .infinity)
                titleRow
                bottomControls
            }
            .frame(maxWidth: 500)
            if panel != nil {
                panels
                    .frame(maxWidth: 620, maxHeight: .infinity)
                    .padding(.vertical, 40)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pieces

    private var panelAnimation: Animation {
        PlayerPresentationState.panelAnimation(reduceMotion: reduceMotion)
    }

    private var grabber: some View {
        Capsule()
            .fill(.white.opacity(0.35))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .contentShape(.rect)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(t("fullscreen.switchButton"))
            .accessibilityAction { router.isNowPlayingPresented = false }
            .onTapGesture { router.isNowPlayingPresented = false }
    }

    /// Remote control and the sleep timer, when they apply.
    @ViewBuilder
    private var statusCapsules: some View {
        if player.target.isRemote || player.sleepTimer.isActive {
            HStack(spacing: 8) {
                RemoteControlCapsule()
                if player.sleepTimer.isActive {
                    SleepTimerMenu {
                        Label {
                            SleepTimerStatus()
                        } icon: {
                            Image(systemName: "moon.zzz.fill")
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassEffect(.regular, in: .capsule)
                    }
                }
            }
            .padding(.top, 4)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private var largeArtwork: some View {
        PlayerArtworkSlot(location: .cover, cornerRadius: 14, shadowRadius: 26)
            .scaleEffect(player.isPlaying || !player.hasMedia ? 1 : 0.8)
            .animation(.spring(duration: 0.45, bounce: 0), value: player.isPlaying)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: NowPlayingText.title(player, t))
                    .font(.title3.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                ArtistMenu()
            }
            Spacer(minLength: 0)
            songButtons
        }
    }

    private var headerArtwork: some View {
        Button {
            panel = nil
        } label: {
            PlayerArtworkSlot(location: .header, cornerRadius: 8, shadowRadius: 10)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("fullscreen.playing"))
    }

    @ViewBuilder
    private var songButtons: some View {
        HStack(spacing: 10) {
            if let song = player.currentSong {
                FavoriteToolbarButton(kind: .song, id: song.id)
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .buttonStyle(.plain)
            }
            Menu {
                NowPlayingMenuItems()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t("playlist.buttons.options", ["name": NowPlayingText.title(player, t)]))
            .disabled(!player.hasMedia)
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            PlaybackScrubber()
            TransportControls(scale: 0.85)
                .padding(.vertical, 6)
            VolumeSlider()
        }
        .padding(.horizontal, 30)
    }

    private var bottomControlsHidden: Bool {
        panel == .lyrics && lyricsControlsHidden
    }

    /// Keep slider state alive while the entire footer gives space to lyrics.
    private var bottomControls: some View {
        VStack(spacing: 0) {
            controls
                .padding(.top, 8)
            bottomBar
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { bottomControlsHeight = $0 }
        .frame(height: bottomControlsHidden ? 0 : bottomControlsHeight, alignment: .top)
        .opacity(bottomControlsHidden ? 0 : 1)
        .clipped()
        .allowsHitTesting(!bottomControlsHidden)
        .accessibilityHidden(bottomControlsHidden)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            panelButton(.lyrics, symbol: "quote.bubble", label: t("fullscreen.lyrics"))
                .disabled(player.isRadio)
            Spacer(minLength: 0)
            if player.target.isRemote {
                Color.clear
                    .frame(width: 44, height: 44)
            } else {
                AudioRoutePicker()
                    .frame(width: 44, height: 44)
            }
            Spacer(minLength: 0)
            DevicesButton()
            Spacer(minLength: 0)
            panelButton(.queue, symbol: "list.bullet", label: t("fullscreen.queue"))
                .disabled(player.isRadio)
        }
        .padding(.horizontal, 44)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private func panelButton(_ target: Panel, symbol: String, label: String) -> some View {
        let isOn = panel == target
        return Button {
            loadedPanels.insert(target)
            panel = isOn ? nil : target
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(isOn ? .black : .white.opacity(0.7))
                .frame(width: 44, height: 44)
                .background(.white.opacity(isOn ? 0.92 : 0), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Keep visited pages mounted so switching preserves scroll position.
    /// The header and transport stay outside this crossfade.
    private var panels: some View {
        ZStack {
            if loadedPanels.contains(.lyrics) {
                LyricsPanel(isActive: panel == .lyrics && router.isNowPlayingPresented) { hidden in
                    lyricsControlsHidden = hidden
                }
                    .opacity(panel == .lyrics ? 1 : 0)
                    .allowsHitTesting(panel == .lyrics)
                    .accessibilityHidden(panel != .lyrics)
            }
            if loadedPanels.contains(.queue) {
                QueuePanel()
                    .opacity(panel == .queue ? 1 : 0)
                    .allowsHitTesting(panel == .queue)
                    .accessibilityHidden(panel != .queue)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.2), value: panel)
        .modifier(PlayerPanelTransition(
            progress: panel == nil ? 0 : 1, element: .content, reduceMotion: reduceMotion
        ))
        .allowsHitTesting(panel != nil)
        .accessibilityHidden(panel == nil)
        .clipped()
    }
}

/// Tie visibility to the same interruptible progress as the cover movement.
/// Text fades out during travel; panel content appears as the cover settles.
private struct PlayerPanelTransition: AnimatableModifier {
    enum Element {
        case metadata
        case content
    }

    var progress: Double
    let element: Element
    let reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let reveal = min(max((progress - 0.9) / 0.1, 0), 1)
        let opacity: Double = switch element {
        case .metadata:
            reduceMotion ? 1 : max(1 - progress / 0.25, reveal)
        case .content:
            reduceMotion ? progress : reveal
        }
        content.opacity(opacity)
    }
}

/// Only the upper content changes layout. Both artwork destinations always
/// exist, and the same metadata row moves between them; controls never reflow.
private struct PlayerContentLayout: SwiftUI.Layout {
    var showsPanel: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let leading: CGFloat = showsPanel ? 102 : 30
        let trailing: CGFloat = showsPanel ? 24 : 30
        let titleWidth = max(bounds.width - leading - trailing, 0)
        let titleSize = subviews[2].sizeThatFits(ProposedViewSize(width: titleWidth, height: nil))
        let headerHeight = max(64, titleSize.height)
        let panelTop = headerHeight + 16
        let coverHeight = max(bounds.height - titleSize.height - 24, 0)
        let coverSide = max(min(bounds.width - 60, coverHeight), 0)

        subviews[0].place(
            at: CGPoint(x: bounds.midX - coverSide / 2, y: bounds.minY + 12 + (coverHeight - coverSide) / 2),
            proposal: ProposedViewSize(width: coverSide, height: coverSide)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + 24, y: bounds.minY + 8 + (headerHeight - 64) / 2),
            proposal: ProposedViewSize(width: 64, height: 64)
        )
        subviews[2].place(
            at: CGPoint(
                x: bounds.minX + leading,
                y: showsPanel ? bounds.minY + 8 + (headerHeight - titleSize.height) / 2 : bounds.maxY - titleSize.height
            ),
            proposal: ProposedViewSize(width: titleWidth, height: titleSize.height)
        )
        subviews[3].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + panelTop),
            proposal: ProposedViewSize(width: bounds.width, height: max(bounds.height - panelTop, 0))
        )
    }
}

// MARK: - Title pieces

/// The artist line, opening a menu that goes to the artist or the album.
private struct ArtistMenu: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    var body: some View {
        let subtitle = NowPlayingText.subtitle(player, t) ?? ""
        if let song = player.currentSong, song.artistId != nil || song.albumId != nil {
            Menu {
                if let artistId = song.artistId {
                    Button {
                        router.navigate(to: .artist(id: artistId, name: song.artist))
                    } label: {
                        Label(t("options.goto.artist"), systemImage: "music.mic")
                    }
                }
                if let albumId = song.albumId {
                    Button {
                        router.navigate(to: .album(id: albumId, preview: nil))
                    } label: {
                        Label(t("options.goto.album"), systemImage: "square.stack")
                    }
                }
            } label: {
                MarqueeText(text: subtitle)
                    .foregroundStyle(.white.opacity(0.65))
            }
            .buttonStyle(.plain)
        } else {
            MarqueeText(text: subtitle)
                .foregroundStyle(.white.opacity(0.65))
        }
    }
}

/// The current song's actions, like the web player menu: add to a
/// playlist, favorite, download, the sleep timer, lyrics settings, the
/// artist and album, and the song's details.
private struct NowPlayingMenuItems: View {
    @Environment(PlayerStore.self) private var player
    @Environment(DownloadsStore.self) private var downloads
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    var body: some View {
        if let song = player.currentSong {
            Section {
                Button {
                    router.present(.addToPlaylist([song]))
                } label: {
                    Label(t("options.playlist.add"), systemImage: "text.badge.plus")
                }
                FavoriteButton(kind: .song, id: song.id)
                downloadButton(song)
            }
        }
        Section {
            SleepTimerMenu {
                Label(t("player.sleepTimer.title"), systemImage: "moon.zzz")
            }
            if player.currentSong != nil {
                Button {
                    router.present(.lyricsSettings)
                } label: {
                    Label(t("fullscreen.selectLyrics"), systemImage: "quote.bubble")
                }
            }
        }
        if let song = player.currentSong {
            Section {
                if let artistId = song.artistId {
                    Button {
                        router.navigate(to: .artist(id: artistId, name: song.artist))
                    } label: {
                        Label(t("options.goto.artist"), systemImage: "music.mic")
                    }
                }
                if let albumId = song.albumId {
                    Button {
                        router.navigate(to: .album(id: albumId, preview: nil))
                    } label: {
                        Label(t("options.goto.album"), systemImage: "square.stack")
                    }
                }
                Button {
                    router.present(.songInfo(song))
                } label: {
                    Label(t("options.info"), systemImage: "info.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func downloadButton(_ song: Song) -> some View {
        let _ = downloads.revision
        switch downloads.state(ofSong: song.id) {
        case .cached(.explicit, _), .downloading:
            Button(role: .destructive) {
                Task { await downloads.remove(songIds: [song.id]) }
            } label: {
                Label(t("options.removeDownload"), systemImage: "trash")
            }
        default:
            Button {
                Task { await downloads.download(songs: [song]) }
            } label: {
                Label(t("options.download"), systemImage: "arrow.down.circle")
            }
        }
    }
}

// MARK: - Remote control and devices

/// Which device is being controlled, with a way back to this one.
private struct RemoteControlCapsule: View {
    @Environment(PlayerStore.self) private var player
    @Environment(CoordinationStore.self) private var coordination
    @Environment(Localizer.self) private var t

    var body: some View {
        if case let .remote(_, deviceName) = player.target {
            HStack(spacing: 10) {
                Label(
                    t("settings.crossDevice.playback.controllingDevice", ["name": deviceName]),
                    systemImage: "hifispeaker.fill"
                )
                .lineLimit(1)
                Button(t("settings.crossDevice.playback.exitControl")) {
                    coordination.stopControlling()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

/// Opens the devices sheet; lit while another device is controlled.
private struct DevicesButton: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    var body: some View {
        let isRemote = player.target.isRemote
        Button {
            router.present(.devices)
        } label: {
            Image(systemName: isRemote ? "hifispeaker.and.homepod.fill" : "hifispeaker.and.homepod")
                .font(.title3.weight(.medium))
                .foregroundStyle(isRemote ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.7)))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("settings.crossDevice.title"))
    }
}

// MARK: - Background

/// The cover's colors in a slowly moving mesh, as behind Apple Music's Now
/// Playing. `intensity` is the color strength setting.
struct NowPlayingBackground: View {
    let palette: ArtworkPalette?
    let intensity: Double
    var isAnimating = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isAnimating)) { context in
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: Self.points(at: context.date.timeIntervalSinceReferenceDate),
                    colors: colors
                )
            }
            .opacity(opacity)
        }
        .animation(.smooth(duration: 0.8), value: palette)
    }

    private var colors: [Color] {
        palette?.meshColors ?? Array(repeating: Color(white: 0.2), count: 9)
    }

    /// 0.5 at the weakest setting, fully opaque at the strongest.
    private var opacity: Double {
        let range = AppearanceSettings.colorIntensityRange
        let normalized = (intensity - range.lowerBound) / (range.upperBound - range.lowerBound)
        return 0.5 + 0.5 * min(max(normalized, 0), 1)
    }

    /// The middle points drift on slow, offset sine waves; the edges stay put.
    nonisolated static func points(at time: TimeInterval) -> [SIMD2<Float>] {
        let t = Float(time.truncatingRemainder(dividingBy: 10_000))
        func drift(_ phase: Float, _ amount: Float) -> Float {
            sin(t * 0.22 + phase) * amount
        }
        return [
            SIMD2(0, 0), SIMD2(0.5 + drift(0, 0.12), 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + drift(1.3, 0.12)),
            SIMD2(0.5 + drift(2.1, 0.16), 0.5 + drift(0.7, 0.16)),
            SIMD2(1, 0.5 + drift(2.9, 0.12)),
            SIMD2(0, 1), SIMD2(0.5 + drift(1.7, 0.12), 1), SIMD2(1, 1),
        ]
    }
}
