import Foundation
import SwiftGateAdapters
import SwiftGateDomain
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
    let root = FileManager.default.temporaryDirectory
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

  static func allow(_ root: URL, _ rule: String, _ location: String, _ reason: String) -> Result<
    BrownfieldAllow, AllowCommandError
  > {
    do throws(AllowCommandError) {
      return .success(
        try AllowCommand.allow(worktree: root, rule: rule, location: location, reason: reason))
    } catch {
      return .failure(error)
    }
  }

  @Test(
    "allow adds 1 entry keyed by the line's hash and keeps every other key — catches a writer that rewrites the areas"
  )
  func addsOneEntry() throws {
    let root = try Self.makeClone(config: Self.config)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = try Self.readConfig(root)

    let result = Self.allow(
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
  func refusesBadInput() throws {
    let root = try Self.makeClone(config: Self.config)
    defer { try? FileManager.default.removeItem(at: root) }
    let configURL = root.appending(path: ".git/swift-harness/config.toml")
    let original = try Data(contentsOf: configURL)

    #expect(
      Self.allow(root, "area.test-failed", "api/handlers.py:2", "r")
        == .failure(.rule("area.test-failed")))
    #expect(Self.allow(root, "nope.rule", "api/handlers.py:2", "r") == .failure(.rule("nope.rule")))
    #expect(
      Self.allow(root, "neutral.unsafe-shortcut", "api/handlers.py", "r")
        == .failure(.location("api/handlers.py")))
    #expect(
      Self.allow(root, "neutral.unsafe-shortcut", "api/handlers.py:9", "r")
        == .failure(.lineOutOfRange(path: "api/handlers.py", line: 9)))
    #expect(
      Self.allow(root, "neutral.unsafe-shortcut", "api/handlers.py:2", "  ")
        == .failure(.emptyReason))
    #expect(try Data(contentsOf: configURL) == original)
  }

  @Test(
    "allow outside a brownfield clone fails naming the directory — catches a config created where none was"
  )
  func needsBrownfieldClone() throws {
    let root = try Self.makeClone(config: nil)
    defer { try? FileManager.default.removeItem(at: root) }
    let result = Self.allow(root, "neutral.unsafe-shortcut", "api/handlers.py:2", "r")
    #expect(result == .failure(.config(.notBrownfield(path: root.path))))
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appending(path: ".git/swift-harness/config.toml").path))
  }
}
