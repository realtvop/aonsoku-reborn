import Foundation

public extension Notification.Name {
    static let aonsokuDynamicArtworkChanged = Notification.Name("AonsokuDynamicArtworkChanged")
}

/// Native settings and file management shared by SwiftUI and the artwork producer.
public enum ArtworkPreferences {
    public static func options() -> [String: Any] { LockScreenArtworkController.snapshot() }
    public static func configure(_ values: [String: Any]) throws {
        try LockScreenArtworkSettings.shared.configure(values)
        LockScreenArtworkModelManager.shared.preferencesChanged()
    }
    public static func download(_ tier: String) {
        guard let tier = LockScreenArtworkTier(rawValue: tier) else { return }
        LockScreenArtworkModelManager.shared.request(tier)
    }
    public static func cancel(_ tier: String) {
        guard let tier = LockScreenArtworkTier(rawValue: tier) else { return }
        LockScreenArtworkModelManager.shared.cancel(tier)
    }
    public static func remove(_ tier: String) {
        guard let tier = LockScreenArtworkTier(rawValue: tier) else { return }
        LockScreenArtworkModelManager.shared.remove(tier)
    }
    public static func videos(_ completion: @escaping ([[String: Any]]) -> Void) {
        LockScreenArtworkStore.shared.listVideos(completion)
    }
    public static func deleteVideo(_ id: String, completion: @escaping (Bool) -> Void) {
        LockScreenArtworkStore.shared.deleteVideo(id: id, completion: completion)
    }
    public static func clearVideos(_ completion: @escaping (Int, Int) -> Void) {
        LockScreenArtworkStore.shared.clearVideos(kind: "all", completion: completion)
    }
}
