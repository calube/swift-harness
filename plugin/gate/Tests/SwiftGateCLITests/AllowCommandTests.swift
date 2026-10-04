import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate allow")
struct AllowCommandTests {
  static let config = """
    schema = 1

    [harness]
    profile = "brownfield"

    [brownfield]
    discovered_at = "0123abcd"
    slice_budget_s = 30
    time_budget_min = 0
    sensitive = ["api/auth/**"]

    [[areas]]
    name = "api"
    root = "api"
    language = "python"
    kind = "python"
    test = "pytest"
    test_files = "pytest {tests}"
    lint = "flake8 {files}"
    test_globs = ["api/tests/**/*.py"]
    packs = []

    [[areas]]
    name = "app"
    root = "App"
    language = "swift"
    kind = "xcode"
    build = "xcodebuild build -workspace App/App.xcworkspace -scheme App"
    test_globs = []
    packs = ["tca"]

    [areas.xcode]
    workspace = "App/App.xcworkspace"
    inclusion = "tuist"
    manifest = "App/Project.swift"
    schemes = ["App"]

    [[allow]]
    rule = "neutral.unsafe-shortcut"
    path = "api/old.py"
    line_sha = "f40fa760a01d75985b218010f6b98666aad3d2812881e9c7b35f9ed6651bcad2"
    reason = "kept from an earlier run"

    """

  static let handlers = "import json\n    value = parse(x)  # type: ignore\n"

  /// A clone with its own `.git` directory, so no test touches this checkout's common dir.
  static func makeClone(config: String?) throws -> URL {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-allow-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    let state = root.appending(path: ".git/swift-harness", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appending(path: "api"), withIntermediateDirectories: true)
    try Data(handlers.utf8).write(to: root.appending(path: "api/handlers.py"))
    if let config {
      try Data(config.utf8).write(to: state.appending(path: "config.toml"))
    }
    return root
  }

  static func readConfig(_ root: URL) throws -> BrownfieldConfig {
    let text = try String(
      contentsOf: root.appending(path: ".git/swift-harness/config.toml"), encoding: .utf8)
    return try TOMLConfigDecoder().decodeBrownfield(text)
  }

  static func allow(
    _ root: URL, _ rule: String, _ location: String, _ reason: String,
    lockTimeout: Duration = .seconds(30)
  ) async -> Result<BrownfieldAllow, AllowCommandError> {
    do throws(AllowCommandError) {
      return .success(
        try await AllowCommand.allow(
          worktree: root, rule: rule, location: location, reason: reason,
          lockTimeout: lockTimeout))
    } catch {
      return .failure(error)
    }
  }

  @Test(
    "allow adds 1 entry keyed by the line's hash and keeps every other key — catches a writer that rewrites the areas"
  )
  func addsOneEntry() async throws {
    let root = try Self.makeClone(config: Self.config)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = try Self.readConfig(root)

    let result = await Self.allow(
      root, "neutral.unsafe-shortcut", "api/handlers.py:2", "the stub package has no types")

    let expected = BrownfieldAllow(
      rule: "neutral.unsafe-shortcut", path: "api/handlers.py",
      lineSHA: AllowMatching.lineSHA("    value = parse(x)  # type: ignore"),
      reason: "the stub package has no types")
    #expect(result == .success(expected))
    let after = try Self.readConfig(root)
    #expect(after.allow == before.allow + [expected])
    #expect(after.areas == before.areas)
    #expect(after.brownfield == before.brownfield)
    #expect(after.buildPresets == before.buildPresets)
  }

  @Test(
    "allow refuses a rule that isn't waivable by line, a missing line and an empty reason, and writes nothing — catches a bad entry written to the config"
  )
  func refusesBadInput() async throws {
    let root = try Self.makeClone(config: Self.config)
    defer { try? FileManager.default.removeItem(at: root) }
    let configURL = root.appending(path: ".git/swift-harness/config.toml")
    let original = try Data(contentsOf: configURL)

    #expect(
      await Self.allow(root, "area.test-failed", "api/handlers.py:2", "r")
        == .failure(.rule("area.test-failed")))
    #expect(
      await Self.allow(root, "nope.rule", "api/handlers.py:2", "r") == .failure(.rule("nope.rule")))
    #expect(
      await Self.allow(root, "neutral.unsafe-shortcut", "api/handlers.py", "r")
        == .failure(.location("api/handlers.py")))
    #expect(
      await Self.allow(root, "neutral.unsafe-shortcut", "api/handlers.py:9", "r")
        == .failure(.lineOutOfRange(path: "api/handlers.py", line: 9)))
    #expect(
      await Self.allow(root, "neutral.unsafe-shortcut", "api/handlers.py:2", "  ")
        == .failure(.emptyReason))
    #expect(try Data(contentsOf: configURL) == original)
  }

  @Test(
    "allow outside a brownfield clone fails naming the directory — catches a config created where none was"
  )
  func needsBrownfieldClone() async throws {
    let root = try Self.makeClone(config: nil)
    defer { try? FileManager.default.removeItem(at: root) }
    let result = await Self.allow(root, "neutral.unsafe-shortcut", "api/handlers.py:2", "r")
    #expect(result == .failure(.notBrownfield(path: root.path)))
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appending(path: ".git/swift-harness/config.toml").path))
  }

  static func layout(_ root: URL) -> BrownfieldStateLayout {
    BrownfieldStateLayout(
      commonDir: root.appending(path: ".git", directoryHint: .isDirectory),
      gitDir: root.appending(path: ".git", directoryHint: .isDirectory))
  }

  @Test(
    "allow waits on the lock discover --apply holds and writes nothing while it is held — catches allow and discover locking different files"
  )
  func waitsOnDiscoverLock() async throws {
    let root = try Self.makeClone(config: Self.config)
    defer { try? FileManager.default.removeItem(at: root) }
    let configURL = root.appending(path: ".git/swift-harness/config.toml")
    let original = try Data(contentsOf: configURL)
    let lease = try await FileCountingLock(
      directory: Self.layout(root).cloneRoot, name: BrownfieldConfigWriter.lockName,
      capacity: 1, pollInterval: .milliseconds(5)
    ).acquire(timeout: .seconds(5))
    defer { lease.release() }

    let result = await Self.allow(
      root, "neutral.unsafe-shortcut", "api/handlers.py:2", "r", lockTimeout: .milliseconds(200))

    guard case .failure(.write(.lock(.timedOut))) = result else {
      Issue.record("expected allow to time out on the held lock, got \(result)")
      return
    }
    #expect(try Data(contentsOf: configURL) == original)
  }

  @Test(
    "allow and discover's writer racing on 1 clone both keep their edits — catches a lost allow entry or a lost discover change"
  )
  func raceKeepsBothEdits() async throws {
    let root = try Self.makeClone(config: Self.config)
    defer { try? FileManager.default.removeItem(at: root) }
    let lines = (1...12).map { "value\($0) = parse(x)  # type: ignore" }
    try Data((lines.joined(separator: "\n") + "\n").utf8)
      .write(to: root.appending(path: "api/handlers.py"))
    let writer = BrownfieldConfigWriter(
      layout: Self.layout(root),
      lock: FileCountingLock(
        directory: Self.layout(root).cloneRoot, name: BrownfieldConfigWriter.lockName,
        capacity: 1, pollInterval: .milliseconds(1)))

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 1...lines.count {
        group.addTask {
          _ = try await Self.allow(
            root, "neutral.unsafe-shortcut", "api/handlers.py:\(index)", "reason \(index)"
          ).get()
        }
        group.addTask {
          try await writer.updateConfig { config throws(BrownfieldConfigWriteError) in
            guard let config else { throw .rejected("no config") }
            return BrownfieldConfig(
              brownfield: BrownfieldSettings(
                discoveredAt: config.brownfield.discoveredAt,
                sliceBudgetSeconds: config.brownfield.sliceBudgetSeconds,
                timeBudgetMinutes: config.brownfield.timeBudgetMinutes,
                sensitive: config.brownfield.sensitive + ["s\(index)/**"]),
              areas: config.areas, allow: config.allow, buildPresets: config.buildPresets)
          }
        }
      }
      try await group.waitForAll()
    }

    let after = try Self.readConfig(root)
    #expect(Set(after.allow.map(\.reason)).isSuperset(of: (1...lines.count).map { "reason \($0)" }))
    #expect(Set(after.brownfield.sensitive).isSuperset(of: (1...lines.count).map { "s\($0)/**" }))
  }

  @Test(
    "allow over a config that fails to load fails naming it and leaves it byte for byte — catches a writer that replaces what it couldn't read"
  )
  func invalidConfigUntouched() async throws {
    let root = try Self.makeClone(config: "schema = 1\n[harness]\nprofile = \"owned\"\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let configURL = root.appending(path: ".git/swift-harness/config.toml")
    let original = try Data(contentsOf: configURL)

    let result = await Self.allow(root, "neutral.unsafe-shortcut", "api/handlers.py:2", "r")

    guard case .failure(.write(.malformed(let path, _))) = result else {
      Issue.record("expected the malformed config to be refused, got \(result)")
      return
    }
    #expect(path == configURL.path)
    #expect(try Data(contentsOf: configURL) == original)
  }
}
