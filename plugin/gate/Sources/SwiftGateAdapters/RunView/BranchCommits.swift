import Foundation

/// Which commits a local branch alone reaches, so a gate run's head commit names the checkout
/// that ran it.
public protocol BranchCommitReading: Sendable {
  /// The full shas `branches`, 1 task's branch and its fixer's, reach that no other local branch
  /// does; empty when none of them exists, `nil` when git can't say.
  func exclusiveCommits(of branches: [String]) -> Set<String>?
}

/// ``BranchCommitReading`` over `git rev-list` in a git common dir.
public struct LiveBranchCommits: BranchCommitReading {
  /// The git common dir, absolute.
  public let commonDirectory: URL
  private let runner: LiveProcessRunner

  public init(commonDirectory: URL, runner: LiveProcessRunner = LiveProcessRunner()) {
    self.commonDirectory = commonDirectory
    self.runner = runner
  }

  public func exclusiveCommits(of branches: [String]) -> Set<String>? {
    guard !branches.isEmpty, branches.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else {
      return nil
    }
    let invocation = ProcessInvocation(
      executable: "git",
      arguments: ["--git-dir=\(commonDirectory.path)", "rev-list", "--ignore-missing"]
        + branches.map { "refs/heads/\($0)" } + ["--not"] + branches.map { "--exclude=\($0)" }
        + ["--branches"],
      timeout: .seconds(30))
    guard case .success(let output) = runner.runBlocking(invocation), output.status.isSuccess
    else { return nil }
    return Set(output.stdout.text.split(separator: "\n").map(String.init))
  }
}
