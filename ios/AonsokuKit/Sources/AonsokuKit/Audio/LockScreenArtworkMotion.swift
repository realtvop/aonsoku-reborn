import CoreGraphics
import CoreImage
import Foundation
import Vision

#if os(iOS)
  import UIKit
  import os
#endif

/// Only the small normalized depth map and text geometry survive inference.
struct LockScreenArtworkMotionAnalysis {
  let mask: CGImage?
  let reason: String
  let protectedText: [CGRect]
  init(mask: CGImage?, reason: String, protectedText: [CGRect] = []) {
    self.mask = mask
    self.reason = reason
    self.protectedText = protectedText
  }
  var mode: String { mask == nil ? "camera" : "parallax" }
  var canCache: Bool {
    mask != nil || reason == "unsafe-source-geometry" || reason == "camera-fallback-no-depth"
  }
}

enum LockScreenArtworkMotion {
  static let frameRate = 24
  static let frameCount = 144
  static let duration = 6.0
  private static let context = CIContext(options: [.cacheIntermediates: false])
  // Unlike CIDisplacementDistortion (a gradient/bump effect), this kernel
  // translates flat foreground/background regions by their actual depth.
  private static let kernel: CIKernel? = {
    let source = """
      #include <CoreImage/CoreImage.h>
      using namespace metal;
      [[stitchable]] float4 coverMotion(coreimage::sampler image,
          coreimage::sampler depth, float2 offset, coreimage::destination dest) {
          float2 p = dest.coord();
          float d = depth.sample(depth.transform(p)).r;
          return image.sample(image.transform(p + offset * (2.0 * d - 1.0)));
      }
      """
    LockScreenArtworkDiagnostics.shared.setRenderer("compiling Metal kernel")
    do {
      let result = try CIKernel.kernels(withMetalString: source).first
      LockScreenArtworkDiagnostics.shared.setRenderer(result == nil ? "unavailable" : "Metal ready")
      return result
    } catch {
      LockScreenArtworkDiagnostics.shared.setRenderer("Metal failed: \(error.localizedDescription)")
      return nil
    }
  }()
  static var parallaxAvailable: Bool { kernel != nil }

  /// Normalized Vision coordinates, origin at bottom-left. Never record text.
  static func textRegions(_ image: CGImage) -> [CGRect] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    if #available(iOS 16.0, macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
    let supported = (try? request.supportedRecognitionLanguages()) ?? []
    let languages = ["en-US", "ja-JP", "zh-Hans", "zh-Hant"].filter { supported.contains($0) }
    if !languages.isEmpty { request.recognitionLanguages = languages }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    let detection = VNDetectTextRectanglesRequest()
    guard (try? handler.perform([request, detection])) != nil else { return [] }
    var regions = (request.results ?? []).compactMap { observation -> CGRect? in
      guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3,
        candidate.string.filter({ !$0.isWhitespace }).count >= 2
      else { return nil }
      return observation.boundingBox
    }
    // Stylized/boxed title lettering can have low OCR confidence. Use
    // detected horizontal text lines too; avoid isolated eye/circle shapes.
    for result in detection.results ?? [] {
      let box = result.boundingBox
      if box.width > 0.08 && box.height > 0.01 && box.width > box.height * 1.8 {
        regions.append(box)
      }
    }
    return regions
  }

  static func analyze(_ image: CGImage) -> LockScreenArtworkMotionAnalysis {
    .init(mask: nil, reason: "camera-fallback-no-depth")
  }

  static func depthImage(
    _ analysis: LockScreenArtworkMotionAnalysis, source: CGImage,
    format: LockScreenArtworkFormat
  ) -> CIImage? {
    guard let mask = analysis.mask else { return nil }
    let rect = LockScreenArtworkRenderer.sourceRect(for: source, format: format)
    // Depth is scalar data, not a display image. Disabling its color-space
    // conversion keeps 0.5 neutral instead of gamma-shifting it to ~0.21.
    let field = CIImage(cgImage: mask, options: [.colorSpace: NSNull()]).transformed(
      by: CGAffineTransform(
        scaleX: rect.width / Double(mask.width), y: rect.height / Double(mask.height))
    )
    .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    .composited(over: CIImage(color: .black))
    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
    .cropped(to: CGRect(x: 0, y: 0, width: format.width, height: format.height))
    guard !analysis.protectedText.isEmpty else { return field }
    var protection = CIImage(color: .black)
    for text in analysis.protectedText {
      let box = CGRect(
        x: rect.minX + text.minX * rect.width,
        y: rect.minY + text.minY * rect.height,
        width: text.width * rect.width, height: text.height * rect.height
      )
      .insetBy(dx: -12, dy: -12)
      protection = CIImage(color: .white).cropped(to: box).composited(over: protection)
    }
    protection = protection.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5])
    // Neutral depth has zero relative shift. Camera motion still moves all
    // glyphs rigidly together; soft margins avoid a sharp displacement seam.
    return CIImage(
      color: CIColor(
        red: 0.5, green: 0.5, blue: 0.5, alpha: 1,
        colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!
    )
    .applyingFilter(
      "CIBlendWithMask",
      parameters: [
        kCIInputBackgroundImageKey: field, kCIInputMaskImageKey: protection,
      ]
    ).cropped(to: field.extent)
  }

  /// The function is periodic in phase; the next frame after 143 is frame 0.
  /// A tiny overscan hides displaced borders without stretching the subject.
  static func frame(
    _ image: CGImage, depth: CIImage?, phase: Double,
    parameters: LockScreenArtworkMotionParameters = .init()
  ) -> CIImage {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let input = CIImage(cgImage: image).clampedToExtent()
    let angle = phase * 2 * Double.pi
    let factor =
      (depth == nil ? 1 : parameters.amplitude) * Double(min(image.width, image.height)) / 720
    let amplitude = (depth == nil ? 4.0 : 1.5) * factor
    let cameraX = amplitude * sin(angle)
    let cameraY = amplitude * sin(2 * angle) * 0.5
    // Restore the smooth periodic zoom. Zoom is dimensionless: only pixel
    // displacement scales with output resolution, not the zoom percentage.
    let zoomAmplitude = depth == nil ? 1 : parameters.amplitude
    let scale = depth == nil
      ? 1.025 + 0.0125 * (1 - cos(angle))
      : 1 + 0.04 * zoomAmplitude + 0.004 * zoomAmplitude * (1 - cos(angle))
    let transform = CGAffineTransform(
      translationX: bounds.midX + cameraX,
      y: bounds.midY + cameraY
    )
    .scaledBy(x: scale, y: scale)
    .translatedBy(x: -bounds.midX, y: -bounds.midY)
    let camera = input.transformed(by: transform)
    if let depth, let kernel,
      let warped = kernel.apply(
        extent: bounds,
        roiCallback: { index, rect in
          index == 0 ? rect.insetBy(dx: -14 * factor, dy: -14 * factor) : rect
        },
        arguments: [
          camera, depth,
          CIVector(x: 10 * factor * sin(angle), y: 4 * factor * sin(2 * angle)),
        ])
    {
      return warped.cropped(to: bounds)
    }
    return camera.cropped(to: bounds)
  }
}

/// Main-thread lifecycle snapshots are read by the utility encoder. Returning
/// to the foreground retries preparation; system URL handlers never run AI.
final class LockScreenArtworkMotionPolicy {
  static let shared = LockScreenArtworkMotionPolicy()
  private let lock = NSLock()
  private var foreground = true
  private var memoryPauseUntil = Date.distantPast
  private var memoryDowngradeUntil = Date.distantPast
  private var observers: [NSObjectProtocol] = []
  #if os(iOS)
    private var reduceMotion = false
    private var pressureSource: DispatchSourceMemoryPressure?
  #endif

  private init() {
    #if os(iOS)
      foreground = UIApplication.shared.applicationState == .active
      reduceMotion = UIAccessibility.isReduceMotionEnabled
      let center = NotificationCenter.default
      for name in [
        UIApplication.didBecomeActiveNotification,
        UIApplication.willResignActiveNotification,
        UIApplication.didReceiveMemoryWarningNotification,
        UIAccessibility.reduceMotionStatusDidChangeNotification,
      ] {
        observers.append(
          center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.lock.lock()
            self.foreground = UIApplication.shared.applicationState == .active
            self.reduceMotion = UIAccessibility.isReduceMotionEnabled
            self.lock.unlock()
            if note.name == UIApplication.didReceiveMemoryWarningNotification {
              self.noteMemoryPressure()
            }
          })
      }
      let pressure = DispatchSource.makeMemoryPressureSource(
        eventMask: [.warning, .critical], queue: .main)
      pressure.setEventHandler { [weak self] in self?.noteMemoryPressure() }
      pressureSource = pressure
      pressure.resume()
    #endif
  }

  static let resourcesChanged = Notification.Name("AonsokuArtworkResourcesChanged")
  private func noteMemoryPressure() {
    lock.lock()
    memoryPauseUntil = Date().addingTimeInterval(60)
    memoryDowngradeUntil = Date().addingTimeInterval(180)
    lock.unlock()
    NotificationCenter.default.post(name: Self.resourcesChanged, object: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 61) {
      NotificationCenter.default.post(name: Self.resourcesChanged, object: nil)
    }
  }
  private var availableMemory: UInt64? {
    #if os(iOS)
      let bytes = UInt64(os_proc_available_memory())
      return bytes > 0 ? bytes : nil
    #else
      return nil
    #endif
  }

  var generationReason: String {
    lock.lock()
    let active = foreground
    let paused = Date() <= memoryPauseUntil
    lock.unlock()
    if !LockScreenArtworkSettings.shared.value.resourceProtectionEnabled {
      if !active { return "background" }
      return allowsPlayback ? "ready" : "reduceMotion"
    }
    if paused { return "memoryPressure" }
    if !active { return "background" }
    if ProcessInfo.processInfo.thermalState.rawValue >= 2 { return "thermal" }
    if ProcessInfo.processInfo.isLowPowerModeEnabled { return "lowPower" }
    if !allowsPlayback { return "reduceMotion" }
    if effectiveTier == nil { return "memoryPressure" }
    return "ready"
  }
  var effectiveTier: LockScreenArtworkTier? {
    let options = LockScreenArtworkSettings.shared.value
    if !options.resourceProtectionEnabled {
      return LockScreenArtworkTier(rawValue: options.quality)
        ?? LockScreenArtworkTier.automatic(memory: ProcessInfo.processInfo.physicalMemory)
    }
    lock.lock()
    let pressured = Date() <= memoryPauseUntil
    let recovering = Date() <= memoryDowngradeUntil
    lock.unlock()
    return LockScreenArtworkTier.select(
      quality: options.quality,
      memory: ProcessInfo.processInfo.physicalMemory,
      thermal: ProcessInfo.processInfo.thermalState.rawValue,
      memoryPressure: pressured, recovering: recovering, availableMemory: availableMemory)
  }

  var allowsGeneration: Bool {
    return allowsStaticGeneration && allowsPlayback
  }

  var allowsStaticGeneration: Bool {
    let protection = LockScreenArtworkSettings.shared.value.resourceProtectionEnabled
    lock.lock()
    let allowed = foreground && (!protection || Date() > memoryPauseUntil)
    lock.unlock()
    return allowed && effectiveTier != nil
      && (!protection || (ProcessInfo.processInfo.thermalState.rawValue < 2
        && !ProcessInfo.processInfo.isLowPowerModeEnabled))
  }

  var allowsPlayback: Bool {
    #if os(iOS)
      lock.lock()
      let reduced = reduceMotion
      lock.unlock()
      // Resource protection gates new work, never playback of completed files.
      return !reduced
    #else
      return true
    #endif
  }
}

/// Revision cancellation without reading plugin/player state on a worker.
final class LockScreenArtworkGeneration {
  private let lock = NSLock()
  private var revision = 0
  func update(_ revision: Int) {
    lock.lock()
    self.revision = revision
    lock.unlock()
  }
  func contains(_ revision: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return self.revision == revision
  }
}
