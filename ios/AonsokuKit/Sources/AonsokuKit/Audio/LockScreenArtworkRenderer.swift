import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import VideoToolbox

struct LockScreenArtworkFormat: Equatable {
  let width: Int
  let height: Int
  static let square = Self(width: 720, height: 720)  // Legacy fixture/default only.
  static let tall = Self(width: 720, height: 960)
  var isSquare: Bool { width == height }
  var label: String { isSquare ? "1:1" : "3:4" }
  var consumerFormat: String { isSquare ? "square" : "portrait" }
}

/// Source-aware dimensions, independent of DAV2's fixed inference input.
/// Round down in aspect-ratio units; neither alignment nor protection upsizes art.
enum LockScreenArtworkResolution {
  struct Plan {
    let format: LockScreenArtworkFormat
    let reason: String
    var decodeLimit: Int { max(format.width, format.height) }
  }
  static func sourceSize(_ data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetStatus(source) == .statusComplete,
      let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let w = p[kCGImagePropertyPixelWidth] as? Int,
      let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
    else { return nil }
    let orientation = p[kCGImagePropertyOrientation] as? Int ?? 1
    return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
  }
  static func aligned(_ size: CGSize, portrait: Bool) -> LockScreenArtworkFormat? {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      return nil
    }
    let uw = portrait ? 6 : 2
    let uh = portrait ? 8 : 2
    let n = Int(min(size.width / Double(uw), size.height / Double(uh)).rounded(.down))
    guard n >= 1 else { return nil }
    return LockScreenArtworkFormat(width: n * uw, height: n * uh)
  }
  static func base(source: CGSize, target: CGSize, portrait: Bool) -> LockScreenArtworkFormat? {
    guard let target = aligned(target, portrait: portrait) else { return nil }
    let r = min(1, max(source.width / Double(target.width), source.height / Double(target.height)))
    return aligned(
      CGSize(width: Double(target.width) * r, height: Double(target.height) * r), portrait: portrait
    )
  }
  static func plan(
    source: CGSize, target: CGSize, portrait: Bool,
    budgetBytes: UInt64, checkHardware: Bool = true
  ) -> Plan? {
    guard var format = base(source: source, target: target, portrait: portrait) else { return nil }
    var reasons: [String] = []
    // Includes decoded image, extension arrays, CI surfaces and six video buffers.
    let pixels = Double(max(1, budgetBytes / 80))
    let area = Double(format.width) * Double(format.height)
    if area > pixels {
      let factor = sqrt(pixels / area)
      guard
        let smaller = aligned(
          CGSize(
            width: Double(format.width) * factor,
            height: Double(format.height) * factor), portrait: portrait)
      else { return nil }
      format = smaller
      reasons.append("resource-budget")
    }
    if checkHardware {
      var specification: CFDictionary?
      if #available(iOS 17.4, macOS 10.9, *) {
        specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
      } else {
        reasons.append("legacy-encoder-probe")
      }
      for _ in 0..<16 {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
          allocator: kCFAllocatorDefault,
          width: Int32(format.width), height: Int32(format.height),
          codecType: kCMVideoCodecType_H264,
          encoderSpecification: specification,
          imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
          refcon: nil, compressionSessionOut: &session)
        let prepared =
          session.map { VTCompressionSessionPrepareToEncodeFrames($0) == noErr } ?? false
        if let session { VTCompressionSessionInvalidate(session) }
        if status == noErr && prepared {
          return Plan(
            format: format,
            reason: reasons.isEmpty ? "source-and-target" : reasons.joined(separator: ","))
        }
        guard
          let smaller = aligned(
            CGSize(
              width: Double(format.width) * 0.75,
              height: Double(format.height) * 0.75), portrait: portrait), smaller != format
        else { return nil }
        format = smaller
        if !reasons.contains("hardware-encoder") { reasons.append("hardware-encoder") }
      }
      return nil
    }
    return Plan(
      format: format, reason: reasons.isEmpty ? "source-and-target" : reasons.joined(separator: ",")
    )
  }
}

/// A single continuous image: aspect-fit the source, then extend its actual
/// edge pixels. Blur increases only as we move away from the source boundary.
/// There is no cropped background image or foreground card to join together.
enum LockScreenArtworkRenderer {
  private static let context = CIContext(options: [.cacheIntermediates: false])

  // The default is an ordinary-artwork preview budget; producers pass their plan.
  static func decode(_ data: Data, maxPixelSize: Int = 1200) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary)
  }

  static func sourceRect(for image: CGImage, format: LockScreenArtworkFormat = .tall) -> CGRect {
    let width = format.width
    let height = format.height
    let scale = min(
      1, min(Double(width) / Double(image.width), Double(height) / Double(image.height)))
    let w = max(1, min(width, Int((Double(image.width) * scale).rounded())))
    let h = max(1, min(height, Int((Double(image.height) * scale).rounded())))
    return CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h)
  }

  static func render(_ image: CGImage, format: LockScreenArtworkFormat = .tall) -> CGImage? {
    let width = format.width
    let height = format.height
    let rect = sourceRect(for: image, format: format)
    let w = Int(rect.width)
    let h = Int(rect.height)
    let left = Int(rect.minX)
    let bottom = Int(rect.minY)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    var source = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = source.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let canvas = CGContext(
          data: bytes.baseAddress, width: w, height: h,
          bitsPerComponent: 8, bytesPerRow: w * 4,
          space: colorSpace, bitmapInfo: bitmapInfo
        )
      else { return false }
      // Transparent artwork is flattened consistently for the JPEG/video.
      canvas.setFillColor(CGColor(gray: 0, alpha: 1))
      canvas.fill(CGRect(x: 0, y: 0, width: w, height: h))
      canvas.interpolationQuality = .high
      canvas.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { return nil }
    if left == 0, bottom == 0, w == width, h == height,
      let provider = CGDataProvider(data: Data(source) as CFData)
    {
      return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    let band = max(1, Double(min(w, h)) * 0.12)
    let reflectionBand = max(1, Double(min(w, h)) * 0.025)
    func coordinate(_ position: Int, start: Int, length: Int) -> Int {
      let local = position - start
      if local >= 0 && local < length { return local }
      let distance = local < 0 ? -local : local - length + 1
      // Reflect a narrow band, gradually stretching it outward. This
      // continues edge texture without repeating the whole album/subject.
      let inset = min(
        length - 1, Int(reflectionBand * (1 - exp(-Double(distance) / reflectionBand))))
      return local < 0 ? inset : length - 1 - inset
    }
    let xs = (0..<width).map { coordinate($0, start: left, length: w) }
    let ys = (0..<height).map { coordinate($0, start: bottom, length: h) }
    var extended = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let src = (ys[y] * w + xs[x]) * 4
        let dst = (y * width + x) * 4
        for c in 0..<3 { extended[dst + c] = source[src + c] }
      }
    }
    func makeImage(_ pixels: [UInt8]) -> CGImage? {
      guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
      return CGImage(
        width: width, height: height, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent
      )
    }
    guard let base = makeImage(extended) else { return nil }
    let input = CIImage(cgImage: base)
    let filtered = input.clampedToExtent().applyingFilter(
      "CIGaussianBlur", parameters: [kCIInputRadiusKey: band * 0.45]
    ).cropped(to: input.extent)
    var blurred = [UInt8](repeating: 0, count: extended.count)
    blurred.withUnsafeMutableBytes { bytes in
      context.render(
        filtered, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
        bounds: input.extent, format: .RGBA8, colorSpace: colorSpace)
    }
    for y in 0..<height {
      let dy = max(0, bottom - y, y - (bottom + h - 1))
      for x in 0..<width {
        let dx = max(0, left - x, x - (left + w - 1))
        guard dx > 0 || dy > 0 else { continue }
        let t = min(1, hypot(Double(dx), Double(dy)) / band)
        let blend = t * t * (3 - 2 * t)
        let offset = (y * width + x) * 4
        for c in 0..<3 {
          extended[offset + c] = UInt8(
            (Double(extended[offset + c]) * (1 - blend)
              + Double(blurred[offset + c]) * blend).rounded())
        }
      }
    }
    return makeImage(extended)
  }
}
