import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit

public typealias PlatformImage = UIImage
public typealias PlatformView = UIView
#elseif canImport(AppKit)
import AppKit

public typealias PlatformImage = NSImage
public typealias PlatformView = NSView
#endif

extension PlatformImage {
    /// A bitmap image showing `cgImage` at its pixel size.
    static func make(cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        UIImage(cgImage: cgImage)
        #else
        NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        #endif
    }

    /// The bitmap behind the image, if it has one.
    var platformCGImage: CGImage? {
        #if canImport(UIKit)
        cgImage
        #else
        cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}
