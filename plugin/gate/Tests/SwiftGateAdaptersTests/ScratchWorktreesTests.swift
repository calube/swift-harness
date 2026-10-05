import Foundation
import SwiftGateAdapters
import SwiftGateTestSupport
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
      try repository.write("app/Sources/Lib/Stable.swift", "stable\n")
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
      TestTemporaryDirectory.remove(temporary)
    }
  }

  private func read(_ root: URL, _ path: String) -> String? {
    try? String(contentsOf: root.appending(path: path), encoding: .utf8)
  }

  private static let past = Date(timeIntervalSince1970: 1_000_000_000)

  private func modified(_ root: URL, _ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: root.appending(path: path).path))?[
      .modificationDate] as? Date
  }

  private func keeping(_ scratch: Scratch) -> LiveScratchWorktrees {
    LiveScratchWorktrees(
      runner: scratch.repository.runner, repositoryRoot: scratch.repository.root.path,
      directory: scratch.temporary, keepsTree: true)
  }

  private func proveRequest(_ scratch: Scratch) -> ScratchTreeRequest {
    ScratchTreeRequest(
      revision: "HEAD", revertTo: scratch.base,
      copiedPaths: ["app/Tests/LibTests/T.swift", "app/Tests/LibTests/U.swift"],
      revertedPaths: ["app/Sources/Lib/Lib.swift", "app/Sources/Lib/New.swift"])
  }

  private static let provePaths = [
    "app/Sources/Lib/Lib.swift", "app/Sources/Lib/New.swift", "app/Tests/LibTests/T.swift",
    "app/Tests/LibTests/U.swift",
  ]

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
    "a source moved since the merge base is reverted to its old content at its new path, not deleted — catches prove emptying every module of a package that moved directory"
  )
  func revertsMovedSourcesInPlace() async throws {
    let repository = try await TemporaryGitRepository()
    let temporary = repository.root.appending(path: "../scratch-\(UUID().uuidString)")
      .standardizedFileURL
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer {
      repository.remove()
      try? FileManager.default.removeItem(at: temporary)
    }
    let lines = (1...20).map { "let line\($0) = \($0)\n" }.joined()
    try repository.write("app/Sources/Lib/Lib.swift", lines)
    try repository.write("app/Sources/Lib/Other.swift", "enum Other {}\n" + lines)
    let base = try await repository.commitAll("base")
    try repository.delete("app")
    try repository.write("plugin/app/Sources/Lib/Lib.swift", lines + "let added = 21\n")
    try repository.write("plugin/app/Sources/Lib/Other.swift", "enum Other {}\n" + lines)
    try repository.write("plugin/app/Sources/Lib/New.swift", "enum New {}\n")
    _ = try await repository.commitAll("move")
    let adapter = LiveScratchWorktrees(
      runner: repository.runner, repositoryRoot: repository.root.path, directory: temporary)

    let contents = try await adapter.withScratchTree(
      ScratchTreeRequest(
        revision: "HEAD", revertTo: base,
        copiedPaths: ["app/Sources/Lib/Lib.swift", "app/Sources/Lib/Other.swift"],
        revertedPaths: [
          "plugin/app/Sources/Lib/Lib.swift", "plugin/app/Sources/Lib/New.swift",
          "plugin/app/Sources/Lib/Other.swift",
        ])
    ) { root in
      [
        read(root, "plugin/app/Sources/Lib/Lib.swift"),
        read(root, "plugin/app/Sources/Lib/Other.swift"),
        read(root, "plugin/app/Sources/Lib/New.swift"), read(root, "app/Sources/Lib/Lib.swift"),
      ]
    }

    #expect(contents == [lines, "enum Other {}\n" + lines, nil, nil])
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
    "a seeded package's .build is cloned into the tree without its module cache — catches workers building cold, or a seed whose absolute-path module cache fails every build"
  )
  func seedsBuildDirectories() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let debug = "app/.build/arm64-apple-macosx/debug"
    try scratch.repository.write("\(debug)/Lib.build/Lib.swift.o", "object\n")
    try scratch.repository.write("\(debug)/ModuleCache/ABC/Foundation.pcm", "pcm\n")

    let contents = try await scratch.adapter.withScratchTree(
      ScratchTreeRequest(
        revision: "HEAD", revertTo: "HEAD", copiedPaths: [], revertedPaths: [],
        seededBuildDirectories: ["app", "unbuilt"])
    ) { root in
      (
        read(root, "\(debug)/Lib.build/Lib.swift.o"),
        FileManager.default.fileExists(atPath: root.appending(path: "\(debug)/ModuleCache").path),
        FileManager.default.fileExists(atPath: root.appending(path: "unbuilt/.build").path)
      )
    }

    #expect(contents.0 == "object\n")
    #expect(contents.1 == false)
    #expect(contents.2 == false)
    // The seed is a copy: the user's own build directory keeps its module cache.
    #expect(read(scratch.repository.root, "\(debug)/ModuleCache/ABC/Foundation.pcm") == "pcm\n")
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

  @Test(
    "a kept tree is used again at the same path, and a file the next use doesn't change keeps its timestamp — catches prove building cold in a fresh path at every gate"
  )
  func keptTreeKeepsUnchangedFiles() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let adapter = keeping(scratch)

    let first = try await adapter.withScratchTree(proveRequest(scratch)) { root in
      try? FileManager.default.setAttributes(
        [.modificationDate: Self.past],
        ofItemAtPath: root.appending(path: "app/Sources/Lib/Stable.swift").path)
      return root
    }
    let (second, contents, stamp) = try await adapter.withScratchTree(proveRequest(scratch)) {
      root in
      (root, Self.provePaths.map { read(root, $0) }, modified(root, "app/Sources/Lib/Stable.swift"))
    }

    #expect(second == first)
    #expect(contents == ["v1\n", nil, "t3\n", "u\n"])
    #expect(stamp == Self.past)
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(read(scratch.repository.root, "app/Sources/Lib/Lib.swift") == "v2\n")
  }

  @Test(
    "a kept tree takes each request as it comes, not what the last use left: a later commit, no copied test, nothing reverted — catches prove running a stale tree that hides a failing test"
  )
  func keptTreeTakesEachRequest() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let adapter = keeping(scratch)
    let first = try await adapter.withScratchTree(proveRequest(scratch)) { $0 }
    try scratch.repository.write("app/Sources/Lib/Lib.swift", "v3\n")
    try await scratch.repository.git("add", "app/Sources/Lib/Lib.swift")
    try await scratch.repository.git("commit", "-q", "-m", "later")

    let (second, contents) = try await adapter.withScratchTree(
      ScratchTreeRequest(revision: "HEAD", revertTo: "HEAD", copiedPaths: [], revertedPaths: [])
    ) { root in (root, Self.provePaths.map { read(root, $0) }) }

    #expect(second == first)
    #expect(contents == ["v3\n", "new\n", "t2\n", nil])
  }

  @Test(
    "a use while the kept tree is held gets a throwaway tree of its own, removed afterwards — catches 2 gates in 1 checkout building in 1 tree at once"
  )
  func heldKeptTreeFallsBack() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let adapter = keeping(scratch)

    let (outer, inner, contents) = try await adapter.withScratchTree(proveRequest(scratch)) {
      outer in
      let inner = try? await adapter.withScratchTree(proveRequest(scratch)) { inner in
        (inner, Self.provePaths.map { read(inner, $0) })
      }
      return (outer, inner?.0, inner?.1)
    }

    let innerRoot = try #require(inner)
    #expect(innerRoot != outer)
    #expect(contents == ["v1\n", nil, "t3\n", "u\n"])
    #expect(!FileManager.default.fileExists(atPath: innerRoot.path))
    #expect(FileManager.default.fileExists(atPath: outer.path))
  }

  @Test(
    "a kept tree whose checkout is broken is made again — catches every later prove blocked by 1 killed one"
  )
  func brokenKeptTreeIsRemade() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let adapter = keeping(scratch)
    let first = try await adapter.withScratchTree(proveRequest(scratch)) { $0 }
    let checkout = first.appending(path: ".git")
    try #require(FileManager.default.fileExists(atPath: checkout.path), "the first use keeps its tree")
    try FileManager.default.removeItem(at: checkout)

    let (second, contents) = try await adapter.withScratchTree(proveRequest(scratch)) { root in
      (root, Self.provePaths.map { read(root, $0) })
    }

    #expect(second == first)
    #expect(contents == ["v1\n", nil, "t3\n", "u\n"])
  }

  @Test(
    "the orphan sweeps leave the kept tree alone — catches each gate deleting the tree the next one would build in"
  )
  func sweepsKeepTheKeptTree() async throws {
    let scratch = try await Scratch.make()
    defer { scratch.remove() }
    let kept = try await keeping(scratch).withScratchTree(proveRequest(scratch)) { $0 }

    _ = try await scratch.adapter.withScratchTree(proveRequest(scratch)) { _ in 0 }
    let sweep = try await scratch.adapter.sweepRegisteredOrphans()

    #expect(sweep.removed.isEmpty)
    #expect(read(kept, "app/Sources/Lib/Stable.swift") == "stable\n")
  }
}
