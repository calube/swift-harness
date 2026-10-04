import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("brownfield check root")
struct BrownfieldCheckRootTests {
  @Test(
    "a brownfield tier started in a subdirectory gates from the worktree's toplevel — catches area roots read against the subdirectory, as web/web was"
  )
  func subdirectoryResolvesToToplevel() async throws {
    let base = TestTemporaryDirectory.root.appending(
      path: "brownfield-root-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: base) }
    let repository = base.appending(path: "clone", directoryHint: .isDirectory)
    let web = repository.appending(path: "web/src", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
    let runner = LiveProcessRunner()
    let initialized = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["init", "-q"], workingDirectory: repository.path,
        timeout: .seconds(30)))
    try #require(initialized.status.isSuccess)

    for directory in [web, web.deletingLastPathComponent(), repository] {
      let root = try await BrownfieldCheck.repositoryRoot(
        from: directory, git: LiveGit(runner: runner, repositoryRoot: directory.path))
      #expect(
        CanonicalPath.of(root) == CanonicalPath.of(repository),
        "from \(directory.path)")
    }
  }

  @Test(
    "the root comes from git's prefix, not the directory's name — catches a resolver that keeps the directory a tier started in"
  )
  func prefixIsStripped() async throws {
    let directory = URL(filePath: "/clone/web/src", directoryHint: .isDirectory)
    let root = try await BrownfieldCheck.repositoryRoot(
      from: directory, git: FakeGit(prefix: "web/src/"))
    #expect(root.path(percentEncoded: false) == "/clone/")
    let top = try await BrownfieldCheck.repositoryRoot(
      from: URL(filePath: "/clone", directoryHint: .isDirectory), git: FakeGit(prefix: ""))
    #expect(top.path(percentEncoded: false) == "/clone/")
  }
}
