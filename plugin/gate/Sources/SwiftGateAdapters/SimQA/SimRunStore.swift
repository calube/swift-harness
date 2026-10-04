import Darwin
import Foundation
import SwiftGateDomain

public enum SimRunStoreError: Error, Sendable, Equatable {
  case io(operation: String, path: String, errno: Int32)
  case unreadableSession(path: String, reason: SimSessionDecodingError)
  case unreadableSteps(path: String, reason: SimStepDecodingError)

  public var message: String {
    switch self {
    case .io(let operation, let path, let code):
      "\(operation) \(path) failed: \(String(cString: strerror(code)))"
    case .unreadableSession(let path, let reason): "\(path): \(reason.message)"
    case .unreadableSteps(let path, let reason): "\(path): \(reason.message)"
    }
  }
}

/// A step's screenshot while it is being captured: a dot-prefixed file in `steps/` that no step
/// line names until the store commits it.
public struct SimStepStaging: Sendable, Equatable {
  public var screenshot: URL

  public init(screenshot: URL) {
    self.screenshot = screenshot
  }
}

/// The files of one run's `sim/` folder that `sim snap` reads and writes.
///
/// A step becomes visible all at once: its files are put in place and its line appended while
/// the step log is locked, so two snaps never take one number and a failed snap leaves no line
/// naming a file that isn't there.
public struct SimRunStore: Sendable {
  public let simDirectory: URL

  public init(simDirectory: URL) {
    self.simDirectory = simDirectory
  }

  public var stepLog: URL { simDirectory.appending(path: SimStep.logFileName) }
  public var agentDeviceLog: URL { simDirectory.appending(path: SimSession.logFileName) }

  public func session() throws(SimRunStoreError) -> SimSession {
    let path = simDirectory.appending(path: SimSession.fileName).path
    guard let data = try Self.contents(path) else {
      throw .io(operation: "read", path: path, errno: ENOENT)
    }
    do {
      return try SimSession.decode(data)
    } catch {
      throw .unreadableSession(path: path, reason: error)
    }
  }

  /// The run's steps in order; none when the log doesn't exist yet.
  public func steps() throws(SimRunStoreError) -> [SimStep] {
    guard let data = try Self.contents(stepLog.path) else { return [] }
    do {
      return try SimStep.decodeLog(data)
    } catch {
      throw .unreadableSteps(path: stepLog.path, reason: error)
    }
  }

  /// Creates `steps/` and names a staging file for the next screenshot.
  public func stage() throws(SimRunStoreError) -> SimStepStaging {
    let directory = simDirectory.appending(path: SimStep.directoryName, directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw .io(operation: "mkdir", path: directory.path, errno: EACCES)
    }
    // Dot-prefixed, so no step name matches it, and ending `.png` like the file it becomes.
    let token = UUID().uuidString.prefix(8)  // swiftgate:allow det.uuid-init — a unique temp name
    return SimStepStaging(screenshot: directory.appending(path: ".\(getpid())-\(token).png"))
  }

  /// Removes whatever a failed capture left at `staging`.
  public func discard(_ staging: SimStepStaging) {
    unlink(staging.screenshot.path)
  }

  /// Numbers the step after the log's last line, moves the staged screenshot to its `NNN.png`,
  /// writes `treeJSON` unmodified to the step's tree path, and appends `makeStep(n)`'s line with
  /// an fsync, all under an exclusive lock on the log. A step with no tree takes no `treeJSON`.
  /// On a throw no line was appended and the step's files are removed.
  public func commit(
    _ staging: SimStepStaging, treeJSON: Data?, makeStep: (Int) -> SimStep
  ) throws(SimRunStoreError) -> SimStep {
    let log = stepLog.path
    let fd = open(log, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw .io(operation: "open", path: log, errno: errno) }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw .io(operation: "lock", path: log, errno: errno) }

    let existing = try Self.readAll(fd, path: log)
    let steps: [SimStep]
    do {
      steps = try SimStep.decodeLog(existing)
    } catch {
      throw .unreadableSteps(path: log, reason: error)
    }
    let step = makeStep(steps.count + 1)
    let tree = step.tree.map { simDirectory.appending(path: $0) }
    let screenshot = simDirectory.appending(path: step.screenshot)
    if let tree, let treeJSON {
      do {
        try treeJSON.write(to: tree, options: .atomic)
      } catch {
        throw .io(operation: "write", path: tree.path, errno: EIO)
      }
    }
    guard rename(staging.screenshot.path, screenshot.path) == 0 else {
      let code = errno
      if let tree { unlink(tree.path) }
      throw .io(operation: "rename", path: screenshot.path, errno: code)
    }

    let line = step.line() + Data("\n".utf8)
    let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    let writeErrno = errno
    guard written == line.count, fsync(fd) == 0 else {
      let code = written == line.count ? errno : (written < 0 ? writeErrno : EIO)
      // A torn line would make the whole log unreadable, so cut it back to the last full step.
      ftruncate(fd, off_t(existing.count))
      if let tree { unlink(tree.path) }
      unlink(screenshot.path)
      throw .io(operation: "append", path: log, errno: code)
    }
    return step
  }

  /// Appends `line` to `agent-device.log`; best effort, since the failure it records is already
  /// being reported.
  public func appendLog(_ line: String) {
    try? FileManager.default.createDirectory(at: simDirectory, withIntermediateDirectories: true)
    let fd = open(agentDeviceLog.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }
    let bytes = Array((line + "\n").utf8)
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
  }

  /// `nil` when nothing is at `path`.
  private static func contents(_ path: String) throws(SimRunStoreError) -> Data? {
    do {
      return try Data(contentsOf: URL(filePath: path))
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw .io(operation: "read", path: path, errno: EIO)
    }
  }

  private static func readAll(_ fd: Int32, path: String) throws(SimRunStoreError) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    var offset: off_t = 0
    while true {
      let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) }
      guard count >= 0 else { throw .io(operation: "read", path: path, errno: errno) }
      if count == 0 { return data }
      data.append(contentsOf: buffer[..<count])
      offset += off_t(count)
    }
  }
}
