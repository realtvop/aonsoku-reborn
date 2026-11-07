import Darwin
import Foundation

/// Samples the process footprint while a phase runs, including synchronous
/// Vision calls. This is total process memory, not the size of a model file.
final class LockScreenArtworkMeasurement {
  private let phase: String
  private let started = Date()
  private let baseline: UInt64
  private let lock = NSLock()
  private var peak: UInt64 = 0
  private var timer: DispatchSourceTimer?

  init(_ phase: String) {
    self.phase = phase
    baseline = Self.footprint()
    peak = baseline
    #if DEBUG
      let timer = DispatchSource.makeTimerSource(
        queue: DispatchQueue(
          label: "com.aonsoku.artwork-memory-sampler", qos: .utility))
      timer.schedule(deadline: .now(), repeating: .milliseconds(10))
      timer.setEventHandler { [weak self] in
        guard let self else { return }
        let memory = Self.footprint()
        self.lock.lock()
        self.peak = max(self.peak, memory)
        self.lock.unlock()
      }
      self.timer = timer
      timer.resume()
    #endif
  }

  func finish(_ detail: String) {
    timer?.cancel()
    timer = nil
    lock.lock()
    peak = max(peak, Self.footprint())
    let maximum = peak
    lock.unlock()
    let message =
      "phase=\(phase) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000)) "
      + "baselineMiB=\(baseline / 1_048_576) peakMiB=\(maximum / 1_048_576) "
      + "deltaMiB=\((maximum > baseline ? maximum - baseline : 0) / 1_048_576) \(detail)"
    LockScreenArtworkDiagnostics.shared.measure(
      phase, elapsed: Int(Date().timeIntervalSince(started) * 1000),
      baseline: baseline, peak: maximum, detail: detail)
    #if os(iOS)
      NativeLogger.shared.info(message, source: "NowPlayingArtwork")
    #else
      print(message)
    #endif
  }

  deinit { timer?.cancel() }

  private static func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
  }
}
