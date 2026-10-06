import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("brownfield config.toml")
struct BrownfieldConfigTOMLTests {
  @Test(
    "a config with every key round-trips through read and render byte for byte — catches a renderer that drops [[allow]] or [areas.xcode]"
  )
  func roundTrips() throws {
    let config = try TOMLConfigDecoder().decodeBrownfield(BrownfieldConfigTOMLSample.text)
    #expect(BrownfieldConfigTOML.render(config) == BrownfieldConfigTOMLSample.text)
    #expect(config.areas.map(\.xcode?.inclusion) == [nil, .tuist])
    #expect(config.allow.map(\.reason) == ["the parser guarantees a value here"])
  }

  @Test(
    "the local packages an Xcode area builds round-trip through config.toml — catches a config that forgets them and stops gating the app on a package change"
  )
  func xcodePackagesRoundTrip() throws {
    let directory = Fixture.directory.appending(
      path: "Discover/timed-build-starter", directoryHint: .isDirectory)
    let listing = try String(
      contentsOf: directory.appending(path: "ls-files.txt"), encoding: .utf8)
    let tree = TrackedTreeSnapshot(
      paths: listing.split(separator: "\n").map(String.init),
      read: { try? Data(contentsOf: directory.appending(path: "tree/\($0)")) })
    let config = Discover.config(
      from: Discover.propose(tree: tree, head: "abc", dirty: []), keeping: nil)
    let packages = config.areas.compactMap(\.xcode).flatMap(\.packages)
    #expect(
      packages == ["Packages/APIClient", "Packages/AppFeature", "Packages/LogClient"])

    let text = BrownfieldConfigTOML.render(config)
    #expect(
      text.contains(
        #"packages = ["Packages/APIClient", "Packages/AppFeature", "Packages/LogClient"]"#))
    #expect(try TOMLConfigDecoder().decodeBrownfield(text) == config)
  }

  @Test("a value TOML must escape survives a round trip — catches unescaped quotes")
  func escapesRoundTrip() throws {
    let text = BrownfieldConfigTOMLSample.text.replacingOccurrences(
      of: "make ui-test", with: "printf 'a\\\\tb\\\\n' \\\"quoted\\\" \\u00E9")
    let config = try TOMLConfigDecoder().decodeBrownfield(text)
    try #require(config.areas.count == 2)
    #expect(config.areas[1].e2e == "printf 'a\\tb\\n' \"quoted\" é")
    let again = try TOMLConfigDecoder().decodeBrownfield(BrownfieldConfigTOML.render(config))
    #expect(again == config)
  }

  @Test(
    "a [judge] table reads as the owned profile's judge settings and renders back byte for byte — catches a brownfield clone that can never name a judge, so the slice judge stays advisory"
  )
  func judgeRoundTrips() throws {
    let judge = """
      [judge]
      backend = "jev"
      model = "jev-1.13.0"
      send_to = "api.typesafe.ai"
      advisory_threshold = 0.6
      block_threshold = 0.9

      """
    let text = BrownfieldConfigTOMLSample.text.replacingOccurrences(
      of: "[build.presets.brownfield]", with: judge + "\n[build.presets.brownfield]")
    let config = try TOMLConfigDecoder().decodeBrownfield(text)
    #expect(
      config.judge
        == .enabled(
          backend: .jev, thresholds: JudgeThresholds(advisory: 0.6, block: 0.9),
          model: "jev-1.13.0"))
    #expect(BrownfieldConfigTOML.render(config) == text)
  }

  @Test(
    "a [judge] key holding a credential is refused by name — catches a brownfield config that stores an API key"
  )
  func judgeSecretRefused() throws {
    let text = BrownfieldConfigTOMLSample.text.replacingOccurrences(
      of: "[build.presets.brownfield]",
      with: "[judge]\nbackend = \"claude\"\napi_key = \"sk\"\n\n[build.presets.brownfield]")
    let error = #expect(throws: ConfigLoadError.self) {
      try TOMLConfigDecoder().decodeBrownfield(text)
    }
    let message = error.map { "\($0)" } ?? "no error"
    #expect(message.contains("judge.api_key"), "\(message)")
    let plain = try TOMLConfigDecoder().decodeBrownfield(BrownfieldConfigTOMLSample.text)
    #expect(plain.judge == .disabled)
  }
}

enum BrownfieldConfigTOMLSample {
  static let text = """
    schema = 1

    [harness]
    profile = "brownfield"

    [brownfield]
    discovered_at = "0123abcd"
    slice_budget_s = 30
    time_budget_min = 0
    sensitive = ["api/auth/**"]

    [[areas]]
    name = "core"
    root = "Core"
    language = "swift"
    kind = "swiftpm"
    test = "swift test --package-path Core"
    test_files = "swift test --package-path Core --filter {tests}"
    test_globs = ["Core/Tests/**/*.swift"]
    packs = []

    [[areas]]
    name = "app"
    root = "App"
    language = "swift"
    kind = "xcode"
    build = "xcodebuild build -workspace App/App.xcworkspace -scheme \\"App\\""
    e2e = "make ui-test"
    test_globs = []
    packs = ["tca"]

    [areas.xcode]
    workspace = "App/App.xcworkspace"
    inclusion = "tuist"
    manifest = "App/Project.swift"
    schemes = ["App"]

    [[allow]]
    rule = "neutral.unsafe-shortcut"
    path = "api/handlers.py"
    line_sha = "abababababababababababababababababababababababababababababababab"
    reason = "the parser guarantees a value here"

    [build.presets.brownfield]
    design_tier = "none"
    max_parallel = 3
    review = "classified"
    task_gate = "slice"
    merge_gate = "merge"
    worker_model = "claude-sonnet-5-5"
    time_budget_min = 0
    stop_starts_before_min = 0
    on_design_conflict = "block"
    task_proof = "prove"
    stall_min = 2

    """
}
