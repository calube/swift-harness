import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

private func temporaryDirectory(_ label: String) throws -> URL {
  let url = TestTemporaryDirectory.root
    .appending(path: "swiftgate-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    .resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func emptyConfig() -> BrownfieldConfig {
  BrownfieldConfig(
    brownfield: BrownfieldSettings(
      discoveredAt: "abc", sliceBudgetSeconds: 30, timeBudgetMinutes: 0, sensitive: []),
    areas: [], allow: [], buildPresets: [:])
}

private func area(_ name: String) -> BrownfieldArea {
  BrownfieldArea(
    name: name, root: name, language: .go, kind: .go, test: "go test ./...", testFiles: nil,
    lint: nil, build: nil, e2e: nil, testGlobs: [], packs: [], xcode: nil)
}

@Suite("brownfield discover adapters")
struct BrownfieldDiscoverAdaptersTests {
  @Test(
    "concurrent config updates each land, so no allow entry is lost — catches a read-modify-write outside the lock"
  )
  func concurrentUpdatesSerialise() async throws {
    let common = try temporaryDirectory("writer")
    defer { try? FileManager.default.removeItem(at: common) }
    let layout = BrownfieldStateLayout(commonDir: common, gitDir: common)
    let lock = FileCountingLock(
      directory: layout.cloneRoot, name: BrownfieldConfigWriter.lockName, capacity: 1,
      pollInterval: .milliseconds(5))
    let writer = BrownfieldConfigWriter(layout: layout, lock: lock)
    try await writer.updateConfig { _ in emptyConfig() }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        group.addTask {
          try await writer.updateConfig { config throws(BrownfieldConfigWriteError) in
            guard let config else { throw .rejected("no config") }
            let entry = BrownfieldAllow(
              rule: "neutral.no-assertion", path: "a\(index).go",
              lineSHA: String(repeating: "c", count: 64), reason: "reason \(index)")
            return BrownfieldConfig(
              brownfield: config.brownfield, areas: config.areas,
              allow: config.allow + [entry], buildPresets: config.buildPresets)
          }
        }
      }
      try await group.waitForAll()
    }

    let config = try TOMLConfigDecoder().decodeBrownfield(
      String(contentsOf: layout.config, encoding: .utf8))
    #expect(config.allow.map(\.path).sorted() == (0..<8).map { "a\($0).go" }.sorted())
  }

  @Test(
    "a config that fails its own schema is refused and no state file is written — catches discover writing a config.toml nothing can load"
  )
  func invalidRenderWritesNothing() async throws {
    let common = try temporaryDirectory("writer-invalid")
    defer { try? FileManager.default.removeItem(at: common) }
    let layout = BrownfieldStateLayout(commonDir: common, gitDir: common)
    let duplicate = BrownfieldConfig(
      brownfield: emptyConfig().brownfield, areas: [area("api"), area("api")], allow: [],
      buildPresets: [:])

    let error = await #expect(throws: BrownfieldConfigWriteError.self) {
      try await BrownfieldConfigWriter(layout: layout).update { _, _ in
        BrownfieldStateWrite(config: duplicate, files: [layout.discoverLast: Data("{}".utf8)])
      }
    }

    guard case .invalidRender(let reason) = error else {
      Issue.record("expected the schema to refuse the config, got \(String(describing: error))")
      return
    }
    #expect(reason.contains("api"))
    #expect(!FileManager.default.fileExists(atPath: layout.config.path))
    #expect(!FileManager.default.fileExists(atPath: layout.discoverLast.path))
  }

  @Test(
    "the tracked tree lists git's files only, reads none it doesn't list, and names a rename's new path among the dirty ones — catches an untracked file read as a signal"
  )
  func trackedTreeAndDirtyPaths() async throws {
    let root = try temporaryDirectory("tracked")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = LiveProcessRunner(baseEnvironment: [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
      "HOME": FileManager.default.temporaryDirectory.path, "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@e.com",
      "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@e.com",
    ])
    func git(_ arguments: String...) async throws {
      let output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: root.path,
          timeout: .seconds(30)))
      #expect(output.status.isSuccess, "\(arguments): \(output.stderr.text)")
    }
    try await git("init", "-q", "-b", "main")
    try Data("old\n".utf8).write(to: root.appending(path: "old.txt"))
    try Data("{}\n".utf8).write(to: root.appending(path: "package.json"))
    try await git("add", "-A")
    try await git("-c", "commit.gpgsign=false", "commit", "-q", "-m", "base")
    try await git("mv", "old.txt", "new.txt")
    try Data("{}\n".utf8).write(to: root.appending(path: "untracked.json"))
    let tree = GitTrackedTree(runner: runner, directory: root)

    let snapshot = try await tree.snapshot()
    let dirty = try await tree.dirtyPaths()

    #expect(snapshot.paths.sorted() == ["new.txt", "package.json"])
    #expect(snapshot.read("package.json") == Data("{}\n".utf8))
    #expect(snapshot.read("untracked.json") == nil)
    #expect(dirty == ["new.txt", "untracked.json"])
    #expect(try await tree.head().count == 40)
  }
}
