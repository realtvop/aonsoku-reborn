import AonsokuKit
import Perception
import SwiftUI

/// The player along the bottom of the window. Filled in by the player
/// milestone; for now the song and Play/Pause.
struct MacPlayerBar: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            if player.hasMedia {
                HStack {
                    Text(player.currentSong?.title ?? "")
                    Spacer()
                    Button(t(player.isPlaying ? "player.tooltips.pause" : "player.tooltips.play")) {
                        player.togglePlayPause()
                    }
                }
                .padding()
                .background(.bar)
            }
        }
    }
}
