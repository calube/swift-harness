import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// A throwaway clone with its own git dir, so nothing a test writes reaches this checkout's
/// shared common dir.
private struct TemporaryClone {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  var layout: BrownfieldStateLayout {
    let gitDir = root.appending(path: ".git", directoryHint: .isDirectory)
    return BrownfieldStateLayout(commonDir: gitDir, gitDir: gitDir)
  }

  /// A clone with `files` committed on `main`.
  init(files: [String: String]) async throws {
    root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-discover-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try write(files)
    try await git("add", "-A")
    try await git("commit", "-q", "-m", "base")
  }

  func write(_ files: [String: String]) throws {
    for (path, text) in files {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
  }

  @discardableResult
  func git(_ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      struct Failure: Error { let stderr: String }
      throw Failure(stderr: output.stderr.text)
    }
    return output.stdout.text
  }

  func dependencies(
    readers: [any EcosystemReader], events: any HarnessEventWriting = MemoryEventLog()
  ) -> DiscoverCommand.Dependencies {
    DiscoverCommand.Dependencies(
      runner: runner, readers: readers, harnessRoot: nil, events: events)
  }

  func remove() { TestTemporaryDirectory.remove(root) }
}

/// 1 area per tracked `package.json` or `Package.swift`, named by its directory: a stand-in for
/// the real readers, which are their own tasks' work.
private struct ManifestReader: EcosystemReader {
  func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    tree.paths.compactMap { path in
      let parts = path.split(separator: "/").map(String.init)
      guard let file = parts.last, file == "package.json" || file == "Package.swift" else {
        return nil
      }
      let root = parts.count == 1 ? "." : parts.dropLast().joined(separator: "/")
      let node = file == "package.json"
      return ProposedArea(
        name: root == "." ? "root" : parts.dropLast().joined(separator: "-"), root: root,
        language: node ? .javascript : .swift, kind: node ? .node : .swiftpm, source: path,
        commands: [
          .lint: Sourced(value: "npx eslint {files}", source: path, confidence: .guessed)
        ], missing: [.test: "no test script"], testGlobs: [], xcode: nil,
        generatedProjectTracked: nil)
    }
  }
}

/// ``ManifestReader``, counting the times discovery runs it.
private final class CountingReader: EcosystemReader {
  private let calls = Mutex(0)
  var count: Int { calls.withLock { $0 } }

  func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    calls.withLock { $0 += 1 }
    return ManifestReader().areas(in: tree)
  }
}

@Suite("swiftgate discover")
struct DiscoverCommandTests {
  @Test(
    "untracked .build/ and ignored node_modules/ manifests yield no area — catches discovery walking the filesystem"
  )
  func untrackedBuildOutputYieldsNoArea() async throws {
    let clone = try await TemporaryClone(files: [
      ".gitignore": ".build/\nnode_modules/\n", "Package.swift": "// swift-tools-version:6.0\n",
      "web/package.json": "{}\n",
    ])
    defer { clone.remove() }
    try clone.write([
      ".build/checkouts/dep/Package.swift": "// swift-tools-version:6.0\n",
      "web/node_modules/left-pad/package.json": "{}\n",
      "scratch/package.json": "{}\n",
    ])

    let outcome = try await DiscoverCommand.propose(
      directory: clone.root, dependencies: clone.dependencies(readers: [ManifestReader()]))

    #expect(outcome.proposal.areas.map(\.root).sorted() == [".", "web"])
    #expect(outcome.proposal.dirty == ["scratch/"])
    #expect(outcome.configPath == nil)
  }

  @Test(
    "--apply in a clone writes its state under the git dir and nothing git status shows, even ignored — catches state written into the tree"
  )
  func applyLeavesTreeClean() async throws {
    let clone = try await TemporaryClone(files: ["web/package.json": "{}\n"])
    defer { clone.remove() }
    let clean = try await clone.git("status", "--porcelain", "--ignored")
    #expect(clean.isEmpty)

    let outcome = try await DiscoverCommand.apply(
      directory: clone.root, edits: [],
      dependencies: DiscoverCommand.Dependencies(
        runner: clone.runner, readers: [ManifestReader()], harnessRoot: nil, events: nil))

    let status = try await clone.git("status", "--porcelain", "--ignored")
    #expect(status.isEmpty, "\(status)")
    let layout = clone.layout
    let configPath = try #require(outcome.configPath)
    #expect(
      URL(filePath: configPath).resolvingSymlinksInPath().path
        == layout.config.resolvingSymlinksInPath().path)
    let config = try TOMLConfigDecoder().decodeBrownfield(
      String(contentsOf: layout.config, encoding: .utf8))
    #expect(config.areas.map(\.name) == ["web"])
    #expect(config.brownfield.discoveredAt == outcome.proposal.head)
    #expect(FileManager.default.fileExists(atPath: layout.discoverDirty.path))
    let record = try JSONDecoder().decode(
      DiscoverRecord.self, from: Data(contentsOf: layout.discoverLast))
    #expect(record.proposal == outcome.proposal)
    let events = layout.worktreeRoot.appending(path: "events")
    #expect(FileManager.default.fileExists(atPath: events.path))
  }

  @Test(
    "--set web.lint records source orchestrator, writes the command and emits discover.run with edited = 1 — catches an orchestrator fix recorded as a guess"
  )
  func setRecordsOrchestrator() async throws {
    let clone = try await TemporaryClone(files: ["web/package.json": "{}\n"])
    defer { clone.remove() }
    let log = MemoryEventLog()
    let edits = try DiscoverEdit.parse(
      sets: ["web.lint=npx eslint --max-warnings 0 {files}"], drops: [], reason: nil)

    let outcome = try await DiscoverCommand.apply(
      directory: clone.root, edits: edits,
      dependencies: clone.dependencies(readers: [ManifestReader()], events: log))

    let lint = try #require(outcome.proposal.areas.first?.commands[.lint])
    #expect(lint.confidence == .orchestrator)
    #expect(lint.source == DiscoverEdit.orchestratorSource)
    let config = try TOMLConfigDecoder().decodeBrownfield(
      String(contentsOf: clone.layout.config, encoding: .utf8))
    #expect(config.areas.first?.lint == "npx eslint --max-warnings 0 {files}")
    let runs = log.events.compactMap { event -> DiscoverRunEvent? in
      guard case .discoverRun(let run) = event.payload else { return nil }
      return run
    }
    #expect(runs.count == 1)
    #expect(runs.first?.edited == 1)
    #expect(runs.first?.areas == 1)
  }

  @Test(
    "a second --apply keeps the first one's --set and every allow entry — catches a rediscovery dropping the orchestrator's fix or a waiver"
  )
  func reapplyKeepsEditsAndAllow() async throws {
    let clone = try await TemporaryClone(files: ["web/package.json": "{}\n"])
    defer { clone.remove() }
    let dependencies = clone.dependencies(readers: [ManifestReader()])
    _ = try await DiscoverCommand.apply(
      directory: clone.root,
      edits: [DiscoverEdit(area: "web", step: .test, change: .set(command: "npm test"))],
      dependencies: dependencies)
    let allow = BrownfieldAllow(
      rule: "neutral.unsafe-shortcut", path: "web/a.js", lineSHA: String(repeating: "b", count: 64),
      reason: "the caller checks it")
    try await BrownfieldConfigWriter(layout: clone.layout).updateConfig {
      config throws(BrownfieldConfigWriteError) in
      guard let config else { throw .rejected("no config after the first apply") }
      return BrownfieldConfig(
        brownfield: config.brownfield, areas: config.areas, allow: config.allow + [allow],
        buildPresets: config.buildPresets)
    }

    let outcome = try await DiscoverCommand.apply(
      directory: clone.root,
      edits: [DiscoverEdit(area: "web", step: .lint, change: .drop(reason: "no linter"))],
      dependencies: dependencies)

    let config = try TOMLConfigDecoder().decodeBrownfield(
      String(contentsOf: clone.layout.config, encoding: .utf8))
    #expect(config.allow == [allow])
    #expect(config.areas.first?.test == "npm test")
    #expect(config.areas.first?.lint == nil)
    #expect(outcome.edits.count == 2)
  }

  @Test(
    "an unreadable existing config fails --apply naming it and leaves every state file as it was — catches a rediscovery clobbering a config it couldn't read"
  )
  func malformedConfigBlocks() async throws {
    let clone = try await TemporaryClone(files: ["web/package.json": "{}\n"])
    defer { clone.remove() }
    let layout = clone.layout
    try FileManager.default.createDirectory(at: layout.cloneRoot, withIntermediateDirectories: true)
    try Data("schema = 1\n[[allow]]\nrule = 3\n".utf8).write(to: layout.config)

    await #expect(throws: BrownfieldConfigWriteError.self) {
      try await DiscoverCommand.apply(
        directory: clone.root, edits: [],
        dependencies: clone.dependencies(readers: [ManifestReader()]))
    }

    #expect(try String(contentsOf: layout.config, encoding: .utf8).contains("rule = 3"))
    #expect(!FileManager.default.fileExists(atPath: layout.discoverLast.path))
  }

  @Test(
    "dirty.json lists the files modified or untracked before discovery — catches workers staging the user's own edits"
  )
  func dirtyFilesRecorded() async throws {
    let clone = try await TemporaryClone(files: ["web/package.json": "{}\n", "README": "a\n"])
    defer { clone.remove() }
    try clone.write(["README": "edited\n", "notes.txt": "mine\n"])

    _ = try await DiscoverCommand.apply(
      directory: clone.root, edits: [],
      dependencies: clone.dependencies(readers: [ManifestReader()]))

    let dirty = try JSONDecoder().decode(
      DiscoverDirtyFiles.self, from: Data(contentsOf: clone.layout.discoverDirty))
    #expect(dirty.paths == ["README", "notes.txt"])
  }

  @Test(
    "settings.json comes from the plugin's hooks.json, and when it can't be rendered the outcome says so — catches a clone left without hooks in silence"
  )
  func settingsNoteWhenUnrendered() async throws {
    let clone = try await TemporaryClone(files: ["web/package.json": "{}\n"])
    defer { clone.remove() }
    var dependencies = clone.dependencies(readers: [ManifestReader()])
    dependencies.harnessRoot = Fixture.checkoutRoot

    let outcome = try await DiscoverCommand.apply(
      directory: clone.root, edits: [], dependencies: dependencies)

    let written = FileManager.default.fileExists(atPath: clone.layout.settings.path)
    let noted = outcome.notes.contains { $0.contains("settings.json") }
    #expect(written != noted, "written: \(written), notes: \(outcome.notes)")
  }

  @Test(
    "an unchanged listing reuses the last proposal without running the readers, and a changed directory listing misses the cache — catches the stale-manifest false RED of a cached answer"
  )
  func cacheMissesOnChangedListing() async throws {
    let clone = try await TemporaryClone(files: ["web/package.json": "{}\n", "web/a.js": "1\n"])
    defer { clone.remove() }
    let reader = CountingReader()
    let dependencies = clone.dependencies(readers: [reader])
    _ = try await DiscoverCommand.apply(
      directory: clone.root,
      edits: [DiscoverEdit(area: "web", step: .test, change: .set(command: "npm test"))],
      dependencies: dependencies)
    try clone.write(["web/a.js": "2\n"])

    let hit = try await DiscoverCommand.apply(
      directory: clone.root, edits: [], dependencies: dependencies)

    #expect(reader.count == 1)
    #expect(hit.proposal.areas.map(\.name) == ["web"])
    #expect(hit.proposal.areas.first?.commands[.test]?.value == "npm test")
    #expect(hit.proposal.areas.first?.commands[.lint]?.confidence == .guessed)

    try clone.write(["api/package.json": "{}\n"])
    try await clone.git("add", "api/package.json")
    let miss = try await DiscoverCommand.apply(
      directory: clone.root, edits: [], dependencies: dependencies)

    #expect(reader.count == 2)
    #expect(miss.proposal.areas.map(\.name).sorted() == ["api", "web"])
  }
}
