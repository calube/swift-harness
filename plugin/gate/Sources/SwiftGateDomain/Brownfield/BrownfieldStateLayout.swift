import Foundation

/// Where a brownfield clone keeps its state: clone-wide files under the git common dir, and each
/// worktree's own under its git dir. Git never sees either, so the user's tree stays clean.
public struct BrownfieldStateLayout: Sendable, Equatable {
  /// The same directory name a ``StateRoot/gitDir(_:)`` root uses, so the clone and worktree
  /// halves of the state sit side by side.
  public static let directoryName = RunLayout.gitDirDirectory

  /// `git rev-parse --git-common-dir`, absolute.
  public let commonDir: URL
  /// `git rev-parse --git-dir` of the worktree, absolute.
  public let gitDir: URL

  public init(commonDir: URL, gitDir: URL) {
    self.commonDir = commonDir
    self.gitDir = gitDir
  }

  /// `<common>/swift-harness/`.
  public var cloneRoot: URL {
    commonDir.appending(path: Self.directoryName, directoryHint: .isDirectory)
  }
  /// The applied config.
  public var config: URL { cloneRoot.appending(path: BrownfieldConfig.fileName) }
  /// The hook wiring `swiftgate claude` passes to `claude --settings`.
  public var settings: URL { cloneRoot.appending(path: "settings.json") }
  /// The last proposal and its inputs' hashes.
  public var discoverDirectory: URL { directory("discover") }
  public var discoverLast: URL { discoverDirectory.appending(path: "last.json") }
  /// Files modified before discovery ran, which workers never stage.
  public var discoverDirty: URL { discoverDirectory.appending(path: "dirty.json") }
  public var baselineDirectory: URL { directory("baseline") }
  /// Known failures at the base tree `tree`.
  public func baseline(tree: String) -> URL { baselineDirectory.appending(path: "\(tree).json") }
  public var warmupDirectory: URL { directory("warmup") }
  /// Warm test times and cold cost at the base tree `tree`.
  public func warmup(tree: String) -> URL { warmupDirectory.appending(path: "\(tree).json") }
  public var plansDirectory: URL { directory("plans") }
  /// `PLAN.md`, a copy of an untracked spec, the ledger, the lock and the report.
  public func plan(slug: String) -> URL {
    plansDirectory.appending(path: slug, directoryHint: .isDirectory)
  }
  /// `<git-dir>/swift-harness/`: what `.harness/` holds in an owned repository.
  public var worktreeRoot: URL { StateRoot.gitDir(gitDir).directory }
  /// Scratch worktrees for prove, the baseline and generators.
  public var scratchDirectory: URL {
    worktreeRoot.appending(path: "scratch", directoryHint: .isDirectory)
  }

  private func directory(_ name: String) -> URL {
    cloneRoot.appending(path: name, directoryHint: .isDirectory)
  }
}
