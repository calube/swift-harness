import Darwin
import Foundation
import SwiftGateDomain

public enum RunStoreError: Error, Sendable, Equatable {
  case invalidRunID(String)
  case io(operation: String, path: String, reason: String)

  public var verdict: Verdict { .blocked }
}

/// What ``RunStore/keepRuns(in:)`` copied, and each run it couldn't with the reason.
public struct RunKeepOutcome: Sendable, Equatable {
  public struct Unkept: Sendable, Equatable {
    public let runID: String
    public let reason: String

    public init(runID: String, reason: String) {
      self.runID = runID
      self.reason = reason
    }
  }

  /// Run ids now in the destination, sorted.
  public let kept: [String]
  public let unkept: [Unkept]

  public init(kept: [String], unkept: [Unkept]) {
    self.kept = kept
    self.unkept = unkept
  }
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
  /// - Parameter headCommit: the commit `HEAD` was at when the run started, in both.
  public func record(
    _ report: RunReport, finishedAt: Date, command: String? = nil, steps: [String]? = nil,
    proofBases: [String]? = nil, headCommit: String? = nil, base: String? = nil
  ) throws(RunStoreError) {
    let directory = try runDirectory(for: report.runID)
    let reportFile = directory.appending(path: RunLayout.reportFileName)
    let reportData: Data
    let line: Data
    do {
      reportData = try RecordedRunReport.encode(
        RecordedRunReport(report: report, headCommit: headCommit))
      line = try RunHistoryJSON.encodeLine(
        RunHistoryRecord(
          report: report, finishedAt: finishedAt, command: command, steps: steps,
          proofBases: proofBases, headCommit: headCommit, base: base))
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

  /// Copies every run directory under this store into `destination`'s runs, so a worktree's gate
  /// reports outlive it. The history file stays behind: the destination's own history counts only
  /// its own runs. A run already in `destination` counts as kept, since run ids are unique.
  /// - Throws: when this store's runs directory exists but can't be listed.
  public func keepRuns(in destination: RunStore) throws(RunStoreError) -> RunKeepOutcome {
    let files = FileManager.default
    let source = worktreeRoot.appending(path: RunLayout.runsDirectory, directoryHint: .isDirectory)
    let names: [String]
    do {
      names = try files.contentsOfDirectory(atPath: source.path)
    } catch CocoaError.fileReadNoSuchFile {
      return RunKeepOutcome(kept: [], unkept: [])
    } catch {
      throw .io(operation: "list", path: source.path, reason: error.localizedDescription)
    }
    var kept: [String] = []
    var unkept: [RunKeepOutcome.Unkept] = []
    for runID in names.sorted() where RunID.isValid(runID) {
      let from = source.appending(path: runID, directoryHint: .isDirectory)
      var isDirectory: ObjCBool = false
      guard files.fileExists(atPath: from.path, isDirectory: &isDirectory), isDirectory.boolValue
      else { continue }
      let to = destination.worktreeRoot.appending(
        path: RunLayout.runDirectory(for: runID), directoryHint: .isDirectory)
      var destinationIsDirectory: ObjCBool = false
      if files.fileExists(atPath: to.path, isDirectory: &destinationIsDirectory),
        destinationIsDirectory.boolValue
      {
        kept.append(runID)
        continue
      }
      do {
        try files.createDirectory(
          at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: from, to: to)
        kept.append(runID)
      } catch {
        unkept.append(.init(runID: runID, reason: error.localizedDescription))
      }
    }
    return RunKeepOutcome(kept: kept, unkept: unkept)
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
