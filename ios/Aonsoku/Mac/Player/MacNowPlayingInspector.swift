import AonsokuKit
import Perception
import SwiftUI

/// Now Playing beside the content: lyrics and the queue. Filled in by the
/// inspector milestone.
struct MacNowPlayingInspector: View {
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            Text(t("fullscreen.queue"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
