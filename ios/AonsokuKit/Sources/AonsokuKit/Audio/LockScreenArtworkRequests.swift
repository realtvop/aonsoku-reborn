import Foundation
import UIKit
import os

/// Main-thread system observations. Preview sizes never become video targets.
final class LockScreenArtworkRequests {
  static let shared = LockScreenArtworkRequests()
  static let changed = Notification.Name("AonsokuArtworkVideoTargetChanged")
  private let key = "ios-artwork-request-sizes-v1"
  private var records: [String: [String: Double]]
  private init() {
    records = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]] ?? [:]
  }
  private var screen: UIScreen {
    UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
      ?? UIScreen.main
  }
  private var display: String {
    let screen = screen
    return
      "\(Int(screen.nativeBounds.width))x\(Int(screen.nativeBounds.height))@\(screen.nativeScale)"
  }
  private var recordScope: String {
    let device = UIDevice.current.identifierForVendor?.uuidString ?? UIDevice.current.model
    return device + "-" + UIDevice.current.systemVersion + "-" + display
  }
  func record(format: LockScreenArtworkFormat, size: CGSize, kind: String) {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
    let id = "\(recordScope)-\(format.label)-\(kind)"
    let next = ["width": Double(size.width), "height": Double(size.height)]
    let changed = records[id] != next
    if changed {
      records[id] = next
      UserDefaults.standard.set(records, forKey: key)
    }
    LockScreenArtworkDiagnostics.shared.update(
      format.label,
      ["\(kind)RequestedPixels": "\(size.width)×\(size.height)", "display": display])
    if changed && kind == "video" {
      NotificationCenter.default.post(name: Self.changed, object: nil)
    }
  }
  func target(portrait: Bool) -> (size: CGSize, origin: String) {
    let label = portrait ? "3:4" : "1:1"
    if let value = records["\(recordScope)-\(label)-video"],
      let w = value["width"], let h = value["height"]
    {
      return (CGSize(width: w, height: h), "recent-system-video-request")
    }
    let bounds = screen.nativeBounds.size
    return (
      CGSize(width: min(bounds.width, bounds.height), height: max(bounds.width, bounds.height)),
      "provisional-native-screen (not a system request)"
    )
  }
  static var budgetBytes: UInt64 {
    // Physical/hardware capacity remains bounded; only pressure-based reduction
    // is optional. Disabling protection does not promise an allocation succeeds.
    if !LockScreenArtworkSettings.shared.value.resourceProtectionEnabled {
      return ProcessInfo.processInfo.physicalMemory / 8
    }
    let available = UInt64(os_proc_available_memory())
    return min(
      ProcessInfo.processInfo.physicalMemory / 8,
      available > 0 ? available / 4 : ProcessInfo.processInfo.physicalMemory / 16)
  }
}
