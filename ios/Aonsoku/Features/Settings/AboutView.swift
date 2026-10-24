import AonsokuKit
import SwiftUI
import UIKit

/// The app's version and build, the server's type and API version, and the
/// project link, like the web About dialog.
struct AboutView: View {
    @State private var serverInfo: ServerInfo?
    @State private var isLoadingServer = false

    @Environment(SessionStore.self) private var session
    @Environment(NetworkMonitor.self) private var network
    @Environment(Localizer.self) private var t
    @Environment(\.locale) private var locale

    var body: some View {
        ThemedList {
            Section {
                VStack(spacing: 10) {
                    AppIconImage()
                        .frame(width: 88, height: 88)
                    Text(verbatim: AppInfo.name)
                        .displayFont(.title)
                    Text(verbatim: AppInfo.version)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section(t("about.client")) {
                LabeledContent(t("about.version")) {
                    // The web shows the commit beside the version.
                    Text(verbatim: [
                        "\(AppInfo.version) (\(AppInfo.build))",
                        AppInfo.buildHash,
                    ].compactMap(\.self).joined(separator: " · "))
                    .monospacedDigit()
                    .textSelection(.enabled)
                }
                LabeledContent(t("about.buildTime")) {
                    Text(AppInfo.buildDate.map { Formatters.dateTime($0, locale: locale) } ?? "dev")
                }
            }

            Section(t("about.server")) {
                if isLoadingServer, serverInfo == nil {
                    LabeledContent(t("generic.loading")) {
                        ProgressView()
                    }
                } else {
                    LabeledContent(t("about.type"), value: serverType)
                    if let version = serverInfo?.serverVersion, !version.isEmpty {
                        LabeledContent(t("about.version"), value: version)
                    }
                    LabeledContent(t("about.apiVersion"), value: apiVersion)
                }
            }

            Section {
                Link(destination: AppInfo.repositoryURL) {
                    Label {
                        Text(verbatim: "GitHub")
                    } icon: {
                        SettingsIcon(systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                .contextMenu {
                    ShareLink(item: AppInfo.repositoryURL)
                }
            } footer: {
                Text(verbatim: AppInfo.repositoryURL.absoluteString)
            }
        }
        .navigationTitle(t("menu.about"))
        .task(id: network.isOnline) {
            await loadServerInfo()
        }
    }

    /// The server as it answered, else as it answered at sign-in.
    private var serverType: String {
        let type = serverInfo?.type ?? session.account?.serverType ?? ""
        return type.isEmpty ? "—" : type
    }

    private var apiVersion: String {
        let version = serverInfo?.protocolVersion ?? session.account?.protocolVersion ?? ""
        guard !version.isEmpty else { return "—" }
        return serverInfo?.isOpenSubsonic == true ? "\(version) · OpenSubsonic" : version
    }

    private func loadServerInfo() async {
        guard network.isOnline else { return }
        isLoadingServer = true
        defer { isLoadingServer = false }
        if let info = await session.serverInfo() {
            serverInfo = info
        }
    }
}

/// The installed app's name, version and build, as the web `getAppInfo`.
enum AppInfo {
    static let name = "Aonsoku"
    static let repositoryURL = URL(string: "https://github.com/realtvop/aonsoku-reborn")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// The commit the build came from; CI sets `AONSOKU_BUILD_HASH`.
    static var buildHash: String? {
        let hash = Bundle.main.object(forInfoDictionaryKey: "AonsokuBuildHash") as? String ?? ""
        return hash.isEmpty || hash.hasPrefix("$(") ? nil : hash
    }

    /// When the executable was linked.
    static var buildDate: Date? {
        guard let path = Bundle.main.executablePath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attributes[.creationDate] as? Date ?? attributes[.modificationDate] as? Date
    }
}

/// The app icon from the bundle, rounded like the Home Screen's.
private struct AppIconImage: View {
    var body: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: proxy.size.width * 0.225, style: .continuous)
            Group {
                if let icon = Self.icon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: proxy.size.width * 0.45, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.accentColor.gradient)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .accessibilityHidden(true)
    }

    private static let icon: UIImage? = {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else {
            return nil
        }
        return UIImage(named: name)
    }()
}
