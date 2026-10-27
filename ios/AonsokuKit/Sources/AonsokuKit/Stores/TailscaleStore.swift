import Foundation
import Perception

@available(iOS 18.1, *)
@MainActor
@Perceptible
public final class TailscaleStore {
    public static let shared = TailscaleStore()
    public private(set) var enabled = TailscaleRouting.shared.current.enabled
    public private(set) var snapshot = TailscaleStatusSnapshot()
    public private(set) var isAuthenticating = false
    public private(set) var hasError = false
    @PerceptionIgnored private var authentication: Task<Void, Never>?
    @PerceptionIgnored private var revision: UInt64 = 0

    public var additionalHosts: [String] { TailscaleRouting.shared.current.additionalHosts }

    public func saveHosts(_ text: String) {
        let hosts = text.components(separatedBy: CharacterSet(charactersIn: ",\n "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        TailscaleRouting.shared.configure(enabled: enabled, additionalHosts: hosts)
    }

    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        revision &+= 1
        authentication?.cancel()
        authentication = nil
        isAuthenticating = false
        hasError = false
        snapshot = TailscaleStatusSnapshot(state: enabled ? .connecting : .disconnected)
        TailscaleRouting.shared.configure(enabled: enabled, additionalHosts: additionalHosts)
        if enabled {
            Task { await refresh() }
        } else {
            Task { await TailscaleService.shared.stop() }
        }
    }

    public func connect(authKey: String? = nil) {
        guard !isAuthenticating else { return }
        if !enabled { setEnabled(true) }
        hasError = false
        isAuthenticating = true
        snapshot = TailscaleStatusSnapshot(state: .connecting)
        revision &+= 1
        let generation = revision
        authentication?.cancel()
        authentication = Task {
            do {
                let result = try await TailscaleService.shared.connect(
                    authKey: authKey, webAuthentication: authKey == nil
                )
                guard !Task.isCancelled, generation == revision else { return }
                snapshot = result
                if result.state == .connected || result.state == .needsApproval { isAuthenticating = false }
                if authKey != nil { isAuthenticating = false }
                if result.authenticationURL == nil, result.state != .connected, result.state != .needsApproval {
                    isAuthenticating = false
                    hasError = true
                }
            } catch {
                guard !Task.isCancelled, generation == revision else { return }
                hasError = true
                snapshot = TailscaleStatusSnapshot(state: .failed)
                isAuthenticating = false
            }
        }
    }

    public func cancelAuthentication() {
        guard isAuthenticating, snapshot.state != .connected else { return }
        revision &+= 1
        authentication?.cancel()
        authentication = nil
        isAuthenticating = false
        Task { await TailscaleService.shared.cancelAuthentication(); await refresh() }
    }

    public func forgetIdentity() async {
        revision &+= 1
        authentication?.cancel()
        isAuthenticating = false
        do {
            try await TailscaleService.shared.forgetIdentity()
            setEnabled(false)
        } catch {
            hasError = true
        }
    }

    public func monitor() async {
        while !Task.isCancelled {
            if enabled { await refresh() }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func refresh() async {
        let generation = revision
        do {
            let value = try await TailscaleService.shared.status()
            guard !Task.isCancelled, generation == revision else { return }
            snapshot = value
            if value.state == .connected {
                isAuthenticating = false
                hasError = false
            }
        } catch {
            guard !Task.isCancelled, generation == revision else { return }
            hasError = true
            snapshot = TailscaleStatusSnapshot(state: .failed)
        }
    }
}
