import AonsokuKit
import SwiftUI

extension Localizer {
    /// `t("key")` reads like the web `t("key")`.
    func callAsFunction(_ key: String, _ args: [String: String] = [:]) -> String {
        t(key, args)
    }

    func callAsFunction(_ key: String, count: Int, _ args: [String: String] = [:]) -> String {
        t(key, count: count, args)
    }
}

extension View {
    /// Puts the app model, every store and the router in the environment.
    func appEnvironment(_ app: AppModel, router: Router) -> some View {
        environment(app)
            .environment(router)
            .environment(app.localizer)
            .environment(app.settings)
            .environment(app.session)
            .environment(app.network)
            .environment(app.toasts)
            .environment(app.sync)
            .environment(app.home)
            .environment(app.pinned)
            .environment(app.favorites)
            .environment(app.playlists)
            .environment(app.radios)
            .environment(app.history)
            .environment(app.player)
            .environment(app.lyrics)
            .environment(app.downloads)
            .environment(app.coordination)
            .environment(\.locale, app.localizer.locale)
    }
}

extension EnvironmentValues {
    /// The namespace the mini player and Now Playing share for the zoom
    /// transition.
    @Entry var playerNamespace: Namespace.ID?
}

extension View {
    /// Plays `feedback` when `trigger` changes, if haptics are enabled.
    func haptic<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        modifier(HapticModifier(feedback: feedback, trigger: trigger))
    }
}

private struct HapticModifier<T: Equatable>: ViewModifier {
    @Environment(SettingsStore.self) private var settings
    let feedback: SensoryFeedback
    let trigger: T

    func body(content: Content) -> some View {
        content.sensoryFeedback(feedback, trigger: trigger) { _, _ in
            settings.settings.playback.hapticFeedback
        }
    }
}
