import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// An in-memory ``Git`` for command tests: staged files are given as full content plus the lines
/// the change adds. Records which paths callers read.
public final class FakeGit: Git {
  public struct StagedFile: Sendable {
    public let content: String
    public let addedLines: [ClosedRange<Int>]

    public init(content: String, addedLines: [ClosedRange<Int>]) {
      self.content = content
      self.addedLines = addedLines
    }
  }

  private let staged: [String: StagedFile]
  private let failure: GitError?
  private let reads = Mutex<[String]>([])

  public init(staged: [String: StagedFile] = [:], failure: GitError? = nil) {
    self.staged = staged
    self.failure = failure
  }

  /// Paths passed to ``stagedContents(of:)``, in call order.
  public var contentReads: [String] { reads.withLock { $0 } }

  public func changedFiles(since ref: String) async throws(GitError) -> [String] {
    if let failure { throw failure }
    return staged.keys.sorted()
  }

  public func stagedAddedLines() async throws(GitError) -> [AddedLines] {
    if let failure { throw failure }
    return staged.keys.sorted().compactMap { path in
      guard let file = staged[path], !file.addedLines.isEmpty else { return nil }
      return AddedLines(path: path, ranges: file.addedLines)
    }
  }

  public func stagedContents(of paths: [String]) async throws(GitError) -> [String: String] {
    if let failure { throw failure }
    reads.withLock { $0 += paths }
    var contents: [String: String] = [:]
    for path in paths {
      guard let file = staged[path] else {
        throw .commandFailed(
          arguments: ["cat-file", "blob", ":\(path)"], status: .exited(128), stderr: "not staged")
      }
      contents[path] = file.content
    }
    return contents
  }

  public func contentHashes(of paths: [String]) async throws(GitError) -> [String: String] {
    if let failure { throw failure }
    return [:]
  }

  public func mergeBase(_ first: String, _ second: String) async throws(GitError) -> String? {
    if let failure { throw failure }
    return nil
  }
}
