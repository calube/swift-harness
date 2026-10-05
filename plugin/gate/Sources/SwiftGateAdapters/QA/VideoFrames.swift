import Foundation

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
    throw VideoFrameError("frames aren't read yet")
  }
}
