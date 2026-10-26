import AonsokuKit
import Perception
import SwiftUI

/// Now Playing, modeled on Apple Music: the cover over its own colors,
/// shrinking while paused, the song with Favorite and More, the scrubber,
/// transport and volume, and a bar for lyrics, AirPlay, Aonsoku devices
/// and the queue. Lyrics and the queue move the cover into a compact
/// header; on a wide iPad they open beside it.
struct NowPlayingView: View {
    @State private var lyricsControlsHidden = false
    @State private var metadataHeight: CGFloat = 64
    @State private var panelsEnteringFromCover = false

    @Environment(PlayerStore.self) private var player
    @Environment(LyricsStore.self) private var lyrics
    @Environment(Localizer.self) private var t
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(Router.self) private var router
    @Environment(PlayerPresentationState.self) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var panel: PlayerPanel? { presentation.panel }

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { proxy in
                WithPerceptionTracking {
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
                    // Keep layout and native scroll geometry immediate. Individual
                    // content surfaces opt into their own visual-only animations.
                    .animation(nil, value: panel)
                    .appOnChange(of: isWide, initial: true) { _, isWide in
                        presentation.usesWideLayout = isWide
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
            .appOnChange(of: player.hasMedia) { _, hasMedia in
                if !hasMedia {
                    router.isNowPlayingPresented = false
                }
            }
            .appOnChange(of: player.isRadio) { _, isRadio in
                if isRadio {
                    selectPanel(nil)
                }
            }
            .appOnChange(of: panel) { lyricsControlsHidden = false }
            .appOnChange(of: router.isNowPlayingPresented) { lyricsControlsHidden = false }
            .appOnChange(of: player.currentSong?.id) { lyricsControlsHidden = false }
            .appOnChange(of: bottomControlsHidden, initial: true) {
                presentation.arePlaybackControlsVisible = !bottomControlsHidden
            }
            .appOnChange(of: panel == .queue && router.isNowPlayingPresented, initial: true) {
                presentation.queueOwnsScrollGestures = panel == .queue && router.isNowPlayingPresented
            }
            .accessibilityAction(.escape) {
                router.isNowPlayingPresented = false
            }
            .globalPresentations(.nowPlaying)
        }
    }

    // MARK: - Layouts

    private var compactLayout: some View {
        VStack(spacing: 0) {
            grabber
            statusCapsules
            GeometryReader { proxy in
                WithPerceptionTracking {
                    PlayerContentLayout {
                        largeArtwork
                        headerArtwork
                            .opacity(panel == .lyrics ? 1 : 0)
                            .allowsHitTesting(panel == .lyrics)
                            .accessibilityHidden(panel != .lyrics)
                        Color.clear
                            .frame(height: 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        measuredTitleRow(isCompact: true)
                            .modifier(PlayerPageContent(
                                isVisible: panel == .lyrics,
                                riseDistance: panel == nil ? 64 : 0,
                                isMetadata: true,
                                entranceDelay: panelsEnteringFromCover ? 0.16 : 0
                            ))
                        panels(showsQueueHeader: true)
                    }
                    .frame(maxHeight: .infinity)
                    .clipped()
                }
            }
            bottomControls
        }
    }

    private var wideLayout: some View {
        HStack(spacing: panel == nil ? 0 : 56) {
            VStack(spacing: 0) {
                grabber
                statusCapsules
                largeArtwork
                    .padding(.vertical, 20)
                    .frame(maxHeight: .infinity)
                bottomControls
            }
            .frame(maxWidth: 500)
            panels(showsQueueHeader: false)
                .frame(maxWidth: panel == nil ? 0 : 620, maxHeight: .infinity)
                .padding(.vertical, 40)
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pieces

    private func selectPanel(_ panel: PlayerPanel?) {
        // Reset the hidden List and its artwork target before selecting it,
        // so the transition never starts at the previous scroll position.
        if panel == .queue { presentation.prepareQueueForPresentation?() }
        panelsEnteringFromCover = self.panel == nil && panel != nil
        lyricsControlsHidden = false
        presentation.panel = panel
    }

    private func coverMetadataTransition(in height: CGFloat) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 64).combined(with: .opacity),
            removal: .offset(y: -max(height - metadataHeight - 16, 0))
                .combined(with: .scale(scale: 0.85, anchor: .leading))
                .combined(with: .opacity)
        )
    }

    private var grabber: some View {
        Button {
            router.isNowPlayingPresented = false
        } label: {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 38, height: 5)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.touchFeedback)
        .accessibilityLabel(t("fullscreen.switchButton"))
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
                        .appGlass(in: .capsule)
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

    private func titleRow(isCompact: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: NowPlayingText.title(player, t))
                    .displayFont(.player)
                    .accessibilityAddTraits(.isHeader)
                ArtistMenu()
            }
            .scaleEffect(isCompact ? 17.0 / 20.0 : 1, anchor: .leading)
            Spacer(minLength: 0)
            songButtons
        }
    }

    private func measuredTitleRow(isCompact: Bool) -> some View {
        titleRow(isCompact: isCompact)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { metadataHeight = $0 }
    }

    private var headerArtwork: some View {
        Button {
            selectPanel(nil)
        } label: {
            PlayerArtworkSlot(location: .header, cornerRadius: 8, shadowRadius: 10)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("fullscreen.playing"))
    }

    @ViewBuilder
    private var songButtons: some View {
        HStack(spacing: 4) {
            if let song = player.currentSong {
                NowPlayingFavoriteButton(songId: song.id)
            }
            Menu {
                NowPlayingMenuItems()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.touchFeedback)
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

    private var presentationAnimation: Animation {
        PlayerPresentationState.panelAnimation(reduceMotion: reduceMotion)
    }

    private var controlsTransitionOffset: CGFloat {
        if reduceMotion { return 0 }
        let baseOffset: CGFloat = presentation.isExpanded ? 0 : 40
        let dragShift = min(max(presentation.dragOffset * 0.25, 0), 60)
        return baseOffset + dragShift
    }

    private var controlsTransitionOpacity: Double {
        guard presentation.isExpanded else { return 0 }
        if presentation.dragOffset > 0 {
            return max(0, 1 - Double(presentation.dragOffset) / 220.0)
        }
        return 1
    }

    /// Keep slider state alive while the entire footer gives space to lyrics.
    private var bottomControls: some View {
        VStack(spacing: 0) {
            if panel == nil {
                titleRow(isCompact: false)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 6)
            }
            controls
                .padding(.top, panel == nil ? 8 : 0)
            bottomBar
        }
        .fixedSize(horizontal: false, vertical: true)
        // Page-specific metadata grows upward from the fixed button row.
        // Reusing a measured height here briefly lays out the new page in
        // the previous page's height and moves the buttons for one frame.
        .frame(height: bottomControlsHidden ? 0 : nil, alignment: .bottom)
        .offset(y: controlsTransitionOffset)
        .opacity(bottomControlsHidden ? 0 : controlsTransitionOpacity)
        .animation(presentationAnimation, value: presentation.isExpanded)
        .animation(presentationAnimation, value: presentation.dragOffset == 0)
        .clipped()
        .allowsHitTesting(!bottomControlsHidden && presentation.isExpanded)
        .accessibilityHidden(bottomControlsHidden || !presentation.isExpanded)
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

    private func panelButton(_ target: PlayerPanel, symbol: String, label: String) -> some View {
        let isOn = panel == target
        return Button {
            selectPanel(isOn ? nil : target)
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(isOn ? .black : .white.opacity(0.7))
                .frame(width: 44, height: 44)
                .background(.white.opacity(isOn ? 0.92 : 0), in: .circle)
                .contentShape(.rect)
                .animation(.easeInOut(duration: 0.2), value: isOn)
        }
        .buttonStyle(.touchFeedback)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Keep both pages mounted and animate their appearance locally, without
    /// animating List layout, scroll resets or the shared artwork markers.
    private func panels(showsQueueHeader: Bool) -> some View {
        ZStack {
            LyricsPanel(isActive: panel == .lyrics && router.isNowPlayingPresented) { hidden in
                lyricsControlsHidden = hidden
            }
            .padding(.top, showsQueueHeader ? (metadataHeight + 16) : 0)
            .modifier(PlayerPageContent(isVisible: panel == .lyrics))
            QueuePanel(
                isActive: panel == .queue && router.isNowPlayingPresented,
                showsCurrentTrack: showsQueueHeader,
                currentHeaderHeight: max(64, metadataHeight),
                metadataEntranceDelay: panelsEnteringFromCover ? 0.16 : 0,
                onShowCover: { selectPanel(nil) }
            ) { titleRow(isCompact: true) }
            .padding(.horizontal, 30)
            .allowsHitTesting(panel == .queue)
            .accessibilityHidden(panel != .queue)
        }
        .allowsHitTesting(panel != nil)
        .accessibilityHidden(panel == nil)
        .clipped()
    }
}

/// Body content floats up a short distance after the outgoing page fades.
/// Compact metadata crossfades in place between the lyrics and queue pages.
/// Hidden pages retain state but relinquish touches and accessibility focus.
struct PlayerPageContent: ViewModifier {
    var isVisible: Bool
    var riseDistance: CGFloat = 24
    var isMetadata = false
    var entranceDelay: Double = 0.14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                // Only the reveal interpolates. Native List layout and scroll
                // preparation must never inherit the page animation transaction.
                .transaction { $0.animation = nil }
                .modifier(PlayerPageReveal(
                    progress: isVisible ? 1 : 0,
                    riseDistance: reduceMotion ? 0 : riseDistance
                ))
                .animation(animation, value: isVisible)
                .allowsHitTesting(isVisible)
                .accessibilityHidden(!isVisible)
        }
    }

    private var animation: Animation {
        if reduceMotion { return .linear(duration: 0.15) }
        if isMetadata {
            return .easeInOut(duration: 0.22).delay(isVisible ? entranceDelay : 0)
        }
        return isVisible
            ? .spring(duration: 0.38, bounce: 0).delay(entranceDelay)
            : .easeOut(duration: 0.18)
    }
}

/// Interpolate the render offset explicitly: applying offset inside SwiftUI's
/// scoped animation closure can jump native-backed content to its endpoint.
private struct PlayerPageReveal: AnimatableModifier {
    var progress: CGFloat
    var riseDistance: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .offset(y: (1 - progress) * riseDistance)
                .opacity(Double(progress))
        }
    }
}

/// Both metadata layouts and artwork destinations stay at their final
/// coordinates while their content rises into view. The presentation host
/// moves the sole artwork separately.
private struct PlayerContentLayout: SwiftUI.Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 5 else { return }
        let titleWidth = max(bounds.width - 60, 0)
        let headerWidth = max(bounds.width - 138, 0)
        let titleSize = subviews[2].sizeThatFits(ProposedViewSize(width: titleWidth, height: nil))
        let headerSize = subviews[3].sizeThatFits(ProposedViewSize(width: headerWidth, height: nil))
        let headerHeight = max(64, headerSize.height)
        let coverHeight = max(bounds.height - titleSize.height - 24, 0)
        let coverSide = max(min(bounds.width - 60, coverHeight), 0)

        subviews[0].place(
            at: CGPoint(x: bounds.midX - coverSide / 2, y: bounds.minY + 12 + (coverHeight - coverSide) / 2),
            proposal: ProposedViewSize(width: coverSide, height: coverSide)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + 30, y: bounds.minY + 8 + (headerHeight - 64) / 2),
            proposal: ProposedViewSize(width: 64, height: 64)
        )
        subviews[2].place(
            at: CGPoint(x: bounds.minX + 30, y: bounds.maxY - titleSize.height),
            proposal: ProposedViewSize(width: titleWidth, height: titleSize.height)
        )
        subviews[3].place(
            at: CGPoint(x: bounds.minX + 108, y: bounds.minY + 8 + (headerHeight - headerSize.height) / 2),
            proposal: ProposedViewSize(width: headerWidth, height: headerSize.height)
        )
        subviews[4].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
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
        WithPerceptionTracking {
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
}

/// The current song's heart: red and filled while it is a favorite, as in
/// the web player.
private struct NowPlayingFavoriteButton: View {
    let songId: String

    @Environment(FavoritesStore.self) private var favorites
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            let isFavorite = favorites.isFavorite(.song, id: songId)
            Button {
                Task { await favorites.toggle(.song, id: songId) }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isFavorite ? Color.red : Color.white)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .appSymbolTransition()
                    .appSymbolBounce(value: isFavorite)
            }
            .buttonStyle(.touchFeedback)
            .accessibilityLabel(t(isFavorite ? "options.unlike" : "options.like"))
            .haptic(.lightImpact, trigger: isFavorite)
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
        WithPerceptionTracking {
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
                .appGlass(in: .capsule)
            }
        }
    }
}

/// Opens the devices sheet; lit while another device is controlled.
private struct DevicesButton: View {
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
                    .font(.title3.weight(.medium))
                    .foregroundStyle(isRemote ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.7)))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.touchFeedback)
            .accessibilityLabel(t("settings.crossDevice.title"))
        }
    }
}

// MARK: - Background

/// One opaque fill for every player page and pinned header. Blending the
/// colors before drawing avoids translucent layers and conditional insertion
/// transitions exposing the dark theme underneath.
struct NowPlayingBackground: View {
    @Environment(\.nowPlayingPalette) private var palette
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WithPerceptionTracking {
            let appearance = settings.settings.appearance
            let base = appearance.darkTheme.palette.background
            let cover = (palette?.average ?? palette?.colors.first).map(Color.init) ?? base
            base.appMix(with: cover, by: min(max(appearance.nowPlayingColorIntensity, 0), 1))
                .animation(reduceMotion ? .linear(duration: 0.15) : .smooth(duration: 0.6), value: palette)
        }
    }
}

extension EnvironmentValues {
    @Entry var nowPlayingPalette: ArtworkPalette?
}
