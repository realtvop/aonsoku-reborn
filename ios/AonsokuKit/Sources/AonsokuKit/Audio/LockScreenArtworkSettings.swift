import Foundation

/// Thresholds use physical RAM, never free RAM or model file size. Devices
/// reporting between 4 and 6 GiB use P8; above 6 GiB is the 8+ GB device class.
enum LockScreenArtworkTier: String, CaseIterable, Codable {
  case fp16, p8, p6
  var backend: String { "dav2-\(self == .fp16 ? "f16" : rawValue)" }
  var lower: Self { self == .fp16 ? .p8 : .p6 }
  static func automatic(memory: UInt64) -> Self {
    if memory <= 4 * 1024 * 1024 * 1024 { return .p6 }
    if memory <= 6 * 1024 * 1024 * 1024 { return .p8 }
    return .fp16
  }
  static func select(
    quality: String, memory: UInt64, thermal: Int,
    memoryPressure: Bool = false, recovering: Bool = false,
    availableMemory: UInt64? = nil
  ) -> Self? {
    guard thermal < 2, !memoryPressure else { return nil }
    var chosen = Self(rawValue: quality) ?? automatic(memory: memory)
    if let availableMemory {
      if availableMemory < 96 * 1024 * 1024 { return nil }
      if availableMemory < 192 * 1024 * 1024 {
        chosen = .p6
      } else if availableMemory < 320 * 1024 * 1024 && chosen == .fp16 {
        chosen = .p8
      }
    }
    if recovering { return .p6 }
    return thermal == 1 ? chosen.lower : chosen
  }
}

struct LockScreenArtworkOptions: Codable {
  var immersiveEnabled = true
  // Opt in before fetching any optional model or generating motion.
  var dynamicEnabled = false
  var quality = "auto"
  var wifiOnly = true
  var resourceProtectionEnabled = true
  var motionAmplitude = 1.0
  var motionSpeed = 1.0
  var motionParameters: LockScreenArtworkMotionParameters {
    .init(amplitude: motionAmplitude, speed: motionSpeed)
  }
  init() {}
  private enum CodingKeys: String, CodingKey {
    case immersiveEnabled, dynamicEnabled, quality, wifiOnly, motionAmplitude, motionSpeed
    case resourceProtectionEnabled
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    immersiveEnabled = try values.decodeIfPresent(Bool.self, forKey: .immersiveEnabled) ?? true
    dynamicEnabled = try values.decodeIfPresent(Bool.self, forKey: .dynamicEnabled) ?? false
    quality = try values.decodeIfPresent(String.self, forKey: .quality) ?? "auto"
    wifiOnly = try values.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? true
    resourceProtectionEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .resourceProtectionEnabled) ?? true
    let amplitude = try values.decodeIfPresent(Double.self, forKey: .motionAmplitude) ?? 1
    let speed = try values.decodeIfPresent(Double.self, forKey: .motionSpeed) ?? 1
    let parameters = LockScreenArtworkMotionParameters(amplitude: amplitude, speed: speed)
    motionAmplitude = parameters.amplitude
    motionSpeed = parameters.speed
  }
}

/// One complete loop at 24fps. All speeds stay within Apple's <30s guidance.
struct LockScreenArtworkMotionParameters {
  static let speeds: [Double] = [0.5, 0.75, 1, 1.5, 2]
  let amplitude: Double
  let speed: Double
  init(amplitude: Double = 1, speed: Double = 1) {
    self.amplitude = amplitude.isFinite ? (min(2, max(0.5, amplitude)) * 100).rounded() / 100 : 1
    self.speed = Self.speeds.contains(speed) ? speed : 1
  }
  var frameCount: Int { Int((144 / speed).rounded()) }
  var duration: Double { Double(frameCount) / 24 }
  var cacheKey: String { "a\(Int((amplitude * 100).rounded()))-s\(Int((speed * 100).rounded()))" }
}

final class LockScreenArtworkSettings {
  static let shared = LockScreenArtworkSettings()
  static let changed = Notification.Name("AonsokuLockScreenArtworkSettingsChanged")
  private let lock = NSLock()
  private var options = LockScreenArtworkOptions()
  private let key = "ios-lock-screen-artwork"

  private init() {
    #if os(iOS)
      if let raw = PreferencesManager.shared.getString(key), let data = raw.data(using: .utf8),
        let restored = try? JSONDecoder().decode(LockScreenArtworkOptions.self, from: data)
      {
        options = restored
      }
    #endif
  }
  var value: LockScreenArtworkOptions {
    lock.lock()
    defer { lock.unlock() }
    return options
  }
  func configure(_ update: [String: Any]) throws {
    lock.lock()
    var next = options
    lock.unlock()
    if let enabled = update["immersiveEnabled"] as? Bool { next.immersiveEnabled = enabled }
    if let enabled = update["dynamicEnabled"] as? Bool { next.dynamicEnabled = enabled }
    if let wifiOnly = update["wifiOnly"] as? Bool { next.wifiOnly = wifiOnly }
    if let enabled = update["resourceProtectionEnabled"] as? Bool {
      next.resourceProtectionEnabled = enabled
    }
    if let quality = update["quality"] as? String {
      guard quality == "auto" || LockScreenArtworkTier(rawValue: quality) != nil else {
        throw NSError(domain: "ArtworkSettings", code: 1)
      }
      next.quality = quality
    }
    if let amplitude = update["motionAmplitude"] as? Double {
      guard amplitude.isFinite, (0.5...2).contains(amplitude) else {
        throw NSError(domain: "ArtworkSettings", code: 2)
      }
      next.motionAmplitude = (amplitude * 100).rounded() / 100
    }
    if let speed = update["motionSpeed"] as? Double {
      guard LockScreenArtworkMotionParameters.speeds.contains(speed) else {
        throw NSError(domain: "ArtworkSettings", code: 3)
      }
      next.motionSpeed = speed
    }
    let data = try JSONEncoder().encode(next)
    lock.lock()
    options = next
    lock.unlock()
    #if os(iOS)
      PreferencesManager.shared.setValue(key, value: String(decoding: data, as: UTF8.self))
    #endif
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: Self.changed, object: nil)
    }
  }
}

/// Explicit consumer intent; cache reads and system file callbacks never add work.
final class LockScreenArtworkDemand {
  static let shared = LockScreenArtworkDemand()
  static let changed = Notification.Name("LockScreenArtworkGenerationDemandChanged")
  private let lock = NSLock()
  private var cover: String?
  private var entries: [String: (owner: UUID, cover: String, motion: Bool)] = [:]
  func setCurrentCover(_ value: String?) {
    lock.lock()
    cover = value
    lock.unlock()
  }
  var requested: Bool {
    lock.lock()
    defer { lock.unlock() }
    return entries.values.contains { $0.cover == cover }
  }
  var dynamicRequested: Bool {
    lock.lock()
    defer { lock.unlock() }
    return entries.values.contains { $0.cover == cover && $0.motion }
  }
  func add(owner: UUID, cover: String, motion: Bool) -> String? {
    lock.lock()
    guard entries.values.filter({ $0.owner == owner }).count < 8 else {
      lock.unlock()
      return nil
    }
    let id = UUID().uuidString
    entries[id] = (owner, cover, motion)
    lock.unlock()
    notify()
    return id
  }
  func remove(_ id: String, owner: UUID) {
    lock.lock()
    let found = entries[id]?.owner == owner
    if found { entries.removeValue(forKey: id) }
    lock.unlock()
    if found { notify() }
  }
  func releaseAll(owner: UUID) {
    lock.lock()
    let count = entries.count
    entries = entries.filter { $0.value.owner != owner }
    let changed = entries.count != count
    lock.unlock()
    if changed { notify() }
  }
  private func notify() {
    DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
  }
}
