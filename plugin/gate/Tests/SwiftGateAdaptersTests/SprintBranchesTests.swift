import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@Suite("LiveSprintBranches")
struct SprintBranchesTests {
  private static func branches(_ repo: TemporaryGitRepository) -> LiveSprintBranches {
    LiveSprintBranches(runner: repo.runner, repositoryRoot: repo.root.path)
  }

  @Test(
    "fast-forward moves the branch only to a descendant and returns false moving nothing otherwise — catches main moving to a commit that drops its history"
  )
  func fastForwardOnlyToDescendant() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("a.txt", "a\n")
    let base = try await repo.commitAll("base")
    try await repo.git("switch", "-q", "-c", "work")
    try repo.write("b.txt", "b\n")
    let ahead = try await repo.commitAll("ahead")
    let unrelated = try await repo.git("commit-tree", "\(ahead)^{tree}", "-m", "unrelated")
    try await repo.git("switch", "-q", "--detach")
    let branches = Self.branches(repo)

    let refused = try await branches.fastForward("main", from: base, to: unrelated)
    let mainAfterRefusal = try await repo.git("rev-parse", "main")
    let moved = try await branches.fastForward("main", from: base, to: ahead)

    #expect(refused == false)
    #expect(mainAfterRefusal == base)
    #expect(moved == true)
    #expect(try await repo.git("rev-parse", "main") == ahead)
  }

  @Test(
    "fast-forward throws and moves nothing when the branch is no longer at the expected commit — catches a race overwriting a commit that landed on main"
  )
  func fastForwardComparesAndSwaps() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("a.txt", "a\n")
    let base = try await repo.commitAll("base")
    try repo.write("b.txt", "b\n")
    let landed = try await repo.commitAll("landed on main")
    try repo.write("c.txt", "c\n")
    let ahead = try await repo.commitAll("ahead")
    try await repo.git("update-ref", "refs/heads/main", landed)
    try await repo.git("switch", "-q", "--detach", ahead)

    await #expect(throws: GitWorkspaceError.self) {
      _ = try await Self.branches(repo).fastForward("main", from: base, to: ahead)
    }
    #expect(try await repo.git("rev-parse", "main") == landed)
  }

  @Test(
    "createBranch makes the branch at the commit and refuses an existing one; deleteBranch removes it only at that commit — catches a sprint branch clobbered or rolled back after it moved"
  )
  func createAndGuardedDelete() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("a.txt", "a\n")
    let base = try await repo.commitAll("base")
    try repo.write("b.txt", "b\n")
    let next = try await repo.commitAll("next")
    let branches = Self.branches(repo)

    try await branches.createBranch("sprint/one", at: base)
    let created = try await repo.git("rev-parse", "refs/heads/sprint/one")
    await #expect(throws: GitWorkspaceError.self) {
      try await branches.createBranch("sprint/one", at: next)
    }
    await #expect(throws: GitWorkspaceError.self) {
      try await branches.deleteBranch("sprint/one", at: next)
    }
    let kept = try await repo.git("branch", "--list", "sprint/one")
    try await branches.deleteBranch("sprint/one", at: base)

    #expect(created == base)
    #expect(!kept.isEmpty)
    #expect(try await repo.git("branch", "--list", "sprint/one").isEmpty)
  }

  @Test(
    "currentBranch names the checked-out branch and nil when detached, and checkedOutBranches lists every worktree's — catches a sprint command acting from the wrong branch"
  )
  func readsCheckedOutBranches() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("a.txt", "a\n")
    _ = try await repo.commitAll("base")
    try await repo.git("switch", "-q", "-c", "sprint/one")
    let other = repo.root.deletingLastPathComponent()
      .appending(path: "swiftgate-git-other-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: other) }
    try await repo.git("worktree", "add", "-q", other.path, "main")
    let branches = Self.branches(repo)

    let onBranch = try await branches.currentBranch()
    let checkedOut = try await branches.checkedOutBranches()
    try await repo.git("switch", "-q", "--detach")
    let detached = try await branches.currentBranch()

    #expect(onBranch == "sprint/one")
    #expect(Set(checkedOut) == ["sprint/one", "main"])
    #expect(detached == nil)
  }
}
