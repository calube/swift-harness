import Foundation
import SwiftGateDomain

/// Reads the ``GateReuse/Inputs`` of a brownfield tier about to run in a checkout: its clean
/// tree, the merge base it measures from, the running binary, and the clone's state files the
/// tier reads for that merge base.
public struct BrownfieldGateReuseReader: Sendable {
  public let layout: BrownfieldStateLayout
  public let git: any Git
  public let workingTree: any WorkingTreeReading
  /// `git rev-parse <commit>^{tree}`.
  public let tree: @Sendable (_ commit: String) async throws -> String
  /// `nil` when no shim named the binary, so no run can be matched to it.
  public let sourceHash: String?

  public init(
    layout: BrownfieldStateLayout, git: any Git, workingTree: any WorkingTreeReading,
    tree: @escaping @Sendable (_ commit: String) async throws -> String, sourceHash: String?
  ) {
    self.layout = layout
    self.git = git
    self.workingTree = workingTree
    self.tree = tree
    self.sourceHash = sourceHash
  }

  /// The checkout at `root` read through `runner`; `nil` outside a git checkout.
  public static func live(root: URL, runner: any ProcessRunner, sourceHash: String?) async
    -> BrownfieldGateReuseReader?
  {
    guard let layout = try? await GitTrackedTree(runner: runner, directory: root).stateLayout()
    else { return nil }
    let tree: @Sendable (String) async throws -> String = { commit in
      let output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: ["rev-parse", "--verify", "\(commit)^{tree}"],
          workingDirectory: root.path, timeout: .seconds(60)))
      let hash = output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard output.status.isSuccess, !hash.isEmpty else {
        throw GitError.commandFailed(
          arguments: ["rev-parse", "--verify", "\(commit)^{tree}"], status: output.status,
          stderr: output.stderr.text)
      }
      return hash
    }
    return BrownfieldGateReuseReader(
      layout: layout, git: LiveGit(runner: runner, repositoryRoot: root.path),
      workingTree: LiveWorkingTree(runner: runner, root: root), tree: tree,
      sourceHash: sourceHash)
  }

  /// The inputs `tier` would run on with `--base base`, or `nil` when any of them is unknown: a
  /// dirty tree, no merge base, no binary hash, or a state file that can't be read.
  public func inputs(tier: CheckTier, base: String) async -> GateReuse.Inputs? {
    nil
  }
}
