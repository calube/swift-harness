import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Brownfield prove: each area's changed tests run through `test_files` in a scratch tree at the
/// task head with the task's non-test changes reverted.
enum BrownfieldProve {
  struct Dependencies: Sendable {
    let git: any Git
    let scratch: any ScratchWorktrees
    let runner: any AreaCommandRunning
    /// A file's text, or `nil` when it can't be read.
    let readFile: @Sendable (URL) -> String?
    /// Per command run.
    let deadline: Duration

    init(
      git: any Git, scratch: any ScratchWorktrees, runner: any AreaCommandRunning,
      readFile: @escaping @Sendable (URL) -> String? = {
        try? String(contentsOf: $0, encoding: .utf8)
      },
      deadline: Duration
    ) {
      self.git = git
      self.scratch = scratch
      self.runner = runner
      self.readFile = readFile
      self.deadline = deadline
    }

    /// Live git and scratch trees under `layout`'s scratch directory, around `runner`.
    static func live(
      root: URL, layout: BrownfieldStateLayout, runner: any AreaCommandRunning, deadline: Duration
    ) -> Dependencies {
      let process = LiveProcessRunner()
      return Dependencies(
        git: LiveGit(runner: process, repositoryRoot: root.path),
        scratch: LiveScratchWorktrees(
          runner: process, repositoryRoot: root.path, directory: layout.scratchDirectory),
        runner: runner, deadline: deadline)
    }
  }

  /// - Parameters:
  ///   - root: the worktree's toplevel.
  ///   - junitDirectory: where `{junit}` paths point.
  static func run(
    root: URL, base: String, config: BrownfieldConfig, junitDirectory: URL,
    dependencies: Dependencies
  ) async -> ChangedTestJudgement {
    .empty
  }
}
