import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A committed brownfield clone holding the memos trials' captured `config.toml` and, under
/// `web/`, a captured pnpm project.
private struct MemosLikeClone {
  let root: URL
  let git: LiveProcessRunner

  init() async throws {
    root = TestTemporaryDirectory.root
      .appending(path: "node-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    let web = root.appending(path: "web", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
    let pnpm = Fixture.directory.appending(path: "NodeInstall/pnpm", directoryHint: .isDirectory)
    for name in try FileManager.default.contentsOfDirectory(atPath: pnpm.path) {
      try Data(contentsOf: pnpm.appending(path: name)).write(to: web.appending(path: name))
    }
    git = LiveProcessRunner(baseEnvironment: [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": root.path,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
      "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
    ])
    for arguments in [
      ["init", "-q", "-b", "main"], ["add", "-A"], ["commit", "-q", "-m", "base"],
    ] {
      let output = try await git.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: root.path,
          timeout: .seconds(60)))
      try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    }
    let state = root.appending(path: ".git/swift-harness", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data(try Fixture.text("BrownfieldTrial/memos-4-config.toml").utf8)
      .write(to: state.appending(path: "config.toml"))
  }

  func remove() { TestTemporaryDirectory.remove(root) }
}

@Suite("the live node installer")
struct NodeDependencyInstallerTests {
  @Test(
    "an install that times out is a failed result naming the timeout, and a cache path the manager can't print records the install cold with a note — catches a hung install crashing or stalling worktree creation, or an unread cache passed off as warm"
  )
  func timeoutAndUnreadCache() async throws {
    let clone = try await MemosLikeClone()
    defer { clone.remove() }
    let installs = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      if invocation.arguments == ["store", "path"] {
        return ProcessOutput(status: .exited(1), stderr: "ERR_PNPM_NO_STORE")
      }
      throw .timedOut(
        executable: "pnpm", after: .seconds(600),
        stdout: CapturedStream(bytes: Data("Progress: resolved 12\n".utf8)),
        stderr: CapturedStream())
    }

    let report = await LiveNodeDependencyInstaller(git: clone.git, installs: installs)
      .install(worktree: clone.root)

    #expect(report.results.map(\.install.directory) == ["web"])
    #expect(report.results.map(\.outcome) == [.failed])
    #expect(report.results.map(\.cache) == [.cold])
    #expect(report.results.first?.detail?.contains("timed out") == true, "\(report.results)")
    #expect(report.results.first?.detail?.contains("Progress: resolved 12") == true)
    #expect(report.notes.contains { $0.contains("pnpm store path") }, "\(report.notes)")
    #expect(report.head != nil)
  }
}
