import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

/// A real repository: a root commit, then a commit that adds, changes and deletes Swift files and
/// edits a doc. Reads go through real git, so a missing parent is git's own answer.
struct SurfaceRepo {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)
  private(set) var rootCommit = ""
  private(set) var head = ""

  var reader: LiveSurfaceCommitReader {
    LiveSurfaceCommitReader(runner: runner, repositoryRoot: root.path)
  }

  init() async throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-surface-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try write("Sources/App/Kept.swift", "func kept() -> Int { 1 }\n")
    try write("Sources/App/Changed.swift", "func changed() -> Int { 1 }\n")
    try write("Sources/App/Deleted.swift", "func deleted() {}\n")
    try write("README.md", "# App\n")
    try await git("add", "-A")
    try await git("commit", "-q", "-m", "base")
    rootCommit = try await git("rev-parse", "HEAD")
    try write("Sources/App/Changed.swift", "func changed() -> Int { 2 }\n")
    try write("Sources/App/Added.swift", "func added() {}\n")
    try FileManager.default.removeItem(at: root.appending(path: "Sources/App/Deleted.swift"))
    try write("README.md", "# App\n\nMore.\n")
    try await git("add", "-A")
    try await git("commit", "-q", "-m", "surface")
    head = try await git("rev-parse", "HEAD")
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func write(_ path: String, _ text: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  @discardableResult
  func git(_ arguments: String..., in directory: URL? = nil) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: (directory ?? root).path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      struct GitFailure: Error { let message: String }
      throw GitFailure(message: "git \(arguments): \(output.stderr.text)")
    }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A depth-1 clone: its HEAD is `head`, whose parent object it doesn't hold.
  func shallowClone() async throws -> URL {
    let clone = root.deletingLastPathComponent()
      .appending(
        path: "swiftgate-surface-shallow-\(UUID().uuidString)", directoryHint: .isDirectory)
    try await git(
      "clone", "-q", "--depth", "1", "file://\(root.path)", clone.path,
      in: root.deletingLastPathComponent())
    return clone
  }
}

@Suite("surface commit reader")
struct SurfaceCommitReaderTests {
  @Test(
    "reads each changed Swift file on both sides of the first parent and lists other paths apart — catches an added, changed or deleted file read from the wrong side"
  )
  func readsBothSides() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }

    let surface = try await repo.reader.read("HEAD")

    #expect(surface.commit == repo.head)
    #expect(surface.parent == repo.rootCommit)
    #expect(
      surface.changes == [
        SurfaceFileChange(
          path: "Sources/App/Added.swift", parentText: nil, commitText: "func added() {}\n"),
        SurfaceFileChange(
          path: "Sources/App/Changed.swift", parentText: "func changed() -> Int { 1 }\n",
          commitText: "func changed() -> Int { 2 }\n"),
        SurfaceFileChange(
          path: "Sources/App/Deleted.swift", parentText: "func deleted() {}\n", commitText: nil),
      ])
    #expect(surface.otherPaths == ["README.md"])
  }

  @Test(
    "the parent's sources are every Swift file in the parent's tree, not the commit's — catches a forward checked against code the commit itself adds"
  )
  func parentSourcesComeFromTheParent() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }

    let surface = try await repo.reader.read(repo.head)
    let sources = try await repo.reader.parentSwiftSources(of: surface)

    #expect(
      sources == [
        "Sources/App/Kept.swift": "func kept() -> Int { 1 }\n",
        "Sources/App/Changed.swift": "func changed() -> Int { 1 }\n",
        "Sources/App/Deleted.swift": "func deleted() {}\n",
      ])
  }

  @Test("a root commit has no parent to load — catches a first commit read as a diff from nothing")
  func rootCommitHasNoParent() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }

    await #expect(throws: SurfaceReadError.parentUnavailable(commit: repo.rootCommit)) {
      try await repo.reader.read(repo.rootCommit)
    }
  }

  @Test(
    "a shallow clone's commit whose parent object is absent can't be read — catches a missing parent read as an empty tree"
  )
  func shallowParentIsUnavailable() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }
    let clone = try await repo.shallowClone()
    defer { try? FileManager.default.removeItem(at: clone) }

    let reader = LiveSurfaceCommitReader(runner: repo.runner, repositoryRoot: clone.path)
    await #expect(throws: SurfaceReadError.parentUnavailable(commit: repo.head)) {
      try await reader.read("HEAD")
    }
  }

  @Test("a name that resolves to no commit can't be read — catches a typo read as an empty change")
  func unknownCommit() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }

    await #expect(throws: SurfaceReadError.unknownCommit("no-such-branch")) {
      try await repo.reader.read("no-such-branch")
    }
  }
}
