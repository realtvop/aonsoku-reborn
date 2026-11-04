import AonsokuKit
import Perception
import SwiftUI

/// The Settings window (⌘,): the settings pages of the iOS account sheet in
/// a sidebar, as in System Settings, each in its own navigation stack for
/// pages it opens (such as the cache manager). Shared pages that ask for
/// Settings open this window at their page (`Router.openSettings`). Signed
/// out, the pages about the account, its server and its library are left
/// out. Tailscale never shows on a Mac (`TailscaleSupport.isAvailable`).
struct MacSettingsView: View {
    @Environment(Router.self) private var router
    @Environment(SessionStore.self) private var session
    @Environment(Localizer.self) private var t

    @State private var path: [SettingsPage] = []

    var body: some View {
        WithPerceptionTracking {
            NavigationSplitView {
                List(selection: selection) {
                    WithPerceptionTracking {
                        ForEach(groups.indices, id: \.self) { index in
                            Section {
                                ForEach(groups[index], id: \.self) { page in
                                    WithPerceptionTracking {
                                        row(page)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
                .toolbar(removing: .sidebarToggle)
            } detail: {
                WithPerceptionTracking {
                    NavigationStack(path: $path) {
                        SettingsPageView(page: shownPage)
                            .navigationDestination(for: SettingsPage.self) { page in
                                WithPerceptionTracking {
                                    SettingsPageView(page: page)
                                }
                            }
                    }
                    .id(shownPage)
                }
            }
            .frame(minWidth: 720, idealWidth: 800, minHeight: 480, idealHeight: 580)
            .appOnChange(of: router.settingsPage) { path = [] }
        }
    }

    /// The pages in the account sheet's groups, without those that need an
    /// account while signed out.
    private var groups: [[SettingsPage]] {
        let all: [[SettingsPage]] = [
            [.server, .appearance, .language],
            [.playback, .lyrics, .content],
            [.storage, .crossDevice, .privacy],
            [.about],
        ]
        guard !session.isSignedIn else { return all }
        let accountPages: Set<SettingsPage> = [.server, .storage, .crossDevice, .cacheManager]
        return all.map { $0.filter { !accountPages.contains($0) } }.filter { !$0.isEmpty }
    }

    /// The selected page, or the first one shown when it is left out.
    private var shownPage: SettingsPage {
        let pages = groups.flatMap { $0 } + (session.isSignedIn ? [.cacheManager] : [])
        return pages.contains(router.settingsPage) ? router.settingsPage : (pages.first ?? .appearance)
    }

    private var selection: Binding<SettingsPage?> {
        Binding(
            get: { shownPage },
            set: { page in
                if let page { router.settingsPage = page }
            }
        )
    }

    private func row(_ page: SettingsPage) -> some View {
        let label = Self.label(of: page, t)
        return Label {
            Text(label.title)
        } icon: {
            SettingsIcon(systemImage: label.systemImage)
        }
        .tag(page)
    }

    /// The same titles and symbols as the account sheet's rows.
    static func label(of page: SettingsPage, _ t: Localizer) -> (title: String, systemImage: String) {
        switch page {
        case .server: (t("settings.options.server"), symbol(systemImage: "server.rack"))
        case .appearance: (t("settings.options.appearance"), symbol(systemImage: "paintbrush"))
        case .language: (t("settings.options.language"), symbol(systemImage: "globe"))
        case .playback: (t("settings.options.audio"), symbol(systemImage: "headphones"))
        case .lyrics: (t("settings.audio.lyrics.group"), symbol(systemImage: "quote.bubble"))
        case .content: (t("settings.options.content"), symbol(systemImage: "square.grid.2x2"))
        case .storage, .cacheManager: (t("settings.options.storage"), symbol(systemImage: "internaldrive"))
        case .crossDevice: (t("settings.options.cross-device"), symbol(systemImage: "hifispeaker.and.homepod"))
        case .privacy: (t("settings.options.privacy"), symbol(systemImage: "hand.raised"))
        case .about: (t("menu.about"), symbol(systemImage: "info.circle"))
        }
    }

    /// Names an SF Symbol (and tells the strings check it is not a key).
    private static func symbol(systemImage: String) -> String { systemImage }
}
