import Foundation
import SwiftGateAdapters
import Testing

@Suite("git top level without git")
struct GitTopLevelTests {
  @Test(
    "a nested directory resolves to the ancestor holding .git — catches the cwd taken as the top")
  func nested() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-toplevel-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appending(path: "repo", directoryHint: .isDirectory)
    let worktree = root.appending(path: "worktree", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: repo.appending(path: ".git/objects"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: repo.appending(path: "Sources/App"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try Data("gitdir: elsewhere\n".utf8).write(to: worktree.appending(path: ".git"))

    let repoPath = repo.path(percentEncoded: false)
    let expected = String(repoPath.dropLast())
    #expect(
      GitTopLevel().of(repo.appending(path: "Sources/App").path(percentEncoded: false)) == expected)
    #expect(GitTopLevel().of(expected) == expected)
    #expect(
      GitTopLevel().of(worktree.path(percentEncoded: false))
        == String(worktree.path(percentEncoded: false).dropLast()))
    #expect(GitTopLevel().of(root.path(percentEncoded: false)) == nil)
    #expect(GitTopLevel().of("Sources") == nil)
  }
}

@Suite("git worktree roots without git")
struct GitWorktreeRootsTests {
  @Test(
    "a top level under /private keeps that spelling — catches the transcript's realpath cwd losing every path"
  )
  func privatePrefixKept() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("Sources/App/A.swift", "a\n")
    let real = CanonicalPath.of(repo.root)
    #expect(GitTopLevel().of(real) == real)
    #expect(GitTopLevel().of("\(real)/Sources/App") == real)
  }

  @Test(
    "the main checkout and a linked worktree list each other — catches a worker's worktree missing from the roots"
  )
  func linkedWorktreesListed() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("A.swift", "a\n")
    _ = try await repo.commitAll("base")
    let linked = repo.root.deletingLastPathComponent()
      .appending(path: "\(repo.root.lastPathComponent)-linked", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: linked) }
    try await repo.git("worktree", "add", "-q", "-b", "task", linked.path)
    let main = CanonicalPath.of(repo.root)
    let task = CanonicalPath.of(linked)

    #expect(GitTopLevel().worktrees(of: main) == [main, task])
    #expect(GitTopLevel().worktrees(of: "\(task)/Sources") == [main, task])
    #expect(GitTopLevel().worktrees(of: repo.root.deletingLastPathComponent().path) == [])
  }
}
