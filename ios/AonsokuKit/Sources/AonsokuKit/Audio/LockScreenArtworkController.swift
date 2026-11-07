#if os(iOS)
  import Foundation
  import MediaPlayer

  /// iOS artwork settings/status bridge. Settings persist in the existing native
  /// preferences store; rendering and optional downloads stay native-owned.
  enum LockScreenArtworkController {
    static var supported: Bool {
      #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
          return !MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys.isEmpty
        }
      #endif
      return false
    }
    static func snapshot() -> [String: Any] {
      let settings = LockScreenArtworkSettings.shared.value
      let policy = LockScreenArtworkMotionPolicy.shared
      let manager = LockScreenArtworkModelManager.shared
      let data = try? JSONEncoder().encode(settings)
      let options = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
      var reason = policy.generationReason
      if !(settings.immersiveEnabled && settings.dynamicEnabled) && !LockScreenArtworkDemand.shared.dynamicRequested {
        reason = "disabled"
      } else if reason == "ready", let tier = policy.effectiveTier, manager.modelURL(tier) == nil,
        manager.availableTier(upTo: tier) == nil
      {
        reason = "waitingForModel"
      }
      return [
        "supported": supported, "options": options,
        "deviceMemoryBytes": ProcessInfo.processInfo.physicalMemory,
        "recommendedTier": LockScreenArtworkTier.automatic(
          memory: ProcessInfo.processInfo.physicalMemory
        ).rawValue,
        "effectiveTier": policy.effectiveTier?.rawValue as Any? ?? NSNull(),
        "generationStatus": reason, "models": manager.snapshot(),
        "modelRevision": LockScreenArtworkModelCatalog.revision,
      ]
    }
  }
#endif
