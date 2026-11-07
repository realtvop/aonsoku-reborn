import CoreGraphics
import Foundation

/// Small structured snapshots, separate from the rendering FIFO so the debug
/// panel remains responsive while Core ML is loading. No source URLs or text.
final class LockScreenArtworkDiagnostics {
  static let shared = LockScreenArtworkDiagnostics()
  private let lock = NSLock()
  private var variants: [String: [String: String]] = [:]
  private var phases: [String: [String: String]] = [:]
  private var depth: CGImage?
  private var renderer = "not initialized (cached videos need no renderer)"
  func setRenderer(_ state: String) {
    lock.lock()
    renderer = state
    lock.unlock()
  }
  func rendererState() -> String {
    lock.lock()
    defer { lock.unlock() }
    return renderer
  }
  func setDepth(_ image: CGImage?) {
    lock.lock()
    depth = image
    lock.unlock()
  }
  func depthPreview() -> CGImage? {
    lock.lock()
    defer { lock.unlock() }
    return depth
  }

  func update(_ format: String, _ fields: [String: String]) {
    lock.lock()
    var current = variants[format] ?? [:]
    current.merge(fields) { _, new in new }
    variants[format] = current
    lock.unlock()
  }

  func measure(_ phase: String, elapsed: Int, baseline: UInt64, peak: UInt64, detail: String) {
    lock.lock()
    phases[phase] = [
      "elapsed": "\(elapsed) ms",
      "memory":
        "baseline \(baseline / 1_048_576), peak \(peak / 1_048_576), delta \((peak > baseline ? peak - baseline : 0) / 1_048_576) MiB",
      "detail": detail,
    ]
    lock.unlock()
  }

  func snapshot() -> (variants: [String: [String: String]], phases: [String: [String: String]]) {
    lock.lock()
    defer { lock.unlock() }
    return (variants, phases)
  }
}
