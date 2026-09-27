import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

/// The session-start sweep over a real repository with real `git worktree` registrations.
@Suite("scratch worktree sweep")
struct ScratchWorktreeSweepTests {
  private static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path, "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Test",
    "GIT_AUTHOR_EMAIL": "test@example.com", "GIT_COMMITTER_NAME": "Test",
    "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  private static func git(_ arguments: String..., in directory: URL) async throws -> String {
    let output = try await LiveProcessRunner(baseEnvironment: environment).run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: directory.path,
        timeout: .seconds(60)))
    guard output.status.isSuccess else {
      throw SweepTestFailure(detail: "git \(arguments): \(output.stderr.text)")
    }
    return output.stdout.text
  }

  /// The id of a process that has run and been reaped, so nothing owns it any more.
  private static func deadProcessID() throws -> Int32 {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    return process.processIdentifier
  }

  @Test(
    "session start removes and unregisters every prove scratch worktree whose owner died, whatever checkout made it and even half deleted, and keeps a live one — catches a killed ready run's worktree and its profile data left registered with git forever"
  )
  func sessionStartSweepsDeadScratchWorktrees() async throws {
    let temporary = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-sweep-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let base = temporary.resolvingSymlinksInPath()
    let root = base.appending(path: "app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try await Self.git("init", "-q", "-b", "main", in: root)
    try Data("a\n".utf8).write(to: root.appending(path: "a.txt"))
    _ = try await Self.git("add", "-A", in: root)
    _ = try await Self.git("-c", "commit.gpgsign=false", "commit", "-q", "-m", "base", in: root)

    let dead = try Self.deadProcessID()
    let orphans = [
      base.appending(path: ".app-swiftgate-prove-\(dead)-1a2b"),
      // Made from a linked worktree of the same repository that has since been removed.
      base.appending(path: ".app-feature-swiftgate-prove-\(dead)-3c4d"),
      // Half deleted, so `git worktree remove` refuses it.
      base.appending(path: ".app-swiftgate-prove-\(dead)-7a8b"),
    ]
    let live = base.appending(
      path: ".app-swiftgate-prove-\(ProcessInfo.processInfo.processIdentifier)-5e6f")
    for tree in orphans + [live] {
      _ = try await Self.git("worktree", "add", "--detach", "--quiet", tree.path, in: root)
    }
    defer { _ = try? FileManager.default.removeItem(at: live) }
    for tree in orphans {
      try Data("profile".utf8).write(to: tree.appending(path: "default.profraw"))
    }
    try FileManager.default.removeItem(at: orphans[2].appending(path: ".git"))

    let note = await HookDependencies.live(root: root, environment: [:]).sweep.sweep()

    #expect(note?.contains("Removed 3 scratch worktree") == true, "\(String(describing: note))")
    let registered = try await Self.git("worktree", "list", "--porcelain", in: root)
    for tree in orphans {
      #expect(!FileManager.default.fileExists(atPath: tree.path))
      #expect(!registered.contains(tree.path))
    }
    #expect(FileManager.default.fileExists(atPath: live.path))
    #expect(registered.contains(live.path))
  }
}

private struct SweepTestFailure: Error {
  let detail: String
}
