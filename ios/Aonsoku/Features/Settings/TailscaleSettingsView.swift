import AonsokuKit
import Perception
import SafariServices
import SwiftUI

@available(iOS 18.1, *)
struct TailscaleSettingsView: View {
    // The parent reads the iOS 16 Perception environment. An availability-gated
    // view would otherwise select SwiftUI's different native observation key.
    let t: Localizer
    @State private var store = TailscaleStore.shared
    @State private var hosts = ""
    @State private var authKey = ""
    @State private var authenticationPage: AuthenticationPage?
    @State private var isConfirmingForget = false

    var body: some View {
        WithPerceptionTracking {
            ThemedForm {
                WithPerceptionTracking {
                    Section {
                        Toggle(t("native.tailscale.enabled"), isOn: Binding(
                            get: { store.enabled }, set: { store.setEnabled($0) }
                        ))
                        LabeledContent(t("native.tailscale.status"), value: statusLabel)
                        if !store.snapshot.addresses.isEmpty {
                            Text(store.snapshot.addresses.joined(separator: "\n"))
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                        if store.enabled, store.snapshot.state != .connected {
                            Button {
                                store.saveHosts(hosts)
                                store.connect()
                            } label: {
                                HStack {
                                    Text(t("native.tailscale.signIn"))
                                    if store.isAuthenticating { Spacer(); ProgressView() }
                                }
                            }
                            .disabled(store.isAuthenticating)
                            .accessibilityIdentifier("tailscale.signIn")
                            if store.isAuthenticating {
                                Button(t("generic.cancel"), role: .cancel) { store.cancelAuthentication() }
                            }
                        }
                        if store.hasError {
                            Text(t("native.tailscale.error"))
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t("native.tailscale.description"))
                            Text(t("native.tailscale.downloadsDescription"))
                        }
                    }

                    if store.enabled {
                        Section {
                            Toggle(t("native.tailscale.acceptSubnetRoutes"), isOn: Binding(
                                get: { store.acceptSubnetRoutes }, set: { store.setAcceptSubnetRoutes($0) }
                            ))
                            .accessibilityIdentifier("tailscale.acceptSubnetRoutes")
                        } footer: {
                            Text(t("native.tailscale.subnetRoutesDescription"))
                        }

                        Section {
                            TextField(t("native.tailscale.hosts"), text: $hosts, axis: .vertical)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                            Button(t("settings.server.save")) { store.saveHosts(hosts) }
                        } header: {
                            Text(t("native.tailscale.hosts"))
                        } footer: {
                            Text(t("native.tailscale.hostsDescription"))
                        }

                        Section {
                            DisclosureGroup(t("native.tailscale.authKey")) {
                                SecureField(t("native.tailscale.authKey"), text: $authKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Button(t("native.tailscale.useKey")) {
                                    let key = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                    authKey = ""
                                    store.saveHosts(hosts)
                                    store.connect(authKey: key)
                                }
                                .disabled(authKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isAuthenticating)
                            }
                            .disabled(store.snapshot.state == .connected)
                            Button(t("native.tailscale.forget"), role: .destructive) { isConfirmingForget = true }
                        } footer: {
                            Text(t("native.tailscale.authKeyDescription"))
                        }
                    }
                }
            }
            .navigationTitle("Tailscale")
            .task {
                hosts = store.additionalHosts.joined(separator: ", ")
                await store.monitor()
            }
            .onChange(of: store.snapshot) { value in
                if value.state == .connected {
                    authenticationPage = nil
                } else if store.isAuthenticating, let url = value.authenticationURL {
                    if authenticationPage?.url != url { authenticationPage = AuthenticationPage(url: url) }
                }
            }
            .sheet(item: $authenticationPage, onDismiss: { store.cancelAuthentication() }) { page in
                TailscaleAuthenticationBrowser(url: page.url).ignoresSafeArea()
            }
            .confirmationDialog(t("native.tailscale.forgetTitle"), isPresented: $isConfirmingForget, titleVisibility: .visible) {
                Button(t("native.tailscale.forget"), role: .destructive) { Task { await store.forgetIdentity() } }
                Button(t("generic.cancel"), role: .cancel) {}
            } message: {
                Text(t("native.tailscale.forgetDescription"))
            }
        }
    }

    private var statusLabel: String {
        switch store.snapshot.state {
        case .disconnected: t("native.tailscale.disconnected")
        case .connecting: t("native.tailscale.connecting")
        case .needsLogin: t("native.tailscale.needsLogin")
        case .needsApproval: t("native.tailscale.needsApproval")
        case .connected: t("native.tailscale.connected")
        case .failed: t("native.tailscale.failed")
        }
    }

    private struct AuthenticationPage: Identifiable {
        let id = UUID()
        let url: URL
    }
}

private struct TailscaleAuthenticationBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Older systems retain ordinary server connections and have no Tailscale entry.
struct TailscaleSettingsLink: View {
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            if #available(iOS 18.1, *) {
                NavigationLink {
                    TailscaleSettingsView(t: t)
                } label: {
                    Label("Tailscale", systemImage: "network")
                }
                .accessibilityIdentifier("tailscale.settings")
            }
        }
    }
}
