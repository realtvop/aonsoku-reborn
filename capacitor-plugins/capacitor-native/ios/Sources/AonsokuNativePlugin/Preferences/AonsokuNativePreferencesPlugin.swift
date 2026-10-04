import Foundation
import Capacitor
import GRDB

@objc(AonsokuNativePreferencesPlugin)
public class AonsokuNativePreferencesPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "AonsokuNativePreferencesPlugin"
    public let jsName = "AonsokuNativePreferences"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getAllPreferences", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPreferences", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPreference", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deletePreference", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getQueueState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setQueueState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPlayHistory", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "addToPlayHistory", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearPlayHistory", returnType: CAPPluginReturnPromise),
    ]

    private var db: DatabasePool { DatabaseManager.shared.dbPool }
    private var prefs: PreferencesManager { PreferencesManager.shared }
    private lazy var playHistory = PlayHistoryStore(db: db)

    // MARK: - Preferences

    @objc func getAllPreferences(_ call: CAPPluginCall) {
        let all = prefs.getAll()
        call.resolve(["preferences": all])
    }

    @objc func setPreferences(_ call: CAPPluginCall) {
        guard let preferences = call.getObject("preferences") else {
            call.reject("Missing preferences object")
            return
        }
        var pairs: [String: String] = [:]
        for (key, value) in preferences {
            if let str = value as? String {
                pairs[key] = str
            } else if let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed]
            ) {
                pairs[key] = String(data: data, encoding: .utf8) ?? ""
            }
        }
        prefs.setValues(pairs)
        call.resolve()
    }

    @objc func setPreference(_ call: CAPPluginCall) {
        guard let key = call.getString("key") else {
            call.reject("Missing key")
            return
        }
        let value = call.getValue("value")
        let stringValue: String
        if let str = value as? String {
            stringValue = str
        } else if let data = try? JSONSerialization.data(
            withJSONObject: value as Any, options: [.fragmentsAllowed]
        ) {
            stringValue = String(data: data, encoding: .utf8) ?? ""
        } else {
            stringValue = "\(value ?? "null")"
        }
        prefs.setValue(key, value: stringValue)
        call.resolve()
    }

    @objc func deletePreference(_ call: CAPPluginCall) {
        guard let key = call.getString("key") else {
            call.reject("Missing key")
            return
        }
        prefs.deleteValue(key)
        call.resolve()
    }

    // MARK: - Queue State

    @objc func getQueueState(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let stateJson = try self.db.read { db in
                    try String.fetchOne(
                        db,
                        sql: "SELECT stateJson FROM queueState WHERE key = 'current'"
                    )
                }
                call.resolve(["state": stateJson ?? NSNull()])
            } catch {
                call.reject("Failed to read queue state", nil, error)
            }
        }
    }

    @objc func setQueueState(_ call: CAPPluginCall) {
        guard let state = call.getString("state") else {
            call.reject("Missing state")
            return
        }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        DispatchQueue.global(qos: .utility).async {
            try? self.db.write { db in
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO queueState (key, stateJson, updatedAt)
                        VALUES ('current', ?, ?)
                        """,
                    arguments: [state, now]
                )
            }
            call.resolve()
        }
    }

    // MARK: - Play History

    @objc func getPlayHistory(_ call: CAPPluginCall) {
        let limit = call.getInt("limit") ?? 100
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                call.resolve([
                    "history": try self.playHistory.history(limit: limit),
                ])
            } catch {
                call.reject("Failed to read play history", nil, error)
            }
        }
    }

    @objc func addToPlayHistory(_ call: CAPPluginCall) {
        guard let songJson = call.getString("song") else {
            call.reject("Missing song")
            return
        }
        let maxSize = call.getInt("maxSize") ?? 100
        DispatchQueue.global(qos: .utility).async {
            do {
                try self.playHistory.add(songJSON: songJson, maxSize: maxSize)
                call.resolve()
            } catch {
                call.reject("Failed to update play history", nil, error)
            }
        }
    }

    @objc func clearPlayHistory(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .utility).async {
            do {
                try self.playHistory.clear()
                call.resolve()
            } catch {
                call.reject("Failed to clear play history", nil, error)
            }
        }
    }
}
