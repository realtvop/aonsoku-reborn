import Foundation
import Capacitor

final class EventEmitter {
    private let notify: (String, [String: Any]) -> Void
    private var syncStateTimer: Timer?
    private var pendingSyncState: [String: Any]?
    private let terminalPhases = ["done", "error", "cancelled"]

    init(plugin: CAPPlugin) {
        self.notify = { [weak plugin] event, data in
            plugin?.notifyListeners(event, data: data)
        }
    }

    init(notify: @escaping (String, [String: Any]) -> Void) {
        self.notify = notify
    }

    func emitSyncStateChanged(_ state: [String: Any]) {
        pendingSyncState = state
        if let phase = state["phase"] as? String,
           terminalPhases.contains(phase) {
            forceFlush()
        } else if syncStateTimer == nil {
            syncStateTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                self?.flushSyncState()
            }
        }
    }

    func emitDataChanged(tables: [String], tier: String) {
        notify("dataChanged", [
            "tables": tables,
            "tier": tier,
        ])
    }

    private func flushSyncState() {
        syncStateTimer = nil
        guard let state = pendingSyncState else { return }
        pendingSyncState = nil
        notify("syncStateChanged", state)
    }

    func forceFlush() {
        syncStateTimer?.invalidate()
        syncStateTimer = nil
        flushSyncState()
    }
}
