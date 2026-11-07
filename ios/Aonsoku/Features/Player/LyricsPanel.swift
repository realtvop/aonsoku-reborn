import AonsokuKit
import Perception
import SwiftUI

/// The playing song's lyrics. Synced lyrics (`SyncedLyrics`) follow the song
/// with the web player's Apple Music Like Lyrics motion; a tap on a line plays
/// from it, and scrolling by hand pauses the following for a moment.
struct LyricsPanel: View {
    var isActive = true
    var onControlsHiddenChange: (Bool) -> Void = { _ in }

    @Environment(PlayerStore.self) private var player
    @Environment(LyricsStore.self) private var lyrics
    @Environment(SettingsStore.self) private var settings
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            Group {
                switch lyrics.state {
                case .idle, .loading:
                    message(t("fullscreen.loadingLyrics")) {
                        ProgressView()
                            .tint(.white)
                    }
                case .unavailable:
                    message(t("fullscreen.noLyrics"), systemImage: "quote.bubble") {
                        settingsButton
                    }
                case .disabled:
                    message(t("lyrics.customSelect.lyricsDisabled"), systemImage: "eye.slash") {
                        settingsButton
                    }
                case let .loaded(songLyrics):
                    if songLyrics.isSynced {
                        SyncedLyrics(
                            lyrics: songLyrics, showsTranslation: showsTranslation,
                            isActive: isActive, onControlsHiddenChange: onControlsHiddenChange
                        )
                    } else {
                        PlainLyrics(
                            lyrics: songLyrics, showsTranslation: showsTranslation,
                            isActive: isActive, onControlsHiddenChange: onControlsHiddenChange
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .simultaneousGesture(TapGesture().onEnded {
                if isActive { onControlsHiddenChange(false) }
            })
        }
    }

    private var showsTranslation: Bool {
        settings.settings.lyrics.showTranslation
    }

    private var settingsButton: some View {
        Button(t("fullscreen.selectLyrics")) {
            router.present(.lyricsSettings)
        }
        .appGlassButtonStyle()
    }

    private func message<Accessory: View>(
        _ text: String,
        systemImage: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(text)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            accessory()
        }
        .padding(32)
    }
}

// MARK: - Plain

private struct PlainLyrics: View {
    let lyrics: SongLyrics
    let showsTranslation: Bool
    let isActive: Bool
    let onControlsHiddenChange: (Bool) -> Void

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(lyrics.lines) { line in
                        WithPerceptionTracking {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.text)
                                    .font(.title3.weight(.semibold))
                                if showsTranslation, let translation = line.translation, !translation.isEmpty {
                                    Text(translation)
                                        .font(.body.weight(.medium))
                                        .opacity(0.75)
                                }
                            }
                        }
                    }
                    LyricsCredit(lyrics: lyrics)
                }
                .foregroundStyle(.white.opacity(0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 40)
            }
            .scrollIndicators(.hidden)
            .modifier(LyricsControlsScrollObserver(
                isActive: isActive, onControlsHiddenChange: onControlsHiddenChange
            ))
            .mask(EdgeFade())
        }
    }
}

/// React only to browsing gestures, never playback following or viewport
/// changes caused by the footer itself. Accumulation filters finger jitter.
struct LyricsControlsScrollObserver: ViewModifier {
    let isActive: Bool
    let onControlsHiddenChange: (Bool) -> Void

    @State private var isUserScrolling = false
    @State private var travel: CGFloat = 0

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .appOnScrollPhaseChange { _, phase in
                    isUserScrolling = phase == .interacting || phase == .decelerating
                    if !isUserScrolling { travel = 0 }
                }
                .appOnScrollGeometryChange(for: LyricsScrollMetrics.self) { geometry in
                    let maximum = max(
                        geometry.contentSize.height + geometry.contentInsets.top
                            + geometry.contentInsets.bottom - geometry.containerSize.height, 0
                    )
                    return LyricsScrollMetrics(
                        offset: min(max(geometry.contentOffset.y + geometry.contentInsets.top, 0), maximum),
                        viewportHeight: geometry.containerSize.height,
                        contentHeight: geometry.contentSize.height
                    )
                } action: { old, new in
                    guard isActive, isUserScrolling,
                          abs(new.viewportHeight - old.viewportHeight) < 0.5,
                          abs(new.contentHeight - old.contentHeight) < 0.5 else {
                        travel = 0
                        return
                    }
                    let delta = new.offset - old.offset
                    guard delta != 0 else { return }
                    if new.offset <= 0 {
                        onControlsHiddenChange(false)
                        travel = 0
                    } else {
                        travel = delta > 0 ? max(travel, 0) + delta : min(travel, 0) + delta
                        if abs(travel) >= 20 {
                            onControlsHiddenChange(travel > 0)
                            travel = 0
                        }
                    }
                }
                .appOnChange(of: isActive) {
                    isUserScrolling = false
                    travel = 0
                }
        }
    }
}

private struct LyricsScrollMetrics: Equatable {
    let offset: CGFloat
    let viewportHeight: CGFloat
    let contentHeight: CGFloat
}

/// Who wrote the lyrics, when known, and where they came from.
struct LyricsCredit: View {
    let lyrics: SongLyrics

    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            let source = t("settings.audio.lyrics.source.\(lyrics.source.rawValue)")
            let parts = [lyrics.credit, source].compactMap { $0 }.filter { !$0.isEmpty }
            Text(parts.joined(separator: " · "))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 12)
        }
    }
}

/// Fades content out at the top and bottom edges.
struct EdgeFade: View {
    var top: CGFloat = 36
    var bottom: CGFloat = 36

    init(length: CGFloat = 36) {
        self.top = length
        self.bottom = length
    }

    init(top: CGFloat, bottom: CGFloat) {
        self.top = top
        self.bottom = bottom
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: top)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: bottom)
            }
        }
    }
}
