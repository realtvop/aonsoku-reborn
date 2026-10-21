import Foundation
import GRDB

public final class PreferencesService: @unchecked Sendable {
    public static let shared = PreferencesService()

    private let prefs: PreferencesManager
    private let playHistory: PlayHistoryStore
    private let db: DatabasePool
    private let observers = PreferencesObserverRegistry()

    private convenience init() {
        self.init(db: DatabaseManager.shared.dbPool)
    }

    /// Creates an isolated service for package tests and previews.
    init(
        db: DatabasePool,
        now: @escaping () -> Date = Date.init,
        historyNow: @escaping () -> Int = {
            Int(Date().timeIntervalSince1970 * 1000)
        }
    ) {
        self.db = db
        self.prefs = PreferencesManager(db: db, now: now)
        self.playHistory = PlayHistoryStore(db: db, now: historyNow)
    }

    // MARK: - String Preferences

    /// Get a string preference value.
    public func getString(_ key: String) -> String? {
        prefs.getString(key)
    }

    /// Set a string preference value.
    public func setString(_ value: String, for key: String) {
        prefs.setValue(key, value: value)
        notifyChange(key: key)
    }

    /// Remove a preference value.
    public func remove(_ key: String) {
        prefs.deleteValue(key)
        notifyChange(key: key)
    }

    // MARK: - Codable Preferences

    /// Get a Codable preference value decoded from JSON.
    public func getJSON<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let jsonString = prefs.getString(key),
              let data = jsonString.data(using: String.Encoding.utf8) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            return nil
        }
    }

    /// Set a Codable preference value encoded as JSON.
    public func setJSON<T: Encodable>(_ value: T, for key: String) throws {
        let data = try JSONEncoder().encode(value)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        prefs.setValue(key, value: jsonString)
        notifyChange(key: key)
    }

    // MARK: - Batch Operations

    /// Get all preference key-value pairs.
    public func getAll() -> [String: String] {
        prefs.getAll()
    }

    /// Set multiple preferences at once.
    public func setValues(_ values: [String: String]) {
        prefs.setValues(values)
        for key in values.keys {
            notifyChange(key: key)
        }
    }

    /// List all stored preference keys.
    public func listKeys() -> [String] {
        Array(prefs.getAll().keys)
    }

    // MARK: - Play History

    /// Get play history entries, up to a specified limit.
    public func getPlayHistory(limit: Int = 100) throws -> [String] {
        try playHistory.history(limit: limit)
    }

    /// Add a song to the play history.
    public func addToPlayHistory(songJSON: String, maxSize: Int = 100) throws {
        try playHistory.add(songJSON: songJSON, maxSize: maxSize)
        notifyChange(key: "playHistory")
    }

    /// Clear the entire play history.
    public func clearPlayHistory() throws {
        try playHistory.clear()
        notifyChange(key: "playHistory")
    }

    // MARK: - Observers

    /// Subscribe to preference changes. Handlers run on the thread that wrote
    /// the change; keep the returned observation alive and cancel it when done.
    public func observe(
        _ handler: @escaping (PreferencesChange) -> Void
    ) -> PreferencesObservation {
        let id = observers.add(handler)
        return PreferencesObservation { [observers] in observers.remove(id) }
    }

    // MARK: - Internal

    private func notifyChange(key: String) {
        observers.notify(PreferencesChange(key: key))
    }
}

public struct PreferencesChange: Sendable {
    public let key: String
    public let timestamp = Date()
}

public final class PreferencesObservation: @unchecked Sendable {
    private let onCancel: () -> Void
    private let lock = NSLock()
    private var isCancelled = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        lock.lock()
        let shouldCancel = !isCancelled
        isCancelled = true
        lock.unlock()
        if shouldCancel { onCancel() }
    }
}

private final class PreferencesObserverRegistry: @unchecked Sendable {
    private var handlers: [UUID: (PreferencesChange) -> Void] = [:]
    private let lock = NSLock()

    func add(_ handler: @escaping (PreferencesChange) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return id
    }

    func remove(_ id: UUID) {
        lock.lock()
        handlers[id] = nil
        lock.unlock()
    }

    func notify(_ change: PreferencesChange) {
        lock.lock()
        let current = Array(handlers.values)
        lock.unlock()
        current.forEach { $0(change) }
    }
}
