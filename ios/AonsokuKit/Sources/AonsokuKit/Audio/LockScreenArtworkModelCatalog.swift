import CryptoKit
import Foundation

/// Immutable Apache-2.0 Apple DAV2 Small packages. URL bytes are authenticated
/// by a pinned SHA256 before local compilation; no server credentials are used.
enum LockScreenArtworkModelCatalog {
  static let revision = "cfef6f6f2a70783dedc0bfae40cecbc2052285d3"
  static var licenseURL: URL? {
    #if SWIFT_PACKAGE
      return Bundle.module.url(forResource: "DepthAnythingV2-LICENSE", withExtension: "txt")
    #else
      return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Resources/DepthAnythingV2-LICENSE.txt")
    #endif
  }
  struct File {
    let path: String
    let bytes: Int64
    let sha256: String
  }
  static func package(_ tier: LockScreenArtworkTier) -> String {
    switch tier {
    case .fp16: return "DepthAnythingV2SmallF16.mlpackage"
    case .p8: return "DepthAnythingV2SmallF16P8.mlpackage"
    case .p6: return "DepthAnythingV2SmallF16P6.mlpackage"
    }
  }
  static func files(_ tier: LockScreenArtworkTier) -> [File] {
    switch tier {
    case .fp16:
      return [
        File(
          path: "Data/com.apple.CoreML/model.mlmodel", bytes: 399433,
          sha256: "44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042"),
        File(
          path: "Data/com.apple.CoreML/weights/weight.bin", bytes: 49_419_072,
          sha256: "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed"),
        File(
          path: "Manifest.json", bytes: 617,
          sha256: "2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7"),
      ]
    case .p8:
      return [
        File(
          path: "Data/com.apple.CoreML/model.mlmodel", bytes: 416615,
          sha256: "da3f4c6a8be93a439b1bc56ba57074c09f270b3d28052d798bc106d1259e5a1d"),
        File(
          path: "Data/com.apple.CoreML/weights/weight.bin", bytes: 24_830_720,
          sha256: "660a57cf7becfeac080a9bb02a263be59fd57b5c4d17ff8912833bc8b6edae04"),
        File(
          path: "Manifest.json", bytes: 617,
          sha256: "5530317f2a7c4318b34efd9855694480a78122d8be89e703278b0f7b9337dbdc"),
      ]
    case .p6:
      return [
        File(
          path: "Data/com.apple.CoreML/model.mlmodel", bytes: 416488,
          sha256: "ee53b8f7e1682a66857b5a3d54cf04a97d89a98cf7b5979b5d726aaf9c24ad70"),
        File(
          path: "Data/com.apple.CoreML/weights/weight.bin", bytes: 18_621_888,
          sha256: "3e9bcccc9e35ae6f9759551f481a3b77226510bd74536e059ee9780dda618381"),
        File(
          path: "Manifest.json", bytes: 617,
          sha256: "70e469c0359c89851bde4cdc1d89bf13fa06d4fccd8907b9b5f744e548ecaadf"),
      ]
    }
  }
  static func bytes(_ tier: LockScreenArtworkTier) -> Int64 {
    files(tier).reduce(0) { $0 + $1.bytes }
  }
  static func url(_ tier: LockScreenArtworkTier, file: File) -> URL {
    URL(
      string:
        "https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/\(revision)/\(package(tier))/\(file.path)"
    )!
  }
  static func verify(_ url: URL, file: File) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    var count: Int64 = 0
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
      hash.update(data: data)
      count += Int64(data.count)
    }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard count == file.bytes, digest == file.sha256 else {
      throw NSError(domain: "ArtworkModelIntegrity", code: 1)
    }
  }
}
