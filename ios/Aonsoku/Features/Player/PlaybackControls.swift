import AVKit
import AonsokuKit
import SliderControl
import SwiftUI

// MARK: - Scrubber

/// The position in the song: a bar to drag, the time played and the time
/// left, and the audio quality between them. Radio shows that it is live.
struct PlaybackScrubber: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    /// 0...1 while dragging.
    @State private var dragProgress: Double?
    /// The position just sought to, shown until playback reports it.
    @State private var pendingSeek: (position: TimeInterval, at: Date)?

    var body: some View {
        if player.isRadio {
            live
        } else {
            TimelineView(.animation(minimumInterval: 0.1, paused: !player.isPlaying || dragProgress != nil)) { _ in
                scrubber(position: displayedPosition, duration: player.clock.duration)
            }
        }
    }

    private var displayedPosition: TimeInterval {
        let duration = player.clock.duration
        if let dragProgress {
            return dragProgress * duration
        }
        let position = player.clock.position()
        if let pendingSeek, Date.now.timeIntervalSince(pendingSeek.at) < 1.5,
           abs(position - pendingSeek.position) > 1 {
            return pendingSeek.position
        }
        return position
    }

    private func scrubber(position: TimeInterval, duration: TimeInterval) -> some View {
        let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0
        return SliderControlView(
            value: Binding(
                get: { progress },
                set: { newValue in
                    // The control repeats its final value after editing
                    // ends. Ignore that event so the playback clock resumes.
                    if dragProgress != nil { dragProgress = newValue }
                }
            )
        ) { isEditing in
            if isEditing {
                dragProgress = progress
            } else {
                if let dragProgress, duration > 0 {
                    seek(to: dragProgress * duration)
                }
                dragProgress = nil
            }
        }
        .trackColor(.white.opacity(0.22))
        .progressColor(.white.opacity(0.8), enlarged: .white)
        .progressLabels(
            leading: Formatters.clock(position),
            trailing: "-\(Formatters.clock(max(duration - position, 0)))"
        ) {
            if let quality = player.currentSong.flatMap({ Formatters.quality(of: $0) }) {
                Text(quality)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.12), in: .capsule)
                    .lineLimit(1)
            }
        }
        .disabled(duration <= 0)
        .playerSliderRegion(.progress)
        .accessibilityElement()
        .accessibilityLabel(t("player.tooltips.progress"))
        .accessibilityValue("\(Formatters.clock(position)) / \(Formatters.clock(duration))")
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            let step: TimeInterval = direction == .increment ? 10 : -10
            seek(to: min(max(position + step, 0), duration))
        }
    }

    private func seek(to position: TimeInterval) {
        pendingSeek = (position, .now)
        player.seek(to: position)
    }

    /// Radio has no position: a full bar and the station.
    private var live: some View {
        VStack(spacing: 6) {
            Capsule()
                .fill(.white.opacity(0.8))
                .frame(height: 7)
                .opacity(0.35)
                .frame(height: 24)
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                Text(t("radios.label"))
                    .textCase(.uppercase)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.6))
        }
    }
}

// MARK: - Transport

/// Previous, Play/Pause and Next, as large symbols that light a circle
/// while pressed.
struct TransportControls: View {
    var scale: CGFloat = 1

    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            TransportButton(
                symbol: "backward.fill",
                size: 28 * scale,
                label: t("player.tooltips.previous")
            ) {
                player.previous()
            }
            Spacer(minLength: 0)
            TransportButton(
                symbol: player.isPlaying ? "pause.fill" : "play.fill",
                size: 42 * scale,
                label: t(player.isPlaying ? "player.tooltips.pause" : "player.tooltips.play")
            ) {
                player.togglePlayPause()
            }
            Spacer(minLength: 0)
            TransportButton(
                symbol: "forward.fill",
                size: 28 * scale,
                label: t("player.tooltips.next")
            ) {
                player.next()
            }
            Spacer(minLength: 0)
        }
        .disabled(!player.hasMedia)
        .opacity(player.hasMedia ? 1 : 0.4)
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 1.9, height: size * 1.9)
                .contentShape(.circle)
        }
        .buttonStyle(TransportButtonStyle())
        .accessibilityLabel(label)
    }
}

private struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background {
                Circle()
                    .fill(.white.opacity(configuration.isPressed ? 0.16 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

// MARK: - Volume

/// The output volume, or the controlled device's.
struct VolumeSlider: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    @State private var dragValue: Double?
    @State private var isEditing = false
    @State private var lastSentValue: Double?

    var body: some View {
        let value = dragValue ?? player.volume
        SliderControlView(
            value: Binding(
                get: { value },
                set: { newValue in
                    dragValue = newValue
                    // Keep inertia smooth without a remote command for
                    // every frame. A trailing update sends the exact value.
                    if abs(newValue - (lastSentValue ?? player.volume)) >= 0.01 {
                        sendVolume(newValue)
                    }
                }
            )
        ) { editing in
            isEditing = editing
            if editing {
                dragValue = value
            }
        }
        .trackColor(.white.opacity(0.22))
        .progressColor(.white.opacity(0.8), enlarged: .white)
        .volumeIcons()
        .playerSliderRegion(.volume)
        .task(id: isEditing ? nil : dragValue) {
            guard !isEditing, let dragValue else { return }
            do {
                try await Task.sleep(for: .milliseconds(100))
                if lastSentValue != dragValue {
                    sendVolume(dragValue)
                }
                // Retain the optimistic value through inertia and delayed
                // system/remote echoes, then resume observing output volume.
                try await Task.sleep(for: .seconds(1.5))
                self.dragValue = nil
                lastSentValue = nil
            } catch {}
        }
        .accessibilityElement()
        .accessibilityLabel(t("native.player.volume"))
        .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.1 : -0.1
            let nextValue = min(max(value + step, 0), 1)
            dragValue = nextValue
            sendVolume(nextValue)
        }
    }

    private func sendVolume(_ value: Double) {
        lastSentValue = value
        player.setVolume(value)
    }
}

// MARK: - AirPlay

/// The system AirPlay and Bluetooth route picker.
struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.65)
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

// MARK: - Sleep timer

/// Pauses after a number of minutes or at the end of the song.
struct SleepTimerMenu<Label: View>: View {
    @ViewBuilder let label: Label

    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    var body: some View {
        Menu {
            if player.sleepTimer.isActive {
                Button(role: .destructive) {
                    player.cancelSleepTimer()
                } label: {
                    SwiftUI.Label(t("player.sleepTimer.cancel"), systemImage: "xmark.circle")
                }
            }
            Section(t("player.sleepTimer.title")) {
                ForEach(SleepTimerState.presetMinutes, id: \.self) { minutes in
                    Button(t("player.sleepTimer.minutes", ["count": String(minutes)])) {
                        player.setSleepTimer(minutes: minutes)
                    }
                }
                Button {
                    player.setSleepTimerEndOfTrack()
                } label: {
                    if player.sleepTimer == .endOfTrack {
                        SwiftUI.Label(t("player.sleepTimer.endOfTrack"), systemImage: "checkmark")
                    } else {
                        Text(t("player.sleepTimer.endOfTrack"))
                    }
                }
            }
        } label: {
            label
        }
    }
}

/// What the sleep timer will do: the time left, or the end of the song.
struct SleepTimerStatus: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    var body: some View {
        switch player.sleepTimer {
        case .off:
            EmptyView()
        case .endOfTrack:
            Text(t("player.sleepTimer.endOfTrack"))
        case let .countdown(endsAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(t(
                    "player.sleepTimer.remaining",
                    ["time": Formatters.clock(max(endsAt.timeIntervalSince(context.date), 0))]
                ))
                .monospacedDigit()
            }
        }
    }
}
