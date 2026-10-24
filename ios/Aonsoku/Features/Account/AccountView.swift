import AonsokuKit
import SwiftUI

/// The account sheet, opened from the avatar: who is signed in to which
/// server, the connection and library sync, every settings page, About and
/// Sign Out.
struct AccountView: View {
    @State private var isConfirmingSignOut = false

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.accountPath) {
            ThemedList {
                Section {
                    AccountHeader()
                }
                Section {
                    row(.server, t("settings.options.server"), systemImage: "server.rack")
                    row(.appearance, t("settings.options.appearance"), systemImage: "paintbrush")
                    row(.language, t("settings.options.language"), systemImage: "globe")
                }
                Section {
                    row(.playback, t("settings.options.audio"), systemImage: "headphones")
                    row(.lyrics, t("settings.audio.lyrics.group"), systemImage: "quote.bubble")
                    row(.content, t("settings.options.content"), systemImage: "square.grid.2x2")
                }
                Section {
                    row(.storage, t("settings.options.storage"), systemImage: "internaldrive")
                    row(.crossDevice, t("settings.options.cross-device"), systemImage: "hifispeaker.and.homepod")
                    row(.privacy, t("settings.options.privacy"), systemImage: "hand.raised")
                }
                Section {
                    row(.about, t("menu.about"), systemImage: "info.circle")
                }
                Section {
                    Button(t("menu.serverLogout"), role: .destructive) {
                        isConfirmingSignOut = true
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(t("settings.label"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                SettingsPageView(page: page)
            }
            .alert(t("logout.dialog.title"), isPresented: $isConfirmingSignOut) {
                Button(t("logout.dialog.confirm"), role: .destructive) {
                    dismiss()
                    app.signOut()
                }
                Button(t("logout.dialog.cancel"), role: .cancel) {}
            } message: {
                Text(t("logout.dialog.description"))
            }
        }
        .globalPresentations(.account)
    }

    private func row(_ page: SettingsPage, _ title: String, systemImage: String) -> some View {
        NavigationLink(value: page) {
            Label {
                Text(title)
            } icon: {
                SettingsIcon(systemImage: systemImage)
            }
        }
    }
}

/// The avatar, user and server, with the connection and library sync.
private struct AccountHeader: View {
    @Environment(SessionStore.self) private var session
    @Environment(NetworkMonitor.self) private var network
    @Environment(LibrarySyncStore.self) private var sync
    @Environment(Localizer.self) private var t

    var body: some View {
        HStack(spacing: 14) {
            AvatarImage(username: session.account?.username ?? "", size: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.account?.username ?? "")
                    .displayFont(.section)
                    .lineLimit(1)
                Text(serverLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                status
                    .font(.footnote.weight(.medium))
            }
        }
        .padding(.vertical, 4)
    }

    private var serverLine: String {
        guard let account = session.account else { return "" }
        let host = URL(string: account.activeUrl)?.host() ?? account.activeUrl
        return account.serverType.isEmpty ? host : "\(host) · \(account.serverType.capitalized)"
    }

    @ViewBuilder
    private var status: some View {
        if !network.isOnline {
            Label(t("offline.mode"), systemImage: "wifi.slash")
                .foregroundStyle(.orange)
        } else if let text = SyncPhaseText.text(sync.phase, t) {
            HStack(spacing: 6) {
                if sync.isSyncing {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(text)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Label(t("settings.crossDevice.connectionState.connected"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}

/// The library sync phase as the web describes it; nil while idle.
enum SyncPhaseText {
    static func text(_ phase: LibrarySyncPhase, _ t: Localizer) -> String? {
        switch phase {
        case .idle:
            return nil
        case let .syncing(tier, processed, total):
            let label = switch tier {
            case "t1": t("settings.storage.sync.tier.t1.label")
            case "t2": t("settings.storage.sync.tier.t2.label")
            case "t3": t("settings.storage.sync.tier.t3.label")
            default: t("settings.storage.sync.phases.idle")
            }
            return total > 0 ? "\(label) \(processed)/\(total)" : label
        case let .coverArt(processed, total):
            let label = t("settings.storage.sync.phases.coverArt")
            return total > 0 ? "\(label) \(processed)/\(total)" : label
        case .done:
            return t("settings.storage.sync.phases.done")
        case .cancelled:
            return t("settings.storage.sync.phases.cancelled")
        case .failed:
            return t("settings.storage.sync.phases.error")
        }
    }
}

/// The page for a settings route.
struct SettingsPageView: View {
    let page: SettingsPage

    var body: some View {
        switch page {
        case .server: ServerSettingsView()
        case .appearance: AppearanceSettingsView()
        case .language: LanguageSettingsView()
        case .playback: PlaybackSettingsView()
        case .lyrics: LyricsPreferencesView()
        case .content: ContentSettingsView()
        case .storage: StorageSettingsView()
        case .cacheManager: CacheManagerView()
        case .crossDevice: CrossDeviceSettingsView()
        case .privacy: PrivacySettingsView()
        case .about: AboutView()
        }
    }
}

extension View {
    /// The web's root page header, for Home and Library: the title at the
    /// leading edge of the navigation bar, on the same row as the account
    /// avatar. It stays there when the page scrolls under the bar instead
    /// of moving to the middle. Pages pushed on top set their own title
    /// display mode, since they would otherwise inherit this inline one.
    func rootPageHeader(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(title)
                        .displayFont(.rootTitle)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    AccountButton()
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }
}

/// The signed-in user's avatar, opening the account sheet.
struct AccountButton: View {
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    var body: some View {
        Button {
            router.openSettings()
        } label: {
            AvatarImage(username: session.account?.username ?? "", size: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("settings.label"))
    }
}
