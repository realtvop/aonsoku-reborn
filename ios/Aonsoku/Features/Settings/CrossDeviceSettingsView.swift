import AonsokuKit
import SwiftUI
import UIKit

/// The coordination server connection, this device and the devices bound
/// to the account, like the web cross-device settings.
struct CrossDeviceSettingsView: View {
    @State private var serverUrl = ""
    @State private var identityUrl = ""
    @State private var deviceName = ""
    @State private var didPrefill = false
    @State private var isConnecting = false
    @State private var isConfirmingDisconnect = false
    @State private var isConfirmingDelete = false
    @State private var renaming: CoordinationDevice?
    @State private var newName = ""
    @State private var revoking: CoordinationDevice?

    @Environment(CoordinationStore.self) private var coordination
    @Environment(SessionStore.self) private var session
    @Environment(NetworkMonitor.self) private var network
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t
    @Environment(\.locale) private var locale

    var body: some View {
        let state = coordination.state
        ThemedForm {
            Section {
                LabeledContent(t("settings.crossDevice.connectionState.label")) {
                    ConnectionBadge(state: state.connectionState)
                }
                LabeledContent(t("settings.crossDevice.lastSync.label"), value: lastSyncText)
                LabeledContent(
                    t("settings.crossDevice.devices"),
                    value: t("settings.crossDevice.deviceCount", ["count": String(devices.count)])
                )
            } footer: {
                Text(t("settings.crossDevice.description"))
            }

            if state.isRegistered {
                status(state)
            } else {
                setup
            }

            if !devices.isEmpty {
                Section {
                    ForEach(devices) { device in
                        deviceRow(device, isCurrent: device.id == state.deviceId)
                    }
                } header: {
                    Text(t("settings.crossDevice.devices"))
                } footer: {
                    Text(t("settings.crossDevice.devicesDescription"))
                }
            }

            if state.isRegistered {
                Section {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label(t("settings.crossDevice.deleteData.label"), systemImage: "trash")
                    }
                    .disabled(!network.isOnline)
                } footer: {
                    Text(t("settings.crossDevice.deleteData.info"))
                }
            }
        }
        .navigationTitle(t("settings.options.cross-device"))
        .animation(.smooth, value: state.isRegistered)
        .onAppear(perform: prefill)
        .task(id: state.isRegistered) {
            guard state.isRegistered else { return }
            try? await coordination.refreshDevices()
        }
        .refreshable {
            guard coordination.state.isRegistered else { return }
            try? await coordination.refreshDevices()
        }
        .alert(t("settings.crossDevice.disconnectConfirm.title"), isPresented: $isConfirmingDisconnect) {
            Button(t("settings.crossDevice.disconnect"), role: .destructive, action: disconnect)
            Button(t("generic.cancel"), role: .cancel) {}
        } message: {
            Text(t("settings.crossDevice.disconnectConfirm.description"))
        }
        .alert(t("settings.crossDevice.deleteConfirm.title"), isPresented: $isConfirmingDelete) {
            Button(t("settings.crossDevice.delete"), role: .destructive, action: deleteAccount)
            Button(t("generic.cancel"), role: .cancel) {}
        } message: {
            Text(t("settings.crossDevice.deleteConfirm.description"))
        }
        .alert(
            t("settings.crossDevice.device.rename"),
            isPresented: isPresenting($renaming),
            presenting: renaming
        ) { device in
            TextField(t("settings.crossDevice.deviceName.placeholder"), text: $newName)
            Button(t("settings.crossDevice.device.save")) {
                rename(device)
            }
            .disabled(!canRename(device))
            Button(t("settings.crossDevice.device.cancel"), role: .cancel) {}
        }
        .alert(
            t("settings.crossDevice.revokeConfirm.title"),
            isPresented: isPresenting($revoking),
            presenting: revoking
        ) { device in
            Button(t("settings.crossDevice.device.revoke"), role: .destructive) {
                revoke(device)
            }
            Button(t("generic.cancel"), role: .cancel) {}
        } message: { device in
            Text(t("settings.crossDevice.revokeConfirm.description", ["name": device.name]))
        }
    }

    private var devices: [CoordinationDevice] {
        coordination.state.devices.filter { !$0.isRevoked }
    }

    private var lastSyncText: String {
        guard let date = coordination.state.lastSyncAt else { return t("settings.crossDevice.never") }
        return Formatters.relative(date, locale: locale)
    }

    // MARK: - Setup

    private var setup: some View {
        Section {
            URLField(
                title: t("settings.crossDevice.serverUrl.label"),
                text: $serverUrl,
                prompt: "https://coord.example.com"
            )
            URLField(
                title: t("settings.crossDevice.identityUrl.label"),
                text: $identityUrl,
                prompt: session.account?.activeUrl ?? "https://navidrome.example"
            )
            TextField(
                t("settings.crossDevice.deviceName.label"),
                text: $deviceName,
                prompt: Text(t("settings.crossDevice.deviceName.placeholder"))
            )
            .textInputAutocapitalization(.words)
            Button(action: connect) {
                HStack {
                    Text(t("settings.crossDevice.connect"))
                    if isConnecting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isConnecting || !network.isOnline || !hasSetupFields)
        } header: {
            Text(t("settings.crossDevice.setup.title"))
        } footer: {
            Text(
                "\(t("settings.crossDevice.setup.description")) \(t("settings.crossDevice.serverUrl.info")) \(t("settings.crossDevice.setup.requirement"))"
            )
        }
    }

    private var hasSetupFields: Bool {
        !serverUrl.trimmingCharacters(in: .whitespaces).isEmpty
            && !identityUrl.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        if let config = coordination.state.config {
            serverUrl = config.serverUrl
            identityUrl = config.identityUrl
        } else {
            identityUrl = session.account?.activeUrl ?? ""
        }
        deviceName = UIDevice.current.name
    }

    private func connect() {
        let server = ServerAddress.normalize(serverUrl)
        let identity = ServerAddress.normalize(identityUrl)
        guard !server.isEmpty, !identity.isEmpty, session.account != nil else {
            toasts.show(.key("settings.crossDevice.error.missingFields"), style: .error)
            return
        }
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await coordination.connect(
                    serverUrl: server,
                    identityUrl: identity,
                    deviceName: name.isEmpty ? UIDevice.current.name : name
                )
                serverUrl = server
                identityUrl = identity
                toasts.success("settings.crossDevice.connected")
            } catch {
                toasts.show(
                    .text("\(t("settings.crossDevice.error.connectFailed")): \(error.localizedDescription)"),
                    style: .error
                )
            }
        }
    }

    // MARK: - Status

    private func status(_ state: CoordinationState) -> some View {
        Section {
            LabeledContent {
                ConnectionBadge(state: state.connectionState)
            } label: {
                Text(t("settings.crossDevice.currentDevice"))
                if let name = devices.first(where: { $0.id == state.deviceId })?.name {
                    Text(name)
                }
            }
            if let error = state.lastError {
                Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if state.connectionState == .error || state.connectionState == .disconnected {
                Button(t("settings.crossDevice.retry")) {
                    Task { await coordination.reconnect() }
                }
                .disabled(!network.isOnline)
            }
            Button(t("settings.crossDevice.disconnectShort"), role: .destructive) {
                isConfirmingDisconnect = true
            }
        } header: {
            Text(t("settings.crossDevice.status"))
        } footer: {
            Text(t("settings.crossDevice.statusInfo"))
        }
    }

    private func disconnect() {
        coordination.disconnect()
        toasts.success("settings.crossDevice.disconnected")
    }

    private func deleteAccount() {
        Task {
            do {
                try await coordination.deleteAccount()
                toasts.success("settings.crossDevice.deleted")
            } catch {
                toasts.show(error: error)
            }
        }
    }

    // MARK: - Devices

    private func deviceRow(_ device: CoordinationDevice, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: DeviceSymbol.name(for: device.platform))
                .font(.title3)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .lineLimit(1)
                    if isCurrent {
                        Text(t("settings.crossDevice.device.current"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: .capsule)
                            .foregroundStyle(.tint)
                    }
                }
                Text(deviceDetails(device))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isCurrent {
                Button(t("settings.crossDevice.device.revoke"), systemImage: "xmark.circle") {
                    revoking = device
                }
                .tint(.red)
            }
            Button(t("settings.crossDevice.device.rename"), systemImage: "pencil") {
                beginRename(device)
            }
            .tint(.orange)
        }
        .contextMenu {
            Button(t("settings.crossDevice.device.rename"), systemImage: "pencil") {
                beginRename(device)
            }
            if !isCurrent {
                Button(t("settings.crossDevice.device.revoke"), systemImage: "xmark.circle", role: .destructive) {
                    revoking = device
                }
            }
        }
    }

    /// "iOS · Last online 5 minutes ago".
    private func deviceDetails(_ device: CoordinationDevice) -> String {
        var parts = [DevicePlatform.label(for: device.platform)]
        if let date = device.lastOnlineDate {
            parts.append(t("settings.crossDevice.device.lastOnline", ["time": Formatters.relative(date, locale: locale)]))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func beginRename(_ device: CoordinationDevice) {
        newName = device.name
        renaming = device
    }

    private func canRename(_ device: CoordinationDevice) -> Bool {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != device.name
    }

    private func rename(_ device: CoordinationDevice) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != device.name else { return }
        Task {
            do {
                try await coordination.rename(deviceId: device.id, name: name)
                toasts.success("settings.crossDevice.device.renamed")
            } catch {
                toasts.show(error: error)
            }
        }
    }

    private func revoke(_ device: CoordinationDevice) {
        Task {
            do {
                try await coordination.revoke(deviceId: device.id)
                toasts.success("settings.crossDevice.device.revoked")
            } catch {
                toasts.show(error: error)
            }
        }
    }

    private func isPresenting(_ item: Binding<CoordinationDevice?>) -> Binding<Bool> {
        Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
    }
}

/// The connection state as a colored capsule, like the web badge.
private struct ConnectionBadge: View {
    let state: CoordinationConnectionState

    @Environment(Localizer.self) private var t

    var body: some View {
        Label {
            Text(t("settings.crossDevice.connectionState.\(labelState)"))
        } icon: {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
    }

    /// The web has no "reconnecting" label; it shows "connecting".
    private var labelState: String {
        state == .reconnecting ? CoordinationConnectionState.connecting.rawValue : state.rawValue
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .connecting, .authenticating, .reconnecting: .orange
        case .error: .red
        case .disconnected: .gray
        }
    }
}

/// A platform id as the web names it.
enum DevicePlatform {
    static func label(for platform: String) -> String {
        switch platform.lowercased() {
        case "electron", "desktop": "Desktop"
        case "capacitor-ios", "ios": "iOS"
        case "capacitor-android", "android": "Android"
        case "web": "Web"
        default: platform
        }
    }
}
