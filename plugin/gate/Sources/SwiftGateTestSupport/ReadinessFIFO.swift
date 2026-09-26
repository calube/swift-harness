import Darwin
import Foundation

/// A named pipe a child process writes to once it reaches the point a test waits for: the
/// handshake that replaces guessing how long a child takes to start on a loaded machine.
public struct ReadinessFIFO: Sendable {
  private let directory: URL
  public var path: String { directory.appending(path: "ready").path }

  public init() throws {
    let token = UUID().uuidString  // swiftgate:allow det.uuid-init — unique directory
    directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-ready-\(token)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard mkfifo(directory.appending(path: "ready").path, 0o600) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  /// The lines writers send, finishing once every writer has closed the pipe, which for a child
  /// holding it open until it exits means the child is gone. Reads on a dedicated thread, not the
  /// cooperative pool, since opening the pipe blocks until a writer opens it.
  public func lines() -> AsyncStream<String> {
    let path = path
    return AsyncStream { continuation in
      Thread {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
          continuation.finish()
          return
        }
        defer { close(fd) }
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
          let count = read(fd, &buffer, buffer.count)
          if count < 0, errno == EINTR { continue }
          if count <= 0 { break }
          pending += buffer[0..<count]
          while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            continuation.yield(String(decoding: pending[..<newline], as: UTF8.self))
            pending.removeSubrange(...newline)
          }
        }
        if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
        continuation.finish()
      }.start()
    }
  }

  /// The first line a writer sends, or `nil` if every writer closed the pipe without one.
  public func firstLine() async -> String? {
    var lines = lines().makeAsyncIterator()
    return await lines.next()
  }

  public func remove() { try? FileManager.default.removeItem(at: directory) }
}
