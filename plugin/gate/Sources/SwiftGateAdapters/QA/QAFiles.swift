import Foundation
import SwiftGateDomain

/// Why a `qa` file or folder couldn't be read or written, naming the path.
public struct QAFilesError: Error, Sendable, Equatable, CustomStringConvertible {
  public let path: String
  public let reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }

  public var description: String { "\(path): \(reason)" }
}

/// The file writes `qa run` and `qa adopt` make.
public enum QAFiles {
  /// Writes `data` at `url` atomically, making its parent folders first.
  public static func write(_ data: Data, to url: URL) throws(QAFilesError) {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    } catch {
      throw QAFilesError(path: url.path, reason: error.localizedDescription)
    }
  }

  /// Replaces `destination` with a copy of `source`, so no file of an earlier copy survives.
  /// - Returns: how many files the copy holds.
  public static func replace(_ destination: URL, withCopyOf source: URL) throws(QAFilesError)
    -> Int
  {
    let files = FileManager.default
    // The copy lands beside the destination first, so a failed copy leaves the old one whole.
    let staging = destination.deletingLastPathComponent().appending(
      path:
        ".\(destination.lastPathComponent).adopting-\(ProcessInfo.processInfo.processIdentifier)",
      directoryHint: .isDirectory)
    do {
      try? files.removeItem(at: staging)
      try files.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try files.copyItem(at: source, to: staging)
    } catch {
      try? files.removeItem(at: staging)
      throw QAFilesError(path: source.path, reason: "copying: \(error.localizedDescription)")
    }
    do {
      if files.fileExists(atPath: destination.path) {
        _ = try files.replaceItemAt(destination, withItemAt: staging)
      } else {
        try files.moveItem(at: staging, to: destination)
      }
    } catch {
      try? files.removeItem(at: staging)
      throw QAFilesError(path: destination.path, reason: error.localizedDescription)
    }
    let enumerator = files.enumerator(
      at: destination, includingPropertiesForKeys: [.isRegularFileKey])
    return (enumerator?.allObjects ?? []).compactMap { $0 as? URL }.filter {
      (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.count
  }

  /// The folders directly under `directory`, sorted; empty when it doesn't exist.
  public static func subdirectories(of directory: URL) throws(QAFilesError) -> [String] {
    let files = FileManager.default
    var isDirectory: ObjCBool = false
    guard files.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return [] }
    guard isDirectory.boolValue else {
      throw QAFilesError(path: directory.path, reason: "not a folder")
    }
    do {
      return try files.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey]
      )
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .map(\.lastPathComponent).sorted()
    } catch {
      throw QAFilesError(path: directory.path, reason: error.localizedDescription)
    }
  }
}

extension QAFiles {
  /// The newest `qa/report.json` under `runsDirectory` for `plan` over every row: neither at the
  /// merge base nor `--after` a task. A report that doesn't decode can't name its plan, so it is
  /// passed over.
  public static func newestWholeRun(plan: String, runsDirectory: URL) -> RunReportInput<QAReport>
  {
    .missing(path: runsDirectory.path)
  }
}

/// The checkouts `git worktree list` names for a repository, canonical.
public struct QACheckouts: Sendable {
  private let runner: any ProcessRunner
  private let repositoryRoot: String

  public init(runner: any ProcessRunner, repositoryRoot: String) {
    self.runner = runner
    self.repositoryRoot = repositoryRoot
  }

  public func paths() async throws(QAFilesError) -> [String] {
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: ["worktree", "list", "--porcelain"],
          workingDirectory: repositoryRoot, timeout: .seconds(60)))
    } catch {
      throw QAFilesError(path: repositoryRoot, reason: "git worktree list: \(error)")
    }
    guard output.status.isSuccess else {
      throw QAFilesError(
        path: repositoryRoot,
        reason:
          "git worktree list failed: \(output.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
    let prefix = "worktree "
    return output.stdout.text.split(separator: "\n")
      .filter { $0.hasPrefix(prefix) }
      .map { CanonicalPath.of(URL(filePath: String($0.dropFirst(prefix.count)))) }
  }
}
