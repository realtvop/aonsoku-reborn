import AonsokuKit
import SwiftUI

/// The server addresses, which one is in use, and the library scan, like
/// the web server settings and server management.
struct ServerSettingsView: View {
    @State private var primaryUrl = ""
    @State private var fallbackUrl = ""
    @State private var didPrefill = false
    @State private var isSaving = false
    @State private var scanStatus: ScanStatus?
    @State private var isLoadingScan = false

    @Environment(AppModel.self) private var app
    @Environment(SessionStore.self) private var session
    @Environment(NetworkMonitor.self) private var network
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t
    @Environment(\.locale) private var locale

    var body: some View {
        Form {
            Section {
                URLField(
                    title: t("settings.server.primaryUrl.label"),
                    text: $primaryUrl,
                    prompt: t("settings.server.primaryUrl.placeholder")
                )
            } header: {
                Text(t("settings.server.primaryUrl.label"))
            } footer: {
                Text(t("settings.server.primaryUrl.info"))
            }
            Section {
                URLField(
                    title: t("settings.server.fallbackUrl.label"),
                    text: $fallbackUrl,
                    prompt: t("settings.server.fallbackUrl.placeholder")
                )
            } header: {
                Text(t("settings.server.fallbackUrl.label"))
            } footer: {
                Text(t("settings.server.fallbackUrl.info"))
            }
            Section {
                Button {
                    save()
                } label: {
                    HStack {
                        Text(t(isSaving ? "settings.server.saving" : "settings.server.save"))
                        if isSaving {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isSaving || !network.isOnline)
            }
            Section {
                LabeledContent(t("settings.server.activeUrl.label")) {
                    Text(session.account?.activeUrl ?? t("settings.server.activeUrl.empty"))
                        .textSelection(.enabled)
                }
                LabeledContent(t("settings.server.activeType.label"), value: activeType)
            } footer: {
                Text(t("settings.server.activeType.info"))
            }
            management
        }
        .themedBackground(grouped: true)
        .navigationTitle(t("settings.options.server"))
        .disabled(isSaving)
        .onAppear(perform: prefill)
        .task {
            await loadScanStatus()
        }
    }

    private var activeType: String {
        guard session.account != nil else { return t("settings.server.activeType.none") }
        return t(session.isUsingFallback ? "settings.server.activeType.fallback" : "settings.server.activeType.primary")
    }

    private func prefill() {
        guard !didPrefill, let account = session.account else { return }
        didPrefill = true
        primaryUrl = account.primaryUrl.isEmpty ? account.activeUrl : account.primaryUrl
        fallbackUrl = account.fallbackUrl ?? ""
    }

    private func save() {
        let primary = ServerAddress.normalize(primaryUrl)
        let fallback = ServerAddress.normalize(fallbackUrl)
        guard ServerAddress.isValid(primary) else {
            toasts.show(.key("settings.server.validation.primaryUrl"), style: .error)
            return
        }
        if !fallback.isEmpty, !ServerAddress.isValid(fallback) {
            toasts.show(.key("settings.server.validation.fallbackUrl"), style: .error)
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await session.updateServerUrls(
                    primaryUrl: primary,
                    fallbackUrl: fallback.isEmpty ? nil : fallback
                )
                primaryUrl = primary
                fallbackUrl = fallback
                toasts.success("settings.server.toast.success")
            } catch {
                toasts.show(.key("settings.server.toast.error"), style: .error)
            }
        }
    }

    // MARK: - Management

    private var isLMS: Bool {
        session.account?.isLMS ?? false
    }

    @ViewBuilder
    private var management: some View {
        Section {
            if let scanStatus, !isLMS {
                if let count = scanStatus.count {
                    Text(t("server.songCount", count: count))
                }
                if let folders = scanStatus.folderCount {
                    Text(t("server.folderCount", count: folders))
                }
                if let lastScan = scanStatus.lastScan {
                    Text(t("server.lastScan", ["date": Formatters.dateTime(lastScan, locale: locale)]))
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await loadScanStatus() }
            } label: {
                HStack {
                    Text(t("server.buttons.refresh"))
                    if isLoadingScan || scanStatus?.scanning == true {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isLoadingScan || !network.isOnline)
            Button(t("server.buttons.startScan")) {
                Task { await startScan() }
            }
            .disabled(isLoadingScan || scanStatus?.scanning == true || !network.isOnline)
        } header: {
            Text(t("server.management"))
        }
    }

    private func loadScanStatus() async {
        guard network.isOnline else { return }
        isLoadingScan = true
        defer { isLoadingScan = false }
        do {
            scanStatus = try await app.repository.scanStatus()
        } catch {
            toasts.show(error: error)
        }
    }

    private func startScan() async {
        isLoadingScan = true
        defer { isLoadingScan = false }
        do {
            scanStatus = try await app.repository.startScan()
        } catch {
            toasts.show(error: error)
        }
    }
}
