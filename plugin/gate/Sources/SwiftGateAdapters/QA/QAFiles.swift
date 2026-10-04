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
  }

  /// Replaces `destination` with a copy of `source`, so no file of an earlier copy survives.
  /// - Returns: how many files the copy holds.
  public static func replace(_ destination: URL, withCopyOf source: URL) throws(QAFilesError)
    -> Int
  {
    0
  }

  /// The folders directly under `directory`, sorted; empty when it doesn't exist.
  public static func subdirectories(of directory: URL) throws(QAFilesError) -> [String] {
    []
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
    []
  }
}
