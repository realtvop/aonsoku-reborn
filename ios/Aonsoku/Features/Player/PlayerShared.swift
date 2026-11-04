import AonsokuKit
import Perception
import SwiftUI

// Player pieces with no UIKit in them, shared by the iOS mini player and Now
// Playing and by the Mac player bar and inspector.

// MARK: - Artwork and titles

/// The cover of what is playing: the song's, a radio badge, or a note
/// while nothing plays.
struct PlayerArtwork: View {
    var cornerRadius: CGFloat = 8
    var size: ArtworkSize = .medium

    @Environment(PlayerStore.self) private var player

    var body: some View {
        WithPerceptionTracking {
            if let song = player.currentSong {
                SongArtwork(song: song, size: size, cornerRadius: cornerRadius)
            } else if player.isRadio {
                RadioBadge(name: player.radio?.current?.name ?? "")
                    .overlay {
                        WithPerceptionTracking {
                            GeometryReader { proxy in
                                WithPerceptionTracking {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                        .font(.system(size: proxy.size.width * 0.32, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                    }
                    .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
                    .aspectRatio(1, contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppStyle.tertiaryFill)
                    .overlay {
                        WithPerceptionTracking {
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
            }
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

// MARK: - Buffering

/// Keep Pause available while showing only sustained local buffering.
struct PlayerBufferingIndicator: View {
    var tint: Color = .white

    @Environment(PlayerStore.self) private var player
    @State private var isVisible = false

    private var isBuffering: Bool {
        player.remoteNowPlaying == nil && player.isPlaying && player.isBuffering
    }

    var body: some View {
        WithPerceptionTracking {
            ProgressView()
                .controlSize(.mini)
                .tint(tint)
                .opacity(isVisible && isBuffering ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .task(id: isBuffering) {
                    isVisible = false
                    guard isBuffering else { return }
                    do {
                        try await Task.sleep(for: .milliseconds(800))
                        try Task.checkCancellation()
                        isVisible = true
                    } catch {
                        // Pausing, finishing the load or changing targets cancels it.
                    }
                }
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
