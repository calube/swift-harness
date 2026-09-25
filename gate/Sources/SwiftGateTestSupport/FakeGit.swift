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
  private let changed: [String]?
  private let mergeBaseResult: String?
  private let failure: GitError?
  private let prefix: String
  private let addedSince: [AddedLines]
  private let revisions: [String: String]
  private let hashes: [String: String]
  private let contentsAtRef: [String: String]
  private let refReads = Mutex<[String]>([])
  private let reads = Mutex<[String]>([])
  private let changedSince = Mutex<[String]>([])

  /// - Parameters:
  ///   - changed: what ``changedFiles(since:)`` returns; defaults to the staged paths.
  ///   - mergeBase: what ``mergeBase(_:_:)`` returns for any pair of refs.
  ///   - prefix: what ``workingDirectoryPrefix()`` returns.
  ///   - addedSince: what ``addedLines(since:)`` returns for any ref.
  ///   - revisions: what ``revision(_:)`` answers per ref; others are `nil`.
  ///   - contentHashes: what ``contentHashes(of:)`` answers per path; others are omitted.
  ///   - contentsAtRef: what ``contents(of:at:)`` answers per path for any ref; others are
  ///     omitted.
  public init(
    staged: [String: StagedFile] = [:], changed: [String]? = nil, mergeBase: String? = nil,
    prefix: String = "", addedSince: [AddedLines] = [], revisions: [String: String] = [:],
    contentHashes: [String: String] = [:], contentsAtRef: [String: String] = [:],
    failure: GitError? = nil
  ) {
    self.contentsAtRef = contentsAtRef
    self.revisions = revisions
    self.hashes = contentHashes
    self.prefix = prefix
    self.addedSince = addedSince
    self.staged = staged
    self.changed = changed
    self.mergeBaseResult = mergeBase
    self.failure = failure
  }

  /// Refs passed to ``changedFiles(since:)``, in call order.
  public var changedSinceRefs: [String] { changedSince.withLock { $0 } }

  /// Refs passed to ``contents(of:at:)``, in call order.
  public var contentRefs: [String] { refReads.withLock { $0 } }

  /// Paths passed to ``stagedContents(of:)``, in call order.
  public var contentReads: [String] { reads.withLock { $0 } }

  public func changedFiles(since ref: String) async throws(GitError) -> [String] {
    if let failure { throw failure }
    changedSince.withLock { $0.append(ref) }
    return changed ?? staged.keys.sorted()
  }

  public func addedLines(since ref: String) async throws(GitError) -> [AddedLines] {
    if let failure { throw failure }
    changedSince.withLock { $0.append(ref) }
    return addedSince
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

  public func contents(of paths: [String], at ref: String) async throws(GitError) -> [String:
    String]
  {
    if let failure { throw failure }
    refReads.withLock { $0.append(ref) }
    return contentsAtRef.filter { paths.contains($0.key) }
  }

  public func contentHashes(of paths: [String]) async throws(GitError) -> [String: String] {
    if let failure { throw failure }
    return hashes.filter { paths.contains($0.key) }
  }

  public func revision(_ ref: String) async throws(GitError) -> String? {
    if let failure { throw failure }
    return revisions[ref]
  }

  public func workingDirectoryPrefix() async throws(GitError) -> String {
    if let failure { throw failure }
    return prefix
  }

  public func mergeBase(_ first: String, _ second: String) async throws(GitError) -> String? {
    if let failure { throw failure }
    return mergeBaseResult
  }
}
