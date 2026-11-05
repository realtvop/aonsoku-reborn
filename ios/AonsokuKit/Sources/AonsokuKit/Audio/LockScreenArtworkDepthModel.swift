import CoreGraphics
import CoreImage
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One Core ML boundary for all DAV2 tiers. The exclusive queue also owns model
/// compilation/deletion; no MLModel is retained after the autorelease pool.
enum LockScreenArtworkDepthModel {
  struct Candidate: Decodable {
    let id: String
    let path: String
    let precision: String
    let license: String
    let input: String
    let output: String
    let width: Int
    let height: Int
    let metricDepth: Bool
    let packageBytes: Int
    let compiledBytes: Int
  }
  private static let inferenceQueue = DispatchQueue(
    label: "com.aonsoku.artwork-coreml", qos: .utility)
  static func exclusive<T>(_ work: () throws -> T) rethrows -> T {
    try inferenceQueue.sync(execute: work)
  }
  #if DEBUG
    private struct Manifest: Decodable { let models: [Candidate] }
    static let directory: URL = {
      if let path = ProcessInfo.processInfo.environment["AONSOKU_MOTION_MODELS_DIR"] {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
      return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("motion-models", isDirectory: true)
    }()
    static var candidates: [Candidate] {
      guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
        let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
      else { return [] }
      return manifest.models.filter {
        ["dav2-f16", "dav2-p8", "dav2-p6"].contains($0.id) && !$0.path.contains("/")
          && $0.path.hasSuffix(".mlmodelc")
          && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.path).path)
      }
    }

  #endif

  static func candidate(_ tier: LockScreenArtworkTier) -> Candidate {
    Candidate(
      id: tier.backend, path: "model.mlmodelc",
      precision: tier == .fp16 ? "W16A16" : (tier == .p8 ? "palette-W8A16" : "palette-W6A16"),
      license: "Apache-2.0", input: "image", output: "depth", width: 518, height: 392,
      metricDepth: false, packageBytes: Int(LockScreenArtworkModelCatalog.bytes(tier)),
      compiledBytes: 0)
  }

  static func analyze(
    _ image: CGImage, candidate: Candidate, modelURL: URL? = nil,
    benchmark: Bool = false, shouldContinue: () -> Bool = { true }
  ) -> LockScreenArtworkMotionAnalysis {
    exclusive {
      autoreleasepool {
        do {
          guard shouldContinue() else { return .init(mask: nil, reason: "generation-deferred") }
          let total = LockScreenArtworkMeasurement("model-total backend=\(candidate.id)")
          defer { total.finish("precision=\(candidate.precision) computeUnits=all") }
          let configuration = MLModelConfiguration()
          configuration.computeUnits = .all
          let loading = LockScreenArtworkMeasurement("model-load backend=\(candidate.id)")
          let modelPath: URL
          #if DEBUG
            modelPath = modelURL ?? directory.appendingPathComponent(candidate.path)
          #else
            guard let modelURL else { return .init(mask: nil, reason: "model-unavailable") }
            modelPath = modelURL
          #endif
          let model = try MLModel(
            contentsOf: modelPath,
            configuration: configuration)
          loading.finish(
            "packageBytes=\(candidate.packageBytes) compiledBytes=\(candidate.compiledBytes)")
          guard shouldContinue() else { return .init(mask: nil, reason: "generation-deferred") }
          let resizing = LockScreenArtworkMeasurement("model-input backend=\(candidate.id)")
          var buffer: CVPixelBuffer?
          guard
            CVPixelBufferCreate(
              nil, candidate.width, candidate.height,
              kCVPixelFormatType_32BGRA,
              [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
              == kCVReturnSuccess,
            let buffer
          else { return .init(mask: nil, reason: "model-input-failed") }
          let context = CIContext(options: [.cacheIntermediates: false])
          defer { context.clearCaches() }
          let input = CIImage(cgImage: image).transformed(
            by: CGAffineTransform(
              scaleX: Double(candidate.width) / Double(image.width),
              y: Double(candidate.height) / Double(image.height)))
          context.render(
            input, to: buffer,
            bounds: CGRect(
              x: 0, y: 0,
              width: candidate.width, height: candidate.height),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
          let provider = try MLDictionaryFeatureProvider(dictionary: [
            candidate.input: MLFeatureValue(pixelBuffer: buffer)
          ])
          resizing.finish("size=\(candidate.width)x\(candidate.height)")
          guard shouldContinue() else { return .init(mask: nil, reason: "generation-deferred") }
          let predicting = LockScreenArtworkMeasurement(
            "model-predict-cold backend=\(candidate.id)")
          let result = try model.prediction(from: provider)
          predicting.finish("firstPrediction=true")
          // Warm measurements use the same image and loaded model. They
          // are distinct from generation and never counted as cold load.
          #if DEBUG
            if benchmark {
              for index in 0..<3 {
                try autoreleasepool {
                  let warm = LockScreenArtworkMeasurement(
                    "model-predict-warm backend=\(candidate.id)")
                  _ = try model.prediction(from: provider)
                  warm.finish("run=\(index + 1)")
                }
              }
            }
          #endif
          guard shouldContinue() else { return .init(mask: nil, reason: "generation-deferred") }
          let mapping = LockScreenArtworkMeasurement("model-depth-map backend=\(candidate.id)")
          let feature = result.featureValue(for: candidate.output)
          let mask: CGImage?
          if let values = feature?.multiArrayValue {
            mask = normalizedMap(values, metric: candidate.metricDepth)
          } else if let pixels = feature?.imageBufferValue {
            mask = normalizedMap(pixels, metric: candidate.metricDepth)
          } else {
            mask = nil
          }
          mapping.finish("valid=\(mask != nil)")
          #if DEBUG
            if let mask,
              benchmark || ProcessInfo.processInfo.environment["AONSOKU_MOTION_OUTPUT_DIR"] != nil
            {
              let output =
                ProcessInfo.processInfo.environment["AONSOKU_MOTION_OUTPUT_DIR"].map {
                  URL(fileURLWithPath: $0, isDirectory: true)
                }
                ?? directory.deletingLastPathComponent().appendingPathComponent("motion-comparison")
              try? FileManager.default.createDirectory(
                at: output, withIntermediateDirectories: true)
              var excluded = output
              var attributes = URLResourceValues()
              attributes.isExcludedFromBackup = true
              try? excluded.setResourceValues(attributes)
              if let values = feature?.multiArrayValue {
                exportRaw(values, to: output, backend: candidate.id, metric: candidate.metricDepth)
              } else if let pixels = feature?.imageBufferValue {
                exportRaw(pixels, to: output, backend: candidate.id, metric: candidate.metricDepth)
              }
              if let target = CGImageDestinationCreateWithURL(
                output.appendingPathComponent("depth-" + candidate.id + ".png") as CFURL,
                UTType.png.identifier as CFString, 1, nil)
              {
                CGImageDestinationAddImage(target, mask, nil)
                CGImageDestinationFinalize(target)
              }
            }
          #endif
          return .init(mask: mask, reason: mask == nil ? "model-flat-or-invalid" : candidate.id)
        } catch {
          #if os(iOS)
            NativeLogger.shared.warn(
              "model failed backend=\(candidate.id) domain=\((error as NSError).domain) code=\((error as NSError).code) description=\(error.localizedDescription)",
              source: "NowPlayingArtwork")
          #else
            print("model failed backend=\(candidate.id) error=\(error.localizedDescription)")
          #endif
          return .init(mask: nil, reason: "model-failed")
        }
      }
    }
  }

  #if DEBUG
    private static func saveRaw(
      width: Int, height: Int, to output: URL,
      backend: String, metric: Bool, value: (Int, Int) -> Float
    ) {
      var raw = [Float](repeating: 0, count: width * height)
      for y in 0..<height {
        for x in 0..<width { raw[y * width + x] = value(x, y) }
      }
      raw.withUnsafeBytes {
        try? Data($0).write(
          to: output.appendingPathComponent("raw-" + backend + ".f32"), options: .atomic)
      }
      let metadata: [String: Any] = [
        "width": width, "height": height,
        "dtype": "float32-little-endian", "order": "row-major",
        "units": metric ? "meters" : "model-relative-inverse-depth-image",
        "normalization": "none; raw model output before inverse/percentile mapping",
      ]
      if let json = try? JSONSerialization.data(
        withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
      {
        try? json.write(
          to: output.appendingPathComponent("raw-" + backend + ".json"), options: .atomic)
      }
    }

    private static func exportRaw(
      _ array: MLMultiArray, to output: URL, backend: String, metric: Bool
    ) {
      let shape = array.shape.map { $0.intValue }
      let strides = array.strides.map { $0.intValue }
      guard shape.count >= 2, shape.dropLast(2).allSatisfy({ $0 == 1 }) else { return }
      let height = shape[shape.count - 2]
      let width = shape[shape.count - 1]
      saveRaw(width: width, height: height, to: output, backend: backend, metric: metric) { x, y in
        let offset = y * strides[strides.count - 2] + x * strides[strides.count - 1]
        switch array.dataType {
        case .float16:
          return Float(
            Float16(bitPattern: array.dataPointer.assumingMemoryBound(to: UInt16.self)[offset]))
        case .float32: return array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
        case .double: return Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
        default: return .nan
        }
      }
    }

    private static func exportRaw(
      _ buffer: CVPixelBuffer, to output: URL, backend: String, metric: Bool
    ) {
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
      let format = CVPixelBufferGetPixelFormatType(buffer)
      let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
      guard
        format == kCVPixelFormatType_OneComponent32Float
          || format == kCVPixelFormatType_OneComponent16Half
      else { return }
      saveRaw(
        width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
        to: output, backend: backend, metric: metric
      ) { x, y in
        let row = base.advanced(by: y * rowBytes)
        if format == kCVPixelFormatType_OneComponent32Float {
          return row.assumingMemoryBound(to: Float.self)[x]
        }
        return Float(Float16(bitPattern: row.assumingMemoryBound(to: UInt16.self)[x]))
      }
    }

  #endif
  private static func normalizedMap(_ array: MLMultiArray, metric: Bool) -> CGImage? {
    let shape = array.shape.map { $0.intValue }
    guard shape.count >= 2, shape.dropLast(2).allSatisfy({ $0 == 1 }) else { return nil }
    let height = shape[shape.count - 2]
    let width = shape[shape.count - 1]
    let strides = array.strides.map { $0.intValue }
    guard width > 0, height > 0 else { return nil }
    func value(_ x: Int, _ y: Int) -> Double {
      let offset = y * strides[strides.count - 2] + x * strides[strides.count - 1]
      let raw: Double
      switch array.dataType {
      case .float16:
        raw = Double(
          Float16(bitPattern: array.dataPointer.assumingMemoryBound(to: UInt16.self)[offset]))
      case .float32: raw = Double(array.dataPointer.assumingMemoryBound(to: Float.self)[offset])
      case .double: raw = array.dataPointer.assumingMemoryBound(to: Double.self)[offset]
      default: return .nan
      }
      return raw
    }
    return makeMap(width: width, height: height, metric: metric, value: value)
  }

  private static func normalizedMap(_ buffer: CVPixelBuffer, metric: Bool) -> CGImage? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let type = CVPixelBufferGetPixelFormatType(buffer)
    guard
      type == kCVPixelFormatType_OneComponent32Float
        || type == kCVPixelFormatType_OneComponent16Half
    else { return nil }
    return makeMap(width: width, height: height, metric: metric) { x, y in
      let row = address.advanced(by: y * rowBytes)
      if type == kCVPixelFormatType_OneComponent32Float {
        return Double(row.assumingMemoryBound(to: Float.self)[x])
      }
      return Double(Float16(bitPattern: row.assumingMemoryBound(to: UInt16.self)[x]))
    }
  }

  private static func makeMap(
    width: Int, height: Int, metric: Bool,
    value: (Int, Int) -> Double
  ) -> CGImage? {
    var field = [Double](repeating: 0, count: 256 * 256)
    for y in 0..<256 {
      for x in 0..<256 {
        let raw = value(min(width - 1, x * width / 256), min(height - 1, y * height / 256))
        field[y * 256 + x] = metric ? (raw > 0 ? 1 / raw : .nan) : raw
      }
    }
    let valid = field.filter { $0.isFinite }.sorted()
    guard valid.count > field.count * 9 / 10 else { return nil }
    let low = valid[valid.count * 2 / 100]
    let high = valid[valid.count * 98 / 100]
    guard high - low > max(1e-8, abs(high) * 1e-5) else { return nil }
    let bytes = field.map { sample -> UInt8 in
      guard sample.isFinite else { return 0 }
      return UInt8((max(0, min(1, (sample - low) / (high - low))) * 255).rounded())
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 8,
      bytesPerRow: 256, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}
