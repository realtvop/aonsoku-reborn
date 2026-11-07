import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct ResolutionTests {
  static func main() {
    // Source/target/output examples from resolution.md, including no-upscale.
    let cases: [(Int, Int, Int, Int, Bool, Int, Int)] = [
      (3000, 3000, 1668, 1668, false, 1668, 1668), (1200, 1200, 1668, 1668, false, 1200, 1200),
      (600, 600, 1668, 1668, false, 600, 600), (2400, 1800, 1600, 1600, false, 1600, 1600),
      (900, 1200, 1668, 1668, false, 1200, 1200), (900, 900, 1080, 1440, true, 900, 1200),
      (900, 1600, 1080, 1440, true, 1080, 1440), (1800, 2400, 1080, 1440, true, 1080, 1440),
      (1200, 300, 1668, 1668, false, 1200, 1200), (3001, 3001, 3001, 3001, false, 3000, 3000),
      (901, 901, 1080, 1440, true, 900, 1200), (2400, 1800, 2400, 2400, false, 2400, 2400),
    ]
    for (sw, sh, tw, th, portrait, w, h) in cases {
      let source = CGSize(width: sw, height: sh)
      let target = CGSize(width: tw, height: th)
      let ios = LockScreenArtworkResolution.base(
        source: source, target: target, portrait: portrait)!
      precondition(ios.width == w && ios.height == h)
      let subjectScale = min(Double(w) / Double(sw), Double(h) / Double(sh))
      precondition(subjectScale <= 1)
      precondition(w <= tw && h <= th)
      precondition(portrait ? w * 4 == h * 3 : w == h)
    }
    let capped = LockScreenArtworkResolution.plan(
      source: CGSize(width: 3000, height: 3000),
      target: CGSize(width: 3000, height: 3000), portrait: false, budgetBytes: 80 * 1_000_000,
      checkHardware: false)!
    precondition(capped.format.width == 1000 && capped.reason == "resource-budget")
    let pixels = Data(repeating: 255, count: 1282 * 1282 * 4)
    let image = CGImage(
      width: 1282, height: 1282, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: 1282 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent)!
    let encoded = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      encoded, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    precondition(
      LockScreenArtworkRenderer.decode(encoded as Data, maxPixelSize: 1282)!.width == 1282)
    precondition(LockScreenArtworkRenderer.decode(encoded as Data, maxPixelSize: 1282)!.width == 1282)
    precondition(
      LockScreenArtworkRenderer.sourceRect(for: image, format: LockScreenArtworkFormat(width: 1282, height: 1282))
        == CGRect(x: 0, y: 0, width: 1282, height: 1282))
    let owner = UUID()
    let other = UUID()
    LockScreenArtworkDemand.shared.setCurrentCover("a")
    let id = LockScreenArtworkDemand.shared.add(owner: owner, cover: "a", motion: true)!
    precondition(LockScreenArtworkDemand.shared.requested && LockScreenArtworkDemand.shared.dynamicRequested)
    LockScreenArtworkDemand.shared.setCurrentCover("b")
    precondition(!LockScreenArtworkDemand.shared.requested)
    LockScreenArtworkDemand.shared.setCurrentCover("a")
    LockScreenArtworkDemand.shared.remove(id, owner: other)
    precondition(LockScreenArtworkDemand.shared.dynamicRequested)
    LockScreenArtworkDemand.shared.releaseAll(owner: owner)
    precondition(!LockScreenArtworkDemand.shared.requested)
    print(
      "Resolution examples, alignment, resource cap, consumer/source/session demand isolation passed"
    )
  }
}
