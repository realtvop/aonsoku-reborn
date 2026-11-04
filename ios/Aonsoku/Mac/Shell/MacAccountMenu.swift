import AonsokuKit
import Perception
import SwiftUI

/// The account in the window's toolbar: who is signed in where, whether the
/// server answers, the library sync with Sync Now, Settings and Sign Out.
/// The server is pinged when the menu opens and when the connection changes,
/// as the iOS account sheet does.
struct MacAccountMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionStore.self) private var session
    @Environment(NetworkMonitor.self) private var network
    @Environment(LibrarySyncStore.self) private var sync
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    @State private var isConfirmingSignOut = false
    @State private var checkRevision = 0
    @State private var label: NSImage?

    var body: some View {
        WithPerceptionTracking {
            Menu {
                WithPerceptionTracking {
                    Section(session.account?.username ?? "") {
                        Text(serverLine)
                        Text(connectionText)
                        if let syncText = SyncPhaseText.text(sync.phase, t, operation: sync.operation) {
                            Text(syncText)
                        } else if let lastSyncedAt = sync.lastSyncedAt {
                            Text("\(t("settings.storage.sync.lastSynced")): \(Formatters.relative(lastSyncedAt, locale: t.locale))")
                        }
                    }
                    .onAppear { checkRevision += 1 }
                    Section {
                        Button(t("settings.storage.sync.syncNow")) {
                            sync.syncNow()
                        }
                        .disabled(sync.isSyncing || !network.isOnline)
                        if sync.isSyncing {
                            Button(t("settings.storage.sync.cancel")) {
                                sync.cancel()
                            }
                        }
                        Button(t("server.buttons.refresh")) {
                            checkRevision += 1
                        }
                        .disabled(!network.isOnline)
                    }
                    Section {
                        Button(t("settings.label")) {
                            router.openSettings()
                        }
                        Button(t("menu.serverLogout"), role: .destructive) {
                            isConfirmingSignOut = true
                        }
                    }
                }
            } label: {
                // A toolbar menu draws its label as an image, so the avatar
                // is rendered into one at the size it shows.
                if let label {
                    Image(nsImage: label)
                } else {
                    Image(systemName: "person.crop.circle")
                }
            }
            .menuIndicator(.hidden)
            .task(id: LabelIdentity(username: session.account?.username ?? "", status: statusColor)) {
                label = await renderLabel()
            }
            .help(helpText)
            .accessibilityLabel(t("native.mac.account.menu"))
            .accessibilityValue(helpText)
            .task(id: CheckIdentity(account: session.account, online: network.isOnline, revision: checkRevision)) {
                if network.isOnline { await session.checkServerConnection() }
            }
            .alert(t("logout.dialog.title"), isPresented: $isConfirmingSignOut) {
                Button(t("logout.dialog.confirm"), role: .destructive) {
                    app.signOut()
                }
                Button(t("logout.dialog.cancel"), role: .cancel) {}
            } message: {
                Text(t("logout.dialog.description"))
            }
        }
    }

    private var serverLine: String {
        guard let account = session.account else { return "" }
        let host = URL(string: account.activeUrl)?.host() ?? account.activeUrl
        return account.serverType.isEmpty ? host : "\(host) · \(account.serverType.capitalized)"
    }

    private var connectionText: String {
        if !network.isOnline { return t("offline.mode") }
        return switch session.serverConnection {
        case .unchecked: t("native.serverConnection.unchecked")
        case .checking: t("native.serverConnection.checking")
        case .available: t("native.serverConnection.available")
        case let .failed(message): "\(t("native.serverConnection.failed")): \(message)"
        }
    }

    private var helpText: String {
        [session.account?.username, serverLine, connectionText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Green while the server answers, orange offline, red when it fails.
    private var statusColor: StatusColor? {
        if !network.isOnline { return .orange }
        return switch session.serverConnection {
        case .available: .green
        case .failed: .red
        case .unchecked, .checking: nil
        }
    }

    private enum StatusColor: Hashable {
        case green, orange, red

        var color: Color {
            switch self {
            case .green: .green
            case .orange: .orange
            case .red: .red
            }
        }
    }

    private struct LabelIdentity: Hashable {
        let username: String
        let status: StatusColor?
    }

    /// The avatar, or the user's initial, with the connection's dot.
    private func renderLabel() async -> NSImage? {
        let username = session.account?.username ?? ""
        let avatar = await app.artwork.avatar(username: username)
        let status = statusColor
        let content = ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(Color.accentColor)
                .overlay {
                    if let avatar {
                        Image(platformImage: avatar).resizable().scaledToFill()
                    } else {
                        Text(username.prefix(1).uppercased())
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
                .clipShape(.circle)
                .frame(width: 22, height: 22)
            if let status {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                    .overlay { Circle().stroke(.white, lineWidth: 1.5) }
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: 24, height: 24)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.nsImage
    }

    private struct CheckIdentity: Hashable {
        let account: ServerAccount?
        let online: Bool
        let revision: Int
    }
}
