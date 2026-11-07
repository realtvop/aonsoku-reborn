import AVFoundation
import AppKit
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() {
    throw NSError(
      domain: "ArtworkTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

private func png(_ image: CGImage) -> Data {
  let result = NSMutableData()
  let target = CGImageDestinationCreateWithData(
    result, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(target, image, nil)
  precondition(CGImageDestinationFinalize(target))
  return result as Data
}

private func pixels(_ image: CGImage) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
  bytes.withUnsafeMutableBytes {
    let canvas = CGContext(
      data: $0.baseAddress, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  }
  return bytes
}

private func fixture(width: Int, height: Int) -> CGImage {
  let canvas = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let gradient = CGGradient(
    colorsSpace: canvas.colorSpace,
    colors: [
      CGColor(red: 0.05, green: 0.18, blue: 0.32, alpha: 1),
      CGColor(red: 0.72, green: 0.42, blue: 0.25, alpha: 1),
    ] as CFArray,
    locations: [0, 1])!
  canvas.drawLinearGradient(
    gradient, start: .zero,
    end: CGPoint(x: width, y: height), options: [])
  canvas.setFillColor(CGColor(red: 0.95, green: 0.8, blue: 0.38, alpha: 1))
  canvas.fillEllipse(
    in: CGRect(
      x: Double(width) * 0.3, y: Double(height) * 0.3,
      width: Double(width) * 0.4, height: Double(height) * 0.4))
  // Detailed foreground and asymmetric edge stripes expose cropping,
  // orientation mistakes, and unintended repeated subjects.
  canvas.setFillColor(CGColor(gray: 0.9, alpha: 1))
  canvas.fill(CGRect(x: 0, y: 0, width: max(1, width / 50), height: height))
  canvas.setFillColor(CGColor(gray: 0.08, alpha: 1))
  canvas.fill(
    CGRect(
      x: width - max(1, width / 50), y: 0,
      width: max(1, width / 50), height: height))
  return canvas.makeImage()!
}

private func prepare(
  _ store: LockScreenArtworkStore, data: Data, image: CGImage,
  format: LockScreenArtworkFormat = .tall, motion: Bool = false
) async
  -> LockScreenArtworkAsset?
{
  await withCheckedContinuation { continuation in
    store.prepare(data: data, source: image, format: format, motion: motion) {
      continuation.resume(returning: $0)
    }
  }
}

private func video(_ asset: LockScreenArtworkAsset) async -> URL? {
  await withCheckedContinuation { continuation in
    asset.requestVideo { continuation.resume(returning: $0) }
  }
}

private func releasedVideo(_ store: LockScreenArtworkStore, image: CGImage) async -> URL {
  let asset = await prepare(store, data: png(image), image: image)!
  return await video(asset)!
}

@main
struct ArtworkTests {
  static func main() async throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let examples = [
      ("square", 600, 600), ("landscape", 900, 500), ("portrait", 400, 900),
      ("native-3x4", 600, 800), ("wide", 800, 100), ("tall", 100, 800), ("tiny", 1, 1),
    ]
    var images: [(String, CGImage, CGImage)] = []
    let started = Date()
    for format in [LockScreenArtworkFormat.tall, .square] {
      for (name, width, height) in examples {
        let source = fixture(width: width, height: height)
        let result = LockScreenArtworkRenderer.render(source, format: format)!
        try require(
          result.width == format.width && result.height == format.height,
          "\(name): incorrect output ratio")
        let rect = LockScreenArtworkRenderer.sourceRect(for: source, format: format)
        let w = Int(rect.width)
        let h = Int(rect.height)
        let scaled = CGContext(
          data: nil, width: w, height: h, bitsPerComponent: 8,
          bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        scaled.interpolationQuality = .high
        scaled.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        let expected = pixels(scaled.makeImage()!)
        let actual = pixels(result)
        // Compare every pixel of the resampled source: no subject cropping,
        // deformation beyond integer rounding, or blur inside the source.
        for y in 0..<h {
          for x in 0..<w {
            let a = ((y + Int(rect.minY)) * 720 + x + Int(rect.minX)) * 4
            let b = (y * w + x) * 4
            for c in 0..<4 {
              try require(
                actual[a + c] == expected[b + c], "\(name): source pixel changed")
            }
          }
        }
        try require(
          stride(from: 3, to: actual.count, by: 4).allSatisfy { actual[$0] == 255 },
          "\(name): transparent hole in output")
        // Smooth source regions should not acquire a color step at the join.
        if rect.minY > 0 && w > 10 {
          let x = Int(rect.midX)
          for y in [Int(rect.minY), Int(rect.maxY)] {
            for c in 0..<3 {
              let delta = abs(
                Int(actual[(y * 720 + x) * 4 + c])
                  - Int(actual[((y - 1) * 720 + x) * 4 + c]))
              try require(delta < 6, "\(name): hard edge at vertical join")
            }
          }
        }
        if format == .tall {
          images.append((name, source, result))
        } else {
          try png(result).write(to: output.appendingPathComponent(name + "-1x1.png"))
        }
      }
    }
    let fixtureData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let cover = LockScreenArtworkRenderer.decode(fixtureData)!
    images.append(("repository-cover", cover, LockScreenArtworkRenderer.render(cover)!))
    try require(
      LockScreenArtworkRenderer.decode(Data([0, 1, 2])) == nil, "invalid image accepted")

    let huge = LockScreenArtworkRenderer.decode(png(fixture(width: 4000, height: 2000)))!
    try require(max(huge.width, huge.height) <= 1200, "large image decode was not bounded")
    let transparent = CGContext(
      data: nil, width: 32, height: 32, bitsPerComponent: 8,
      bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    transparent.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
    let flattened = pixels(LockScreenArtworkRenderer.render(transparent.makeImage()!)!)
    try require(
      stride(from: 3, to: flattened.count, by: 4).allSatisfy { flattened[$0] == 255 },
      "transparent image was not flattened")

    // EXIF orientation is applied before deriving the portrait geometry.
    let jpeg = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(
      destination, fixture(width: 160, height: 80),
      [kCGImagePropertyOrientation: 6] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    let oriented = LockScreenArtworkRenderer.decode(jpeg as Data)!
    try require(oriented.width == 80 && oriented.height == 160, "EXIF orientation lost")

    let store = LockScreenArtworkStore(directory: scratch, byteLimit: 1, countLimit: 1)
    var first: LockScreenArtworkAsset? = await prepare(store, data: fixtureData, image: cover)
    try require(first != nil, "preview preparation failed")
    let same = await prepare(store, data: fixtureData, image: cover)
    try require(first === same, "same album preparation was not coalesced")
    try require(
      FileManager.default.fileExists(atPath: scratch.path),
      "static clip was not prewarmed before publication")
    async let a = video(same!)
    async let b = video(same!)
    let (urlA, urlB) = await (a, b)
    try require(urlA != nil && urlA == urlB, "concurrent video requests were not coalesced")
    let file = urlA!
    let movie = AVURLAsset(url: file)
    let videoTracks = try await movie.loadTracks(withMediaType: .video)
    let audioTracks = try await movie.loadTracks(withMediaType: .audio)
    let size = try await videoTracks[0].load(.naturalSize)
    let duration = try await movie.load(.duration)
    try require(
      size == CGSize(width: 720, height: 960), "encoded video has incorrect dimensions")
    try require(audioTracks.isEmpty, "artwork video contains audio")
    try require(abs(duration.seconds - 2) < 0.05, "unexpected artwork duration")
    let generator = AVAssetImageGenerator(asset: movie)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let frame0 = try await generator.image(at: .zero).image
    let frame1 = try await generator.image(at: CMTime(value: 1, timescale: 1)).image
    let p0 = pixels(frame0)
    let p1 = pixels(frame1)
    let preview = pixels(first!.preview)
    let motion =
      zip(p0, p1).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(p0.count)
    let error =
      zip(p0, preview).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
      / Double(p0.count)
    FileHandle.standardError.write(
      Data("Frame motion MAE=\(motion), preview MAE=\(error)\n".utf8))
    try require(motion < 1, "static artwork video visibly changes between frames")
    try require(error < 8, "video differs from preview (orientation/color)")
    let cached = await video(first!)
    try require(cached == file, "repeated request did not reuse disk video")

    let square = await prepare(store, data: fixtureData, image: cover, format: .square)!
    try require(square.id != first!.id, "square asset reused tall identity")
    try require(
      square.preview.width == 720 && square.preview.height == 720,
      "square preview ratio incorrect")
    let squareFile = await video(square)!
    let listed: [[String: Any]] = await withCheckedContinuation { continuation in
      store.listVideos { continuation.resume(returning: $0) }
    }
    try require(
      listed.contains(where: {
        ($0["id"] as? String) == square.id && ($0["protected"] as? Bool) == true
      }),
      "active static video not reported as protected")
    let removedActive: Bool = await withCheckedContinuation { continuation in
      store.deleteVideo(id: square.id) { continuation.resume(returning: $0) }
    }
    try require(!removedActive, "cache manager removed active artwork")
    let cleared: (Int, Int) = await withCheckedContinuation { continuation in
      store.clearVideos(kind: "all") { continuation.resume(returning: ($0, $1)) }
    }
    try require(cleared.0 == 0 && cleared.1 >= 2, "bulk clear did not protect current videos")
    let traversal: Bool = await withCheckedContinuation { continuation in
      store.deleteVideo(id: "../outside") { continuation.resume(returning: $0) }
    }
    try require(!traversal, "cache deletion accepted a filesystem path")
    try require(squareFile != file, "square video replaced tall video")
    let squareMovie = AVURLAsset(url: squareFile)
    let squareTracks = try await squareMovie.loadTracks(withMediaType: .video)
    let squareSize = try await squareTracks[0].load(.naturalSize)
    let squareDuration = try await squareMovie.load(.duration)
    let squareAudio = try await squareMovie.loadTracks(withMediaType: .audio)
    try require(
      squareSize == CGSize(width: 720, height: 720) && abs(squareDuration.seconds - 2) < 0.05
        && squareAudio.isEmpty,
      "square video is not a silent two-second 1:1 clip")
    let squareGenerator = AVAssetImageGenerator(asset: squareMovie)
    let squareFrame0 = try await squareGenerator.image(at: .zero).image
    let squareFrame1 = try await squareGenerator.image(at: CMTime(value: 1, timescale: 1)).image
    try require(pixels(squareFrame0) == pixels(squareFrame1), "square clip changes over time")

    let secondData = png(images[0].1)
    let second = await prepare(store, data: secondData, image: images[0].1)!
    try require(second.id != first!.id, "new content reused stale artwork ID")
    let secondURL = await video(second)!
    try require(
      FileManager.default.fileExists(atPath: file.path), "live first artwork was evicted")
    try require(
      FileManager.default.fileExists(atPath: secondURL.path),
      "live second artwork was evicted")
    first = nil
    // 'same' intentionally still holds the first asset: system retention
    // past a track switch must keep the file valid even above the budget.
    _ = await prepare(store, data: png(images[1].1), image: images[1].1)
    try require(
      FileManager.default.fileExists(atPath: file.path), "retained artwork URL invalidated")
    withExtendedLifetime(same) {}

    let evicting = LockScreenArtworkStore(
      directory: scratch.appendingPathComponent("eviction"), byteLimit: 1, countLimit: 1)
    let unpinnedURL = await releasedVideo(evicting, image: images[0].1)
    let next = await prepare(evicting, data: png(images[1].1), image: images[1].1)!
    try require(
      !FileManager.default.fileExists(atPath: unpinnedURL.path),
      "unpinned cache entry exceeded budget")
    withExtendedLifetime(next) {}

    let failing = LockScreenArtworkStore(directory: URL(fileURLWithPath: "/dev/null/artwork"))
    let unavailable = await prepare(failing, data: secondData, image: images[0].1)!
    let failedURL = await video(unavailable)
    try require(failedURL == nil, "encoding failure did not return nil fallback")

    // Restart reuse requires no live memory entry from the original store.
    let restarted = LockScreenArtworkStore(directory: scratch)
    let restored = await prepare(restarted, data: fixtureData, image: cover)!
    let reused = await video(restored)
    try require(reused == file, "video cache not reused after store restart")

    // Motion uses the same production store, and prepares the movie before
    // publication. A system URL request must never regenerate a missing one.
    let motionStore = LockScreenArtworkStore(directory: scratch.appendingPathComponent("motion"))
    let scene = fixture(width: 512, height: 512)
    let analysis = LockScreenArtworkMotion.analyze(scene)
    print("Synthetic Vision analysis: \(analysis.mode), \(analysis.reason)")
    try require(
      LockScreenArtworkMotion.analyze(fixture(width: 8, height: 8)).mask == nil,
      "tiny artwork received unsafe parallax")
    let textCanvas = CGContext(
      data: nil, width: 512, height: 512, bitsPerComponent: 8,
      bytesPerRow: 2048, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    textCanvas.setFillColor(CGColor(gray: 0, alpha: 1))
    textCanvas.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    textCanvas.textPosition = CGPoint(x: 40, y: 240)
    CTLineDraw(
      CTLineCreateWithAttributedString(
        NSAttributedString(
          string: "ALBUM COVER",
          attributes: [.font: NSFont.systemFont(ofSize: 45), .foregroundColor: NSColor.white])),
      textCanvas)
    let textAnalysis = LockScreenArtworkMotion.analyze(textCanvas.makeImage()!)
    try require(
      textAnalysis.mask == nil
        && !LockScreenArtworkMotion.textRegions(textCanvas.makeImage()!).isEmpty,
      "recognized text was locally warped")
    let ci = CIContext(options: [.cacheIntermediates: false])
    for format in [LockScreenArtworkFormat.tall, .square] {
      let moving = await prepare(
        motionStore, data: png(scene), image: scene,
        format: format, motion: true)!
      let movingURL = await video(moving)!
      let clip = AVURLAsset(url: movingURL)
      let tracks = try await clip.loadTracks(withMediaType: .video)
      let clipDuration = try await clip.load(.duration)
      let fps = try await tracks[0].load(.nominalFrameRate)
      let audio = try await clip.loadTracks(withMediaType: .audio)
      try require(
        abs(clipDuration.seconds - 6) < 0.05 && abs(fps - 24) < 0.1 && audio.isEmpty,
        "motion clip is not silent six-second 24fps")
      let gen = AVAssetImageGenerator(asset: clip)
      gen.requestedTimeToleranceBefore = .zero
      gen.requestedTimeToleranceAfter = .zero
      let start = try await gen.image(at: .zero).image
      let quarter = try await gen.image(at: CMTime(value: 36, timescale: 24)).image
      let end = try await gen.image(at: CMTime(value: 143, timescale: 24)).image
      func mae(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        let a = pixels(lhs)
        let b = pixels(rhs)
        return zip(a, b).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(a.count)
      }
      let movement = mae(start, quarter)
      let seam = mae(start, end)
      FileHandle.standardError.write(
        Data("\(format.label) motion MAE=\(movement), loop seam MAE=\(seam)\n".utf8))
      let previous = try await gen.image(at: CMTime(value: 142, timescale: 24)).image
      let adjacent = mae(previous, end)
      // H.264's first I-frame and last P-frame can differ in quantization
      // even for identical input. Bound the seam against both visible
      // error and an ordinary neighboring-frame step, not total motion.
      try require(
        movement > 0.1 && seam < 2 && seam < adjacent * 2 + 1,
        "motion is absent or loop has a visible jump")
      let depth = LockScreenArtworkMotion.depthImage(
        .init(mask: scene, reason: "test-mask"), source: scene, format: format)
      let bounds = CGRect(x: 0, y: 0, width: format.width, height: format.height)
      let exact0 = ci.createCGImage(
        LockScreenArtworkMotion.frame(moving.preview, depth: depth, phase: 0), from: bounds)!
      let exact1 = ci.createCGImage(
        LockScreenArtworkMotion.frame(moving.preview, depth: depth, phase: 1), from: bounds)!
      try require(mae(exact0, exact1) < 0.01, "renderer is not exactly periodic")
      let warped = ci.createCGImage(
        LockScreenArtworkMotion.frame(moving.preview, depth: depth, phase: 0.25), from: bounds)!
      let opaque = pixels(warped)
      try require(
        stride(from: 3, to: opaque.count, by: 4).allSatisfy { opaque[$0] == 255 },
        "parallax created uncovered pixels")
      let camera = ci.createCGImage(
        LockScreenArtworkMotion.frame(moving.preview, depth: nil, phase: 0.25), from: bounds)!
      try require(mae(camera, warped) > 0.01, "depth map has no effect on rendering")
      try png(warped).write(to: output.appendingPathComponent("parallax-\(format.height).png"))
      try Data(contentsOf: movingURL).write(
        to: output.appendingPathComponent("motion-\(format.height).mp4"))
      try FileManager.default.removeItem(at: movingURL)
      let missingMotion = await video(moving)
      try require(missingMotion == nil, "system request regenerated missing motion")
    }
    // Flat depth regions must translate as whole layers. The built-in
    // displacement/bump filter only moved mask gradients and failed this
    // observable geometry check despite changing a few boundary pixels.
    let layerCanvas = LockScreenArtworkRenderer.render(scene)!
    let layerBounds = CGRect(x: 0, y: 0, width: 720, height: 960)
    let nearFrame = ci.createCGImage(
      LockScreenArtworkMotion.frame(
        layerCanvas,
        depth: CIImage(color: .white), phase: 0.25), from: layerBounds)!
    let farFrame = ci.createCGImage(
      LockScreenArtworkMotion.frame(
        layerCanvas,
        depth: CIImage(color: .black), phase: 0.25), from: layerBounds)!
    func subjectCenterX(_ image: CGImage) -> Double {
      let bytes = pixels(image)
      var count = 0.0
      var sum = 0.0
      for y in 0..<image.height {
        for x in 0..<image.width {
          let index = (y * image.width + x) * 4
          if bytes[index] > 210 && bytes[index + 1] > 170 && bytes[index + 2] < 130 {
            sum += Double(x)
            count += 1
          }
        }
      }
      return sum / count
    }
    let separation = abs(subjectCenterX(nearFrame) - subjectCenterX(farFrame))
    try require(
      separation > 18 && separation < 22,
      "flat-depth foreground/background did not move oppositely by 20px")

    let grayProvider = CGDataProvider(data: Data(repeating: 128, count: 256 * 256) as CFData)!
    let grayMap = CGImage(
      width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 8,
      bytesPerRow: 256, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
      provider: grayProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let mappedNeutral = LockScreenArtworkMotion.depthImage(
      .init(mask: grayMap, reason: "test"),
      source: scene, format: .tall)!
    let neutralFrame = ci.createCGImage(
      LockScreenArtworkMotion.frame(
        layerCanvas,
        depth: mappedNeutral, phase: 0.25), from: layerBounds)!
    let idealNeutral = ci.createCGImage(
      LockScreenArtworkMotion.frame(
        layerCanvas,
        depth: CIImage(
          color: CIColor(
            red: 0.5, green: 0.5, blue: 0.5, alpha: 1,
            colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!), phase: 0.25),
      from: layerBounds)!
    FileHandle.standardError.write(
      Data(
        "neutral center error=\(abs(subjectCenterX(neutralFrame) - subjectCenterX(idealNeutral)))\n"
          .utf8))
    try require(
      abs(subjectCenterX(neutralFrame) - subjectCenterX(idealNeutral)) < 0.2,
      "depth data received a gamma transform instead of preserving neutral 0.5")

    let canceledURL = scratch.appendingPathComponent("canceled.mp4")
    let cancellation: Result<URL, Error> = await withCheckedContinuation { continuation in
      LockScreenArtworkVideo.write(
        image: images[0].2, to: canceledURL,
        queue: DispatchQueue(label: "test.cancel"), motion: true, shouldContinue: { false }
      ) {
        continuation.resume(returning: $0)
      }
    }
    if case .success = cancellation { throw NSError(domain: "CancellationFailed", code: 1) }
    let token = LockScreenArtworkGeneration()
    token.update(2)
    let stale: LockScreenArtworkAsset? = await withCheckedContinuation { continuation in
      motionStore.prepare(
        data: fixtureData, source: cover, motion: true,
        shouldContinue: { token.contains(1) }
      ) { continuation.resume(returning: $0) }
    }
    try require(stale == nil, "stale revision generated artwork")

    let gib: UInt64 = 1024 * 1024 * 1024
    let oldOptions = try JSONDecoder().decode(
      LockScreenArtworkOptions.self,
      from: Data(
        "{\"immersiveEnabled\":false,\"dynamicEnabled\":true,\"quality\":\"p8\",\"wifiOnly\":false}"
          .utf8))
    try require(
      oldOptions.dynamicEnabled && !oldOptions.immersiveEnabled && oldOptions.quality == "p8"
        && oldOptions.motionAmplitude == 1 && oldOptions.motionSpeed == 1,
      "adding motion controls reset existing native preferences")
    let defaultID = LockScreenArtworkStore.motionID(
      digest: "fixture", format: .square,
      backend: "dav2-f16", parameters: .init())
    let adjustedID = LockScreenArtworkStore.motionID(
      digest: "fixture", format: .square,
      backend: "dav2-f16", parameters: .init(amplitude: 1.5, speed: 0.75))
    try require(defaultID != adjustedID, "motion parameters reused stale DAV2 video")
    try require(
      LockScreenArtworkStore.motionID(
        digest: "fixture", format: .square, backend: "camera", parameters: .init())
        == LockScreenArtworkStore.motionID(
          digest: "fixture", format: .square, backend: "camera",
          parameters: .init(amplitude: 2, speed: 0.5)),
      "motion controls changed the quick camera fallback cache")
    for speed in LockScreenArtworkMotionParameters.speeds {
      let parameters = LockScreenArtworkMotionParameters(amplitude: 2, speed: speed)
      let movieURL = output.appendingPathComponent("controls-\(Int(speed * 100)).mp4")
      try? FileManager.default.removeItem(at: movieURL)
      let result: Result<URL, Error> = await withCheckedContinuation { continuation in
        LockScreenArtworkVideo.write(
          image: layerCanvas, to: movieURL,
          queue: DispatchQueue(label: "test.controls"), motion: true,
          depth: mappedNeutral, parameters: parameters
        ) { continuation.resume(returning: $0) }
      }
      let clip = AVURLAsset(url: try result.get())
      let duration = try await clip.load(.duration)
      let tracks = try await clip.loadTracks(withMediaType: .video)
      let fps = try await tracks[0].load(.nominalFrameRate)
      let audio = try await clip.loadTracks(withMediaType: .audio)
      try require(
        abs(duration.seconds - 6 / speed) < 0.01 && duration.seconds < 30
          && abs(fps - 24) < 0.01 && audio.isEmpty,
        "speed preset exceeded artwork limits or broke frame timing")
    }
    for format in [LockScreenArtworkFormat.tall, .square] {
      let canvas = LockScreenArtworkRenderer.render(scene, format: format)!
      let bounds = CGRect(x: 0, y: 0, width: format.width, height: format.height)
      let parameters = LockScreenArtworkMotionParameters(amplitude: 2)
      let near = ci.createCGImage(
        LockScreenArtworkMotion.frame(
          canvas,
          depth: CIImage(color: .white), phase: 0.25, parameters: parameters), from: bounds)!
      let far = ci.createCGImage(
        LockScreenArtworkMotion.frame(
          canvas,
          depth: CIImage(color: .black), phase: 0.25, parameters: parameters), from: bounds)!
      try require(
        abs(abs(subjectCenterX(near) - subjectCenterX(far)) - 40) < 1,
        "2x amplitude did not double the foreground/background displacement")
      for phase in [0.0, 0.125, 0.25, 0.5, 0.75, 1.0] {
        let frame = ci.createCGImage(
          LockScreenArtworkMotion.frame(
            canvas,
            depth: CIImage(color: .white), phase: phase, parameters: parameters), from: bounds)!
        let bytes = pixels(frame)
        try require(
          stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 },
          "maximum amplitude exposed transparent edges")
      }
    }
    try require(
      !LockScreenArtworkMotionAnalysis(mask: nil, reason: "generation-deferred").canCache,
      "deferred inference must not poison the DAV2 video cache")
    try require(
      !LockScreenArtworkMotionAnalysis(mask: nil, reason: "model-failed").canCache,
      "failed inference must not become a DAV2 camera video")
    try require(
      LockScreenArtworkMotionAnalysis(mask: scene, reason: "dav2-f16").canCache,
      "completed depth must be cacheable")
    try require(LockScreenArtworkTier.automatic(memory: 4 * gib) == .p6, "4GB default tier wrong")
    try require(LockScreenArtworkTier.automatic(memory: 6 * gib) == .p8, "6GB default tier wrong")
    try require(LockScreenArtworkTier.automatic(memory: 8 * gib) == .fp16, "8GB default tier wrong")
    try require(
      LockScreenArtworkTier.automatic(memory: 7 * gib) == .fp16, "reported 8GB class RAM wrong")
    try require(
      LockScreenArtworkTier.select(quality: "auto", memory: 8 * gib, thermal: 1) == .p8,
      "fair thermal state did not lower quality")
    try require(
      LockScreenArtworkTier.select(quality: "fp16", memory: 8 * gib, thermal: 2) == nil,
      "serious heat did not pause generation")
    try require(
      LockScreenArtworkTier.select(quality: "p8", memory: 6 * gib, thermal: 0, memoryPressure: true)
        == nil,
      "memory pressure did not pause generation")
    try require(
      LockScreenArtworkTier.select(quality: "auto", memory: 8 * gib, thermal: 0, recovering: true)
        == .p6,
      "memory recovery did not use P6")
    try require(
      LockScreenArtworkTier.select(
        quality: "fp16", memory: 8 * gib, thermal: 0,
        availableMemory: 300 * 1024 * 1024) == .p8, "available RAM did not cap FP16")
    try require(
      LockScreenArtworkTier.select(
        quality: "p8", memory: 6 * gib, thermal: 0,
        availableMemory: 150 * 1024 * 1024) == .p6, "available RAM did not cap P8")
    try require(
      LockScreenArtworkTier.select(
        quality: "p6", memory: 4 * gib, thermal: 0,
        availableMemory: 80 * 1024 * 1024) == nil, "low available RAM did not pause")
    try LockScreenArtworkSettings.shared.configure(["dynamicEnabled": true, "quality": "p8"])
    try LockScreenArtworkSettings.shared.configure(["immersiveEnabled": false])
    try require(
      !LockScreenArtworkSettings.shared.value.immersiveEnabled
        && LockScreenArtworkSettings.shared.value.dynamicEnabled
        && LockScreenArtworkSettings.shared.value.quality == "p8",
      "independent artwork switches lost settings")
    var rejectedTier = false
    do { try LockScreenArtworkSettings.shared.configure(["quality": "unknown"]) } catch {
      rejectedTier = true
    }
    try require(rejectedTier, "invalid model tier accepted")
    for bad in [["motionAmplitude": 2.1], ["motionAmplitude": Double.nan], ["motionSpeed": 0.25]] {
      var rejected = false
      do { try LockScreenArtworkSettings.shared.configure(bad) } catch { rejected = true }
      try require(rejected, "invalid motion controls bypassed native bounds")
    }
    let corrupt = scratch.appendingPathComponent("corrupt-weight.bin")
    try Data([1, 2, 3]).write(to: corrupt)
    var rejectedBytes = false
    do {
      try LockScreenArtworkModelCatalog.verify(
        corrupt, file: LockScreenArtworkModelCatalog.files(.p6)[0])
    } catch { rejectedBytes = true }
    try require(rejectedBytes, "invalid downloaded bytes passed SHA256 validation")

    if ProcessInfo.processInfo.environment["AONSOKU_TEST_MODEL_DOWNLOAD"] == "1" {
      try LockScreenArtworkSettings.shared.configure([
        "immersiveEnabled": true,
        "dynamicEnabled": true, "wifiOnly": false,
      ])
      let manager = LockScreenArtworkModelManager(
        directory: scratch.appendingPathComponent("models"))
      manager.request(.p6)
      let deadline = Date().addingTimeInterval(240)
      while manager.modelURL(.p6) == nil && Date() < deadline {
        if let state = manager.snapshot().first(where: { $0["tier"] as? String == "p6" }),
          state["status"] as? String == "error"
        {
          throw NSError(
            domain: "ModelDownloadTest", code: 1,
            userInfo: [NSLocalizedDescriptionKey: state["error"] as? String ?? "download failed"])
        }
        try await Task.sleep(nanoseconds: 250_000_000)
      }
      try require(manager.modelURL(.p6) != nil, "download/compile did not produce a ready model")
      let inferred = LockScreenArtworkDepthModel.analyze(
        cover,
        candidate: LockScreenArtworkDepthModel.candidate(.p6), modelURL: manager.modelURL(.p6))
      try require(inferred.mask != nil, "downloaded production P6 could not infer")
      try require(manager.availableTier(upTo: .fp16) == .p6, "available lower-tier fallback failed")
      manager.remove(.p6)
      while manager.modelURL(.p6) != nil && Date() < deadline {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      try require(manager.modelURL(.p6) == nil, "model removal did not release disk resources")
      print(
        "PASS: streamed P6 download, pinned checksums, local Core ML compile/inference, tier fallback, removal"
      )
    }

    let sheet = CGContext(
      data: nil, width: 1600, height: 1000, bitsPerComponent: 8,
      bytesPerRow: 1600 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sheet.setFillColor(CGColor(gray: 0.12, alpha: 1))
    sheet.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
    for (index, example) in images.enumerated() {
      let x = (index % 4) * 400
      let y = 500 - (index / 4) * 500
      sheet.draw(example.2, in: CGRect(x: x + 200, y: y + 90, width: 180, height: 240))
      let scale = min(180.0 / Double(example.1.width), 240.0 / Double(example.1.height))
      let w = Double(example.1.width) * scale
      let h = Double(example.1.height) * scale
      sheet.draw(
        example.1,
        in: CGRect(
          x: Double(x) + 100 - w / 2, y: Double(y) + 210 - h / 2,
          width: w, height: h))
      sheet.textPosition = CGPoint(x: x + 20, y: y + 55)
      let label = NSAttributedString(
        string: example.0 + "   →   3:4",
        attributes: [
          .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white,
        ])
      CTLineDraw(CTLineCreateWithAttributedString(label), sheet)
      try png(example.2).write(to: output.appendingPathComponent(example.0 + ".png"))
    }
    try png(sheet.makeImage()!).write(to: output.appendingPathComponent("contact-sheet.png"))
    try Data(contentsOf: file).write(
      to: output.appendingPathComponent("static-artwork.mp4"), options: .atomic)
    print(
      "PASS: 3:4 + 1:1 preservation, seams, decode/EXIF, prewarmed/coalesced video, cache reuse/eviction, live-file protection, failure fallback, smooth motion, filled/flat-depth parallax, neutral depth, text protection, cancellation, RAM/thermal tiers, settings, integrity"
    )
    print(
      String(
        format: "Native validation completed in %.2fs. QA artifacts: %@",
        Date().timeIntervalSince(started), output.path))
  }
}
