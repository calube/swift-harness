import Foundation

/// Where a brownfield clone keeps its state: clone-wide files under the git common dir, and each
/// worktree's own under its git dir. Git never sees either, so the user's tree stays clean.
public struct BrownfieldStateLayout: Sendable, Equatable {
  public static let directoryName = "swift-harness"

  /// `git rev-parse --git-common-dir`, absolute.
  public let commonDir: URL
  /// `git rev-parse --git-dir` of the worktree, absolute.
  public let gitDir: URL

  public init(commonDir: URL, gitDir: URL) {
    self.commonDir = commonDir
    self.gitDir = gitDir
  }

  /// `<common>/swift-harness/`.
  public var cloneRoot: URL { URL(filePath: "") }
  /// The applied config.
  public var config: URL { URL(filePath: "") }
  /// The hook wiring `swiftgate claude` passes to `claude --settings`.
  public var settings: URL { URL(filePath: "") }
  /// The last proposal and its inputs' hashes.
  public var discoverDirectory: URL { URL(filePath: "") }
  public var discoverLast: URL { URL(filePath: "") }
  /// Files modified before discovery ran, which workers never stage.
  public var discoverDirty: URL { URL(filePath: "") }
  public var baselineDirectory: URL { URL(filePath: "") }
  /// Known failures at the base tree `tree`.
  public func baseline(tree: String) -> URL { URL(filePath: "") }
  public var warmupDirectory: URL { URL(filePath: "") }
  /// Warm test times and cold cost at the base tree `tree`.
  public func warmup(tree: String) -> URL { URL(filePath: "") }
  public var plansDirectory: URL { URL(filePath: "") }
  /// `PLAN.md`, a copy of an untracked spec, the ledger, the lock and the report.
  public func plan(slug: String) -> URL { URL(filePath: "") }
  /// `<git-dir>/swift-harness/`: what `.harness/` holds in an owned repository.
  public var worktreeRoot: URL { URL(filePath: "") }
  /// Scratch worktrees for prove, the baseline and generators.
  public var scratchDirectory: URL { URL(filePath: "") }
}
