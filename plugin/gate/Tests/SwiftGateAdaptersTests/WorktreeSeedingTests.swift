import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("LiveGitWorkspace")
struct WorktreeSeedingTests {
  /// A repository whose package `Pkg` is committed and whose `.build` and DerivedData, both
  /// ignored, hold a compiled object beside a module cache.
  private static func warmRepository() async throws -> TemporaryGitRepository {
    let repo = try await TemporaryGitRepository()
    try repo.write(".gitignore", ".build/\n.harness/\n")
    try repo.write("Pkg/Package.swift", "// swift-tools-version: 6.0\n")
    _ = try await repo.commitAll("package")
    try repo.write("Pkg/.build/arm64-apple-macosx/debug/Pkg.build/Pkg.swift.o", "object")
    try repo.write("Pkg/.build/arm64-apple-macosx/debug/ModuleCache/Swift-1.pcm", "stale")
    try repo.write(".harness/derived-data/Build/Products/App.o", "object")
    try repo.write(".harness/derived-data/ModuleCache.noindex/Foundation.pcm", "stale")
    return repo
  }

  private static func subpaths(of url: URL) -> [String] {
    (FileManager.default.subpaths(atPath: url.path) ?? []).sorted()
  }

  @Test(
    "a new worktree on its own branch gets the package build and DerivedData cloned without any module cache — catches a clone whose module cache fails every build on the old path"
  )
  func clonesWarmBuildWithoutModuleCache() async throws {
    let repo = try await Self.warmRepository()
    let worktree = URL(filePath: repo.root.path + "-plan-task", directoryHint: .isDirectory)
    defer {
      repo.remove()
      try? FileManager.default.removeItem(at: worktree)
    }
    let workspace = LiveGitWorkspace(runner: repo.runner, repositoryRoot: repo.root.path)

    try await workspace.addWorktree(at: worktree.path, branch: "plan/task", from: "main")
    let cloned = try await workspace.cloneWarmBuild(
      ["Pkg/.build", ".harness/derived-data", "Missing/.build"], from: repo.root.path,
      into: worktree.path)

    #expect(cloned == ["Pkg/.build", ".harness/derived-data"])
    #expect(
      Self.subpaths(of: worktree.appending(path: "Pkg/.build")) == [
        "arm64-apple-macosx", "arm64-apple-macosx/debug", "arm64-apple-macosx/debug/Pkg.build",
        "arm64-apple-macosx/debug/Pkg.build/Pkg.swift.o",
      ])
    #expect(
      Self.subpaths(of: worktree.appending(path: ".harness/derived-data")) == [
        "Build", "Build/Products", "Build/Products/App.o",
      ])
    #expect(
      FileManager.default.fileExists(
        atPath: repo.root.appending(path: "Pkg/.build/arm64-apple-macosx/debug/ModuleCache").path),
      "the source's own module cache must stay")
    let head = try await repo.runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
        workingDirectory: worktree.path, timeout: .seconds(30)))
    #expect(head.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines) == "plan/task")
    #expect(try await workspace.branchExists("plan/task"))
    #expect(try await workspace.branchExists("plan/other") == false)
  }

  @Test(
    "a branch counts as merged only once main contains its commits, and a merged one's worktree and branch are removed — catches deleting unmerged work"
  )
  func mergedBranchIsRemoved() async throws {
    let repo = try await TemporaryGitRepository()
    try repo.write("README", "one\n")
    _ = try await repo.commitAll("one")
    let worktree = URL(filePath: repo.root.path + "-plan-task", directoryHint: .isDirectory)
    defer {
      repo.remove()
      try? FileManager.default.removeItem(at: worktree)
    }
    let workspace = LiveGitWorkspace(runner: repo.runner, repositoryRoot: repo.root.path)
    try await workspace.addWorktree(at: worktree.path, branch: "plan/task", from: "main")
    try Data("two\n".utf8).write(to: worktree.appending(path: "README"))
    let commit = try await repo.runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["commit", "-q", "-am", "two"],
        workingDirectory: worktree.path, timeout: .seconds(30)))
    #expect(commit.status.isSuccess, "\(commit.stderr.text)")

    #expect(try await workspace.isMerged("plan/task", into: "main") == false)
    try await repo.git("merge", "-q", "--no-ff", "-m", "merge", "plan/task")
    #expect(try await workspace.isMerged("plan/task", into: "main"))

    try await workspace.removeWorktree(at: worktree.path, force: false)
    try await workspace.deleteBranch("plan/task")
    #expect(!FileManager.default.fileExists(atPath: worktree.path))
    #expect(try await workspace.branchExists("plan/task") == false)
  }

  @Test(
    "the clone and the module-cache sweep run /bin/cp -c and /usr/bin/find by absolute path — catches a PATH wrapper that drops the clone flag"
  )
  func toolsByAbsolutePath() async throws {
    let source = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-seed-\(UUID().uuidString)", directoryHint: .isDirectory)
    let destination = source.appending(path: "worktree", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: source) }
    try FileManager.default.createDirectory(
      at: source.appending(path: "Pkg/.build"), withIntermediateDirectories: true)
    let runner = FakeProcessRunner { _ in ProcessOutput(status: .exited(0)) }
    let workspace = LiveGitWorkspace(runner: runner, repositoryRoot: source.path)

    _ = try await workspace.cloneWarmBuild(
      ["Pkg/.build"], from: source.path, into: destination.path)

    let invocations = runner.invocations
    #expect(invocations.map(\.executable) == ["/bin/cp", "/usr/bin/find"])
    #expect(invocations.first?.arguments.prefix(2) == ["-c", "-R"])
    #expect(invocations.last?.arguments.contains("/bin/rm") == true)
  }

  @Test(
    "a failed clone is an error naming the destination, not a silent cold start — catches a worktree reported warm that isn't"
  )
  func failedCloneThrows() async throws {
    let source = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-seed-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: source) }
    try FileManager.default.createDirectory(
      at: source.appending(path: "Pkg/.build"), withIntermediateDirectories: true)
    let runner = FakeProcessRunner { _ in
      ProcessOutput(status: .exited(1), stderr: "clonefile failed")
    }
    let workspace = LiveGitWorkspace(runner: runner, repositoryRoot: source.path)

    await #expect {
      _ = try await workspace.cloneWarmBuild(
        ["Pkg/.build"], from: source.path, into: source.appending(path: "worktree").path)
    } throws: { error in
      guard case .clone(let path, let detail) = error as? GitWorkspaceError else { return false }
      return path.hasSuffix("worktree/Pkg/.build") && detail.contains("clonefile failed")
    }
  }

  @Test(
    "the task worktree sits beside the main checkout as <repo>-<plan>-<task> on <plan>/<task> — catches a worktree named after a linked checkout"
  )
  func taskWorktreeNaming() throws {
    let names = try TaskWorktree(
      commonDirectory: "/work/swift-harness/.git", plan: "2026-09-26-build", task: "cli")
    #expect(names.mainCheckout == "/work/swift-harness")
    #expect(names.path == "/work/swift-harness-2026-09-26-build-cli")
    #expect(names.branch == "2026-09-26-build/cli")
    #expect(throws: GitWorkspaceError.self) {
      try TaskWorktree(commonDirectory: "/work/bare.git", plan: "p", task: "t")
    }
  }

  @Test(
    "a brownfield task worktree sits in its plan's directory under the git common dir, cut from and merged into the plan branch in the plan's checkout, while the owned layout keeps main — catches a brownfield run that writes beside the user's checkout or merges into their branch"
  )
  func brownfieldTaskWorktreeNaming() throws {
    let common = "/work/clone/.git"
    let names = try TaskWorktree(
      commonDirectory: common, plan: "2026-10-04-search", task: "cli", profile: .brownfield)
    let owned = try TaskWorktree(commonDirectory: common, plan: "2026-10-04-search", task: "cli")

    #expect(names.path == "/work/clone/.git/swift-harness/plans/2026-10-04-search/worktrees/cli")
    #expect(names.mainCheckout == "/work/clone/.git/swift-harness/plans/2026-10-04-search/checkout")
    #expect(names.baseBranch == "swift-harness/2026-10-04-search")
    #expect(names.branch == "2026-10-04-search/cli")
    #expect(names.commonDirectory == common)
    #expect(owned.path == "/work/clone-2026-10-04-search-cli")
    #expect(owned.mainCheckout == "/work/clone")
    #expect(owned.baseBranch == "main")
    #expect(throws: GitWorkspaceError.self) {
      try TaskWorktree(commonDirectory: common, plan: "a/b", task: "t", profile: .brownfield)
    }
  }

  @Test(
    "the warm-build survey lists present and missing package builds and the DerivedData — catches a survey reporting a build that isn't there"
  )
  func survey() async throws {
    let repo = try await Self.warmRepository()
    defer { repo.remove() }

    let survey = WarmBuild.survey(packageDirectories: ["Pkg", "Other"], in: repo.root.path)

    #expect(survey.packageBuilds == ["Pkg/.build"])
    #expect(survey.missingPackageBuilds == ["Other/.build"])
    #expect(survey.derivedData == ".harness/derived-data")
    #expect(survey.clonable == ["Pkg/.build", ".harness/derived-data"])
  }
}
