import Darwin
import Foundation
import SwiftGateDomain

public enum RunStoreError: Error, Sendable, Equatable {
  case invalidRunID(String)
  case io(operation: String, path: String, reason: String)

  public var verdict: Verdict { .blocked }
}

/// Persists runs under a worktree's `.harness/runs/`: one directory per run holding its logs and
/// `report.json`, plus the shared `history.jsonl`.
public struct RunStore: Sendable {
  public let worktreeRoot: URL

  public init(worktreeRoot: URL) {
    self.worktreeRoot = worktreeRoot
  }

  public var historyFile: URL {
    worktreeRoot.appending(path: RunLayout.historyFile, directoryHint: .notDirectory)
  }

  /// Creates (if needed) and returns the directory for `runID`, where a run writes its artifacts.
  public func runDirectory(for runID: String) throws(RunStoreError) -> URL {
    guard RunID.isValid(runID) else { throw .invalidRunID(runID) }
    let url = worktreeRoot.appending(
      path: RunLayout.runDirectory(for: runID), directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw .io(operation: "mkdir", path: url.path, reason: error.localizedDescription)
    }
    return url
  }

  /// Writes the run's `report.json` and appends its summary to `history.jsonl`.
  public func record(
    _ report: RunReport, finishedAt: Date, command: String? = nil, steps: [String]? = nil,
    proofBases: [String]? = nil
  ) throws(RunStoreError) {
    let directory = try runDirectory(for: report.runID)
    let reportFile = directory.appending(path: RunLayout.reportFileName)
    let reportData: Data
    let line: Data
    do {
      reportData = try RunReportJSON.encode(report)
      line = try RunHistoryJSON.encodeLine(
        RunHistoryRecord(
          report: report, finishedAt: finishedAt, command: command, steps: steps,
          proofBases: proofBases))
    } catch {
      throw .io(operation: "encode", path: reportFile.path, reason: String(describing: error))
    }
    do {
      try reportData.write(to: reportFile, options: .atomic)
    } catch {
      throw .io(operation: "write", path: reportFile.path, reason: error.localizedDescription)
    }
    try append(line, to: historyFile.path)
  }

  public func readHistory() throws(RunStoreError) -> (
    records: [RunHistoryRecord], invalidLines: Int
  ) {
    let data: Data
    do {
      data = try Data(contentsOf: historyFile)
    } catch CocoaError.fileReadNoSuchFile {
      return ([], 0)
    } catch {
      throw .io(operation: "read", path: historyFile.path, reason: error.localizedDescription)
    }
    return RunHistoryJSON.decode(data)
  }

  /// Several sessions can share a worktree, so each record is one `O_APPEND` write made under an
  /// exclusive `flock`; lines never interleave.
  private func append(_ line: Data, to path: String) throws(RunStoreError) {
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw Self.posixError("open", path) }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw Self.posixError("flock", path) }
    defer { flock(fd, LOCK_UN) }
    var offset = 0
    while offset < line.count {
      let written = line.withUnsafeBytes { buffer -> Int in
        guard let base = buffer.baseAddress else { return 0 }
        return write(fd, base + offset, buffer.count - offset)
      }
      if written < 0 {
        if errno == EINTR { continue }
        throw Self.posixError("write", path)
      }
      offset += written
    }
  }

  private static func posixError(_ operation: String, _ path: String) -> RunStoreError {
    .io(operation: operation, path: path, reason: String(cString: strerror(errno)))
  }
}
