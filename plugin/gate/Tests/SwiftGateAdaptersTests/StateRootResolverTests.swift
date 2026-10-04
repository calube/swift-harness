import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("state root: where a worktree's harness state lives")
struct StateRootResolverTests {
  static let runID = "20261003T120000Z-0000abcd"

  /// A repository with 1 commit; `owned` commits a `.swiftgate.toml`, `configured` writes the
  /// common dir's `swift-harness/config.toml`.
  static func clone(owned: Bool = false, configured: Bool = false) async throws
    -> TemporaryGitRepository
  {
    let repository = try await TemporaryGitRepository()
    try repository.write("Sources/App/App.swift", "let app = 1\n")
    if owned { try repository.write(Config.fileName, "schema = 1\n") }
    _ = try await repository.commitAll("base")
    if configured { try configure(repository) }
    return repository
  }

  static func configure(_ repository: TemporaryGitRepository) throws {
    let file = repository.root.appending(path: ".git/swift-harness/config.toml")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("schema = 1\n".utf8).write(to: file)
  }

  static func gitDirectory(_ repository: TemporaryGitRepository, in directory: URL? = nil)
    async throws -> String
  {
    let output = try await repository.runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["rev-parse", "--absolute-git-dir"],
        workingDirectory: (directory ?? repository.root).path, timeout: .seconds(30)))
    return canonical(
      URL(filePath: output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  /// Without `/private`, however git or Foundation spelled it.
  static func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

  static func report() throws -> RunReport {
    try RunReport(
      runID: runID, durationMilliseconds: 10,
      tiers: [
        TierResult(
          tier: .t1, verdict: .green, durationMilliseconds: 9,
          testCounts: TestCounts(passed: 1, failed: 0, skipped: 0))
      ],
      findings: [])
  }

  /// Writes a hook state file, a run report and an event the way a hook and a gate run do.
  static func writeState(in worktree: URL) throws {
    try HookStateStore(worktreeRoot: worktree).saveLastGreen("fingerprint")
    try RunStore(worktreeRoot: worktree, events: HarnessEventFiles(root: worktree)).record(
      try report(), finishedAt: Date(timeIntervalSince1970: 1_790_000_000))
    try HarnessEventFiles(root: worktree).append(EventSegmentStoreTests.decision("e1"))
  }

  /// Every file under `root`, outside `.git`, relative to it.
  static func files(under root: URL) -> Set<String> {
    let base = root.standardizedFileURL.path + "/"
    var found = Set<String>()
    let walker = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = walker?.nextObject() as? URL {
      let path = String(url.standardizedFileURL.path.dropFirst(base.count))
      if path == ".git" || path.hasPrefix(".git/") {
        walker?.skipDescendants()
        continue
      }
      if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        found.insert(path)
      }
    }
    return found
  }

  @Test(
    "a committed .swiftgate.toml keeps a run report at .harness/runs/<id>/report.json even beside a common-dir config, a bare clone keeps the tree, and a common-dir config.toml alone moves state under the git dir — catches owned repositories losing their tree state or a clone the harness doesn't own writing into its tree"
  )
  func picksTheRootByFileExistence() async throws {
    let owned = try await Self.clone(owned: true, configured: true)
    defer { owned.remove() }
    try RunStore(worktreeRoot: owned.root).record(
      try Self.report(), finishedAt: Date(timeIntervalSince1970: 1_790_000_000))
    #expect(
      FileManager.default.fileExists(
        atPath: owned.root.appending(path: ".harness/runs/\(Self.runID)/report.json").path))
    #expect(StateRootResolver.resolve(worktree: owned.root) == .tree(owned.root))

    let bare = try await Self.clone()
    defer { bare.remove() }
    #expect(StateRootResolver.resolve(worktree: bare.root) == .tree(bare.root))

    let configured = try await Self.clone(configured: true)
    defer { configured.remove() }
    let state = StateRootResolver.resolve(worktree: configured.root)
    let gitDir = try await Self.gitDirectory(configured)
    #expect(Self.canonical(state.directory) == gitDir + "/swift-harness")
    let shown = state.displayPath(RunLayout.historyFile)
    #expect(shown.hasPrefix("/") && shown.hasSuffix("/.git/swift-harness/runs/history.jsonl"))
  }

  @Test(
    "in a clone with only a common-dir config.toml, a hook state write, a run report and an event all land under <git-dir>/swift-harness/, the tree gains no file and git status prints nothing — catches 1 state path left in the tree"
  )
  func configuredCloneKeepsStateOutOfTheTree() async throws {
    let repository = try await Self.clone(configured: true)
    defer { repository.remove() }
    let tracked = Self.files(under: repository.root)

    try Self.writeState(in: repository.root)

    let state = try await Self.gitDirectory(repository) + "/swift-harness"
    for path in [
      "hook-state/last-green", "runs/\(Self.runID)/report.json", "runs/history.jsonl",
      "events/judge.jsonl", "events/gate.jsonl",
    ] {
      #expect(FileManager.default.fileExists(atPath: "\(state)/\(path)"), "\(path)")
    }
    #expect(Self.files(under: repository.root) == tracked)
    #expect(
      try await repository.git("status", "--porcelain", "--ignored", "--untracked-files=all")
        .isEmpty)
  }

  @Test(
    "a linked worktree of a configured clone writes its state under its own git dir, not the main checkout's — catches every worktree sharing 1 run store"
  )
  func linkedWorktreeUsesItsOwnGitDir() async throws {
    let repository = try await Self.clone(configured: true)
    defer { repository.remove() }
    let linked = repository.root.deletingLastPathComponent()
      .appending(path: "\(repository.root.lastPathComponent)-linked", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: linked) }
    try await repository.git("worktree", "add", "-q", "-b", "side", linked.path)

    try Self.writeState(in: linked)

    let linkedGitDir = try await Self.gitDirectory(repository, in: linked)
    let mainGitDir = try await Self.gitDirectory(repository)
    #expect(linkedGitDir != mainGitDir)
    #expect(
      FileManager.default.fileExists(
        atPath: "\(linkedGitDir)/swift-harness/runs/\(Self.runID)/report.json"))
    #expect(!FileManager.default.fileExists(atPath: "\(mainGitDir)/swift-harness/runs"))
    #expect(!FileManager.default.fileExists(atPath: linked.appending(path: ".harness").path))
  }

  @Test(
    "a scratch tree of a configured clone sits under <git-dir>/swift-harness/scratch/ and is gone afterwards, while an owned clone's stays beside the repository — catches prove's trees left beside a clone the harness doesn't own"
  )
  func scratchTreeSitsUnderTheGitDir() async throws {
    let repository = try await Self.clone(configured: true)
    defer { repository.remove() }
    let base = try await repository.git("rev-parse", "HEAD")
    let scratch = LiveScratchWorktrees(
      runner: repository.runner, repositoryRoot: repository.root.path)

    let root = try await scratch.withScratchTree(
      ScratchTreeRequest(revision: "HEAD", revertTo: base, copiedPaths: [], revertedPaths: [])
    ) { $0 }

    let parent = try await Self.gitDirectory(repository) + "/swift-harness/scratch"
    #expect(Self.canonical(root.deletingLastPathComponent()) == parent)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(
      try await repository.git("status", "--porcelain", "--ignored", "--untracked-files=all")
        .isEmpty)

    let owned = try await Self.clone(owned: true)
    defer { owned.remove() }
    let ownedBase = try await owned.git("rev-parse", "HEAD")
    let ownedRoot = try await LiveScratchWorktrees(
      runner: owned.runner, repositoryRoot: owned.root.path
    ).withScratchTree(
      ScratchTreeRequest(revision: "HEAD", revertTo: ownedBase, copiedPaths: [], revertedPaths: [])
    ) { $0 }
    #expect(
      Self.canonical(ownedRoot.deletingLastPathComponent())
        == Self.canonical(owned.root.deletingLastPathComponent()))
  }

  @Test(
    "copying a linked worktree's events up in a configured clone lands them in <common>/swift-harness/events/imported/<storeID>/ and leaves both trees clean — catches a removed worktree's events lost or copied into the tree"
  )
  func eventsCopyUpUnderTheCommonDir() async throws {
    let repository = try await Self.clone(configured: true)
    defer { repository.remove() }
    let linked = repository.root.deletingLastPathComponent()
      .appending(path: "\(repository.root.lastPathComponent)-copied", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: linked) }
    try await repository.git("worktree", "add", "-q", "-b", "copied", linked.path)
    try HarnessEventFiles(root: linked).append(EventSegmentStoreTests.decision("linked-only"))

    let outcome = try EventCopyUp(source: linked, destination: repository.root).run()

    guard case .copied(let storeID, _) = outcome else {
      Issue.record("expected a copy, got \(outcome)")
      return
    }
    let common = try await Self.gitDirectory(repository)
    let imported = "\(common)/swift-harness/events/imported/\(storeID)/judge.jsonl"
    let copied = try String(contentsOfFile: imported, encoding: .utf8)
    #expect(copied.contains("linked-only"))
    #expect(
      try await repository.git("status", "--porcelain", "--ignored", "--untracked-files=all")
        .isEmpty)
    #expect(!FileManager.default.fileExists(atPath: linked.appending(path: ".harness").path))
  }
}
