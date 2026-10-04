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
