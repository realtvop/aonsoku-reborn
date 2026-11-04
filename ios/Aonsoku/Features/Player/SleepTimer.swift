import AonsokuKit
import Perception
import SwiftUI

/// Pauses after a number of minutes or at the end of the song.
struct SleepTimerMenu<Label: View>: View {
    @ViewBuilder let label: Label

    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
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
                        WithPerceptionTracking {
                            Button(t("player.sleepTimer.minutes", ["count": String(minutes)])) {
                                player.setSleepTimer(minutes: minutes)
                            }
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
}

/// What the sleep timer will do: the time left, or the end of the song.
struct SleepTimerStatus: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
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
}
