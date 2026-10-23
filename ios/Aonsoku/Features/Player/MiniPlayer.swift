import AonsokuKit
import SwiftUI

/// The player in the tab bar accessory, as in Apple Music: the cover, the
/// song, Play/Pause and Next. A tap opens Now Playing. Beside the minimized
/// tab bar it keeps the cover, the title and Play/Pause.
struct MiniPlayer: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.playerNamespace) private var namespace

    private var isInline: Bool {
        placement == .inline
    }

    var body: some View {
        HStack(spacing: isInline ? 7 : 10) {
            PlayerArtwork(cornerRadius: isInline ? 4 : 5, size: .small)
                .frame(width: isInline ? 26 : 34, height: isInline ? 26 : 34)
            titles
            Spacer(minLength: 4)
            controls
        }
        .padding(.leading, isInline ? 7 : 10)
        .padding(.trailing, isInline ? 3 : 7)
        .foregroundStyle(.black)
        .contentShape(.rect)
        .onTapGesture {
            open()
        }
        .zoomSource(in: namespace)
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
        VStack(alignment: .leading, spacing: isInline ? 0 : 1) {
            Text(NowPlayingText.title(player, t))
                .font(isInline ? .caption.weight(.semibold) : .footnote.weight(.semibold))
                .lineLimit(1)
            subtitle
                .font(isInline ? .caption2 : .caption)
                .lineLimit(1)
        }
    }

    /// The controlled device, the artist, or Radio.
    @ViewBuilder
    private var subtitle: some View {
        if case let .remote(_, deviceName) = player.target {
            Label(deviceName, systemImage: "hifispeaker.fill")
                .labelStyle(.titleAndIcon)
        } else if let subtitle = NowPlayingText.subtitle(player, t) {
            Text(subtitle)
        }
    }

    @ViewBuilder
    private var controls: some View {
        Button {
            player.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(isInline ? .body : .title3)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .contentShape(.rect)
        }
        .accessibilityLabel(t(player.isPlaying ? "player.tooltips.pause" : "player.tooltips.play"))
        if !isInline {
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel(t("player.tooltips.next"))
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

extension View {
    /// Marks the view the Now Playing zoom transition grows from.
    @ViewBuilder
    func zoomSource(in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: NowPlayingView.transitionID, in: namespace)
        } else {
            self
        }
    }
}
