import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a frame couldn't be taken from a video.
public struct VideoFrameError: Error, Sendable, Equatable {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }
}

/// Reads 1 frame of a recorded video into a PNG.
public protocol VideoFrameReading: Sendable {
  /// Writes the frame on screen `ms` into `video` to `png`; a time past the video's end takes its
  /// last frame.
  func frame(video: URL, atMs ms: Int, to png: URL) async throws(VideoFrameError)
}

/// ``VideoFrameReading`` with AVFoundation, which decodes the frame at the exact time asked.
public struct AVVideoFrames: VideoFrameReading {
  public init() {}

  public func frame(video: URL, atMs ms: Int, to png: URL) async throws(VideoFrameError) {
    let asset = AVURLAsset(url: video)
    let image: CGImage
    do {
      let duration = try await asset.load(.duration)
      // The last frame starts before the video's end, so a later time reads that frame.
      let last = CMTimeSubtract(duration, CMTime(value: 1, timescale: 1000))
      let asked = CMTime(value: CMTimeValue(max(0, ms)), timescale: 1000)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      generator.appliesPreferredTrackTransform = true
      image = try await generator.image(at: CMTimeMinimum(asked, max(last, .zero))).image
    } catch {
      throw VideoFrameError("\(video.lastPathComponent) has no frame at \(ms) ms: \(error)")
    }
    guard
      let destination = CGImageDestinationCreateWithURL(
        png as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw VideoFrameError("\(png.path) can't be written as a PNG") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw VideoFrameError("\(png.path) wasn't written")
    }
  }
}
