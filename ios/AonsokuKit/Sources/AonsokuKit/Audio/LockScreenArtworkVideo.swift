import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

enum LockScreenArtworkError: Error {
  case encodingFailed
}

/// Silent system artwork: one held static frame or a bounded 24fps loop.
/// Frames are streamed through a bounded pool, never accumulated in memory.
enum LockScreenArtworkVideo {
  private final class Request {
    var submitted = false
    var frameIndex = 0
    var completion: ((Result<URL, Error>) -> Void)?

    init(_ completion: @escaping (Result<URL, Error>) -> Void) {
      self.completion = completion
    }

    func finish(_ result: Result<URL, Error>) {
      let callback = completion
      completion = nil
      callback?(result)
    }
  }

  static func write(
    image: CGImage, to url: URL, queue: DispatchQueue,
    motion: Bool = false, depth: CIImage? = nil,
    parameters: LockScreenArtworkMotionParameters = .init(),
    shouldContinue: @escaping () -> Bool = { true },
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    do {
      let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
      let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264,
          AVVideoWidthKey: image.width,
          AVVideoHeightKey: image.height,
          AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 2_000_000,
            AVVideoMaxKeyFrameIntervalKey: motion ? 48 : 1,
            AVVideoAllowFrameReorderingKey: false,
          ],
        ])
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
          kCVPixelBufferWidthKey as String: image.width,
          kCVPixelBufferHeightKey as String: image.height,
          kCVPixelBufferCGImageCompatibilityKey as String: true,
          kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
      )
      guard writer.canAdd(input) else { throw LockScreenArtworkError.encodingFailed }
      writer.add(input)
      guard writer.startWriting() else {
        throw writer.error ?? LockScreenArtworkError.encodingFailed
      }
      writer.startSession(atSourceTime: .zero)
      let context = CIContext(options: [.cacheIntermediates: false])
      let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
      let frameCount = motion ? (depth == nil ? 144 : parameters.frameCount) : 1
      let request = Request(completion)
      // Bound preparation if the encoder stalls. System URL callbacks only
      // receive already completed files and do not wait on this encoder.
      queue.asyncAfter(deadline: .now() + (motion ? 60 : 20)) { [weak request, weak writer] in
        guard let request, request.completion != nil, let writer else { return }
        writer.cancelWriting()
        request.finish(.failure(LockScreenArtworkError.encodingFailed))
      }
      input.requestMediaDataWhenReady(on: queue) {
        guard request.completion != nil, !request.submitted else { return }
        while input.isReadyForMoreMediaData && request.frameIndex < frameCount {
          guard !motion || shouldContinue() else {
            writer.cancelWriting()
            request.finish(.failure(LockScreenArtworkError.encodingFailed))
            return
          }
          let appended = autoreleasepool { () -> Bool in
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                nil, pool,
                [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary,
                &buffer) == kCVReturnSuccess, let buffer
            else { return false }
            let frame =
              motion
              ? LockScreenArtworkMotion.frame(
                image, depth: depth,
                phase: Double(request.frameIndex) / Double(frameCount), parameters: parameters)
              : CIImage(cgImage: image)
            context.render(frame, to: buffer, bounds: bounds, colorSpace: colorSpace)
            let time =
              motion
              ? CMTime(value: Int64(request.frameIndex), timescale: 24) : .zero
            return adaptor.append(buffer, withPresentationTime: time)
          }
          guard appended else {
            writer.cancelWriting()
            request.finish(.failure(writer.error ?? LockScreenArtworkError.encodingFailed))
            return
          }
          request.frameIndex += 1
        }
        if request.frameIndex == frameCount {
          request.submitted = true
          input.markAsFinished()
          writer.endSession(
            atSourceTime: motion
              ? CMTime(value: Int64(frameCount), timescale: 24) : CMTime(value: 2, timescale: 1))
          writer.finishWriting {
            queue.async {
              context.clearCaches()
              if writer.status == .completed {
                request.finish(.success(url))
              } else {
                request.finish(.failure(writer.error ?? LockScreenArtworkError.encodingFailed))
              }
            }
          }
        } else if writer.status == .failed || writer.status == .cancelled {
          request.finish(.failure(writer.error ?? LockScreenArtworkError.encodingFailed))
        }
      }
    } catch {
      completion(.failure(error))
    }
  }
}
