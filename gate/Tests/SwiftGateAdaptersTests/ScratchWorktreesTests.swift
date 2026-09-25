import Foundation
import SwiftGateAdapters
import Testing

@Suite("LiveScratchWorktrees")
struct ScratchWorktreesTests {
  private struct Scratch {
    let repository: TemporaryGitRepository
    let temporary: URL
    let base: String

    var adapter: LiveScratchWorktrees {
      LiveScratchWorktrees(
        runner: repository.runner, repositoryRoot: repository.root.path,
        directory: temporary)
    }

    static func make() async throws -> Scratch {
      let repository = try await TemporaryGitRepository()
      let temporary = repository.root.appending(path: "../scratch-\(UUID().uuidString)")
        .standardizedFileURL
      try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
      try repository.write("app/Sources/Lib/Lib.swift", "v1\n")
      try repository.write("app/Tests/LibTests/T.swift", "t1\n")
      let base = try await repository.commitAll("base")
      try repository.write("app/Sources/Lib/Lib.swift", "v2\n")
      try repository.write("app/Sources/Lib/New.swift", "new\n")
      try repository.write("app/Tests/LibTests/T.swift", "t2\n")
      _ = try await repository.commitAll("change")
      // Uncommitted and untracked work must reach the scratch tree too.
      try repository.write("app/Tests/LibTests/T.swift", "t3\n")
      try repository.write("app/Tests/LibTests/U.swift", "u\n")
      return Scratch(repository: repository, temporary: temporary, base: base)
    }

    func remove() {
      repository.remove()
      try? FileManager.default.removeItem(at: temporary)
    }
  }

  private func read(_ root: URL, _ path: String) -> String? {
    try? String(contentsOf: root.appending(path: path), encoding: .utf8)
  }

  @Test(
    "the scratch tree has the working tree's tests and the merge base's sources, and is removed afterwards — catches prove running against the unreverted change or leaking worktrees"
  )
  func revertsSourcesKeepsTests() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }

    let (root, contents) = try await scratch.adapter.withScratchTree(
      ScratchTreeRequest(
        revision: "HEAD", revertTo: scratch.base,
        copiedPaths: ["app/Tests/LibTests/T.swift", "app/Tests/LibTests/U.swift"],
        revertedPaths: ["app/Sources/Lib/Lib.swift", "app/Sources/Lib/New.swift"])
    ) { root in
      (
        root,
        [
          read(root, "app/Sources/Lib/Lib.swift"), read(root, "app/Sources/Lib/New.swift"),
          read(root, "app/Tests/LibTests/T.swift"), read(root, "app/Tests/LibTests/U.swift"),
        ]
      )
    }

    #expect(contents == ["v1\n", nil, "t3\n", "u\n"])
    #expect(root.path.hasPrefix(scratch.temporary.path))
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let worktrees = try await scratch.repository.git("worktree", "list", "--porcelain")
    #expect(worktrees.components(separatedBy: "worktree ").count == 2)
    // The user's own worktree is untouched.
    #expect(read(scratch.repository.root, "app/Sources/Lib/Lib.swift") == "v2\n")
  }

  @Test(
    "by default the scratch tree is a hidden sibling of the repository — catches trees made under the symlinked temp dir, whose paths the build tools report differently"
  )
  func besideRepository() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let adapter = LiveScratchWorktrees(
      runner: scratch.repository.runner, repositoryRoot: scratch.repository.root.path)

    let root = try await adapter.withScratchTree(
      ScratchTreeRequest(
        revision: "HEAD", revertTo: scratch.base, copiedPaths: [], revertedPaths: [])
    ) { $0 }

    // git reports the toplevel physically (`/private/var/…`); compare resolved forms.
    #expect(
      root.deletingLastPathComponent().resolvingSymlinksInPath()
        == scratch.repository.root.deletingLastPathComponent().resolvingSymlinksInPath())
    #expect(
      root.lastPathComponent.hasPrefix(
        ".\(scratch.repository.root.lastPathComponent)-swiftgate-prove-"))
  }

  @Test(
    "an unknown revision fails as a git error and leaves no directory behind — catches a half-made scratch tree left on disk"
  )
  func unknownRevision() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }

    await #expect(throws: ScratchWorktreeError.self) {
      try await scratch.adapter.withScratchTree(
        ScratchTreeRequest(
          revision: "HEAD", revertTo: "no-such-ref", copiedPaths: [],
          revertedPaths: ["app/Sources/Lib/Lib.swift"])
      ) { _ in 0 }
    }
    let left = try FileManager.default.contentsOfDirectory(atPath: scratch.temporary.path)
    #expect(left.isEmpty)
  }

  @Test(
    "scratch trees of dead processes are swept on the next use — catches worktrees piling up after a killed prove"
  )
  func sweepsOrphans() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let name = ".\(scratch.repository.root.lastPathComponent)-swiftgate-prove-"
    let orphan = scratch.temporary.appending(path: "\(name)2147483646-dead")
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    let live = scratch.temporary.appending(
      path: "\(name)\(ProcessInfo.processInfo.processIdentifier)-alive")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)

    _ = try await scratch.adapter.withScratchTree(
      ScratchTreeRequest(
        revision: "HEAD", revertTo: scratch.base, copiedPaths: [], revertedPaths: [])
    ) { _ in 0 }

    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(FileManager.default.fileExists(atPath: live.path))
  }
}
