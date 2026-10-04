import Foundation
import SwiftGateDomain
import Testing

/// Builds brownfield `config.toml` documents as parsed trees, so each test changes 1 key.
enum BrownfieldConfigSample {
  static let lineSHA = String(repeating: "ab", count: 32)

  static let presetTable: [String: ConfigValue] = [
    "design_tier": .string("none"),
    "max_parallel": .integer(3),
    "review": .string("classified"),
    "task_gate": .string("slice"),
    "merge_gate": .string("merge"),
    "worker_model": .string("claude-sonnet-5-5"),
    "time_budget_min": .integer(0),
    "stop_starts_before_min": .integer(0),
    "on_design_conflict": .string("block"),
    "task_proof": .string("prove"),
    "stall_min": .integer(2),
  ]

  static let coreArea: [String: ConfigValue] = [
    "name": .string("core"),
    "root": .string("Core"),
    "language": .string("swift"),
    "kind": .string("swiftpm"),
    "test": .string("swift test --package-path Core"),
    "test_files": .string("swift test --package-path Core --filter {tests}"),
    "lint": .string("swiftlint lint --config .swiftlint.yml {files}"),
    "test_globs": .array([.string("Core/Tests/**/*.swift")]),
    "packs": .array([]),
  ]

  static let appArea: [String: ConfigValue] = [
    "name": .string("app"),
    "root": .string("App"),
    "language": .string("swift"),
    "kind": .string("xcode"),
    "build": .string("xcodebuild build -workspace App/App.xcworkspace -scheme \"App\""),
    "e2e": .string("make ui-test"),
    "test_globs": .array([]),
    "packs": .array([.string("tca")]),
    "xcode": .table([
      "workspace": .string("App/App.xcworkspace"),
      "inclusion": .string("tuist"),
      "manifest": .string("App/Project.swift"),
      "schemes": .array([.string("App")]),
    ]),
  ]

  static let allowEntry: [String: ConfigValue] = [
    "rule": .string("neutral.unsafe-shortcut"),
    "path": .string("api/handlers.py"),
    "line_sha": .string(lineSHA),
    "reason": .string("the parser guarantees a value here"),
  ]

  static func document(
    areas: [[String: ConfigValue]] = [coreArea, appArea],
    allow: [[String: ConfigValue]] = [allowEntry],
    brownfield: [String: ConfigValue] = [:],
    preset: [String: ConfigValue] = [:]
  ) -> ConfigValue {
    var settings: [String: ConfigValue] = [
      "discovered_at": .string("0123abcd"),
      "slice_budget_s": .integer(30),
      "time_budget_min": .integer(0),
      "sensitive": .array([.string("api/auth/**")]),
    ]
    settings.merge(brownfield) { _, new in new }
    return .table([
      "schema": .integer(1),
      "harness": .table(["profile": .string("brownfield")]),
      "brownfield": .table(settings),
      "areas": .array(areas.map(ConfigValue.table)),
      "allow": .array(allow.map(ConfigValue.table)),
      "build": .table([
        "presets": .table([
          "brownfield": .table(presetTable.merging(preset) { _, new in new })
        ])
      ]),
    ])
  }

  static let preset = BuildPreset(
    designTier: .none, maxParallel: 3, review: .classified, taskGate: .tier(.slice),
    mergeGate: .merge, workerModel: .claudeSonnet55, timeBudgetMin: 0, stopStartsBeforeMin: 0,
    onDesignConflict: .block, taskProof: .prove, stallMin: 2)

  static let config = BrownfieldConfig(
    brownfield: BrownfieldSettings(
      discoveredAt: "0123abcd", sliceBudgetSeconds: 30, timeBudgetMinutes: 0,
      sensitive: ["api/auth/**"]),
    areas: [
      BrownfieldArea(
        name: "core", root: "Core", language: .swift, kind: .swiftpm,
        test: "swift test --package-path Core",
        testFiles: "swift test --package-path Core --filter {tests}",
        lint: "swiftlint lint --config .swiftlint.yml {files}", build: nil, e2e: nil,
        testGlobs: ["Core/Tests/**/*.swift"], packs: [], xcode: nil),
      BrownfieldArea(
        name: "app", root: "App", language: .swift, kind: .xcode, test: nil, testFiles: nil,
        lint: nil, build: "xcodebuild build -workspace App/App.xcworkspace -scheme \"App\"",
        e2e: "make ui-test", testGlobs: [], packs: [.tca],
        xcode: XcodeAreaConfig(
          workspace: "App/App.xcworkspace", project: nil, inclusion: .tuist,
          manifest: "App/Project.swift", schemes: ["App"])),
    ],
    allow: [
      BrownfieldAllow(
        rule: "neutral.unsafe-shortcut", path: "api/handlers.py", lineSHA: lineSHA,
        reason: "the parser guarantees a value here")
    ],
    buildPresets: ["brownfield": preset])

  /// ``config`` as `config.toml` text.
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
    lint = "swiftlint lint --config .swiftlint.yml {files}"
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
    line_sha = "\(lineSHA)"
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

@Suite("brownfield config")
struct BrownfieldConfigTests {
  private func issues(_ document: ConfigValue) -> [ConfigIssue] {
    do {
      _ = try BrownfieldConfigSchema.config(from: document)
      return []
    } catch {
      return error.issues
    }
  }

  @Test(
    "a config with every key reads to the areas, xcode table, allow entry and preset it names — catches a reader that drops a table"
  )
  func readsEveryKey() throws {
    let config = try BrownfieldConfigSchema.config(from: BrownfieldConfigSample.document())
    #expect(config == BrownfieldConfigSample.config)
  }

  @Test(
    "rendering a config with every key gives the schema's text, quotes escaped — catches a renderer that drops [[allow]] or [areas.xcode]"
  )
  func rendersEveryKey() {
    #expect(
      BrownfieldConfigTOML.render(BrownfieldConfigSample.config) == BrownfieldConfigSample.text)
  }

  @Test(
    "an unknown language fails naming areas[0].language and the allowed list — catches an open string"
  )
  func unknownLanguage() {
    var area = BrownfieldConfigSample.coreArea
    area["language"] = .string("perl")
    let found = issues(BrownfieldConfigSample.document(areas: [area]))
    #expect(
      found == [
        .unknownEnumValue(
          path: "areas[0].language", value: "perl", allowed: AreaLanguage.allCases.map(\.rawValue))
      ])
    #expect(found.first?.description.contains("typescript") == true)
  }

  @Test("an xcode area with no [areas.xcode] fails naming the area — catches a silent default")
  func xcodeAreaNeedsTable() {
    var area = BrownfieldConfigSample.appArea
    area["xcode"] = nil
    let found = issues(BrownfieldConfigSample.document(areas: [area]))
    #expect(found == [.xcodeTableMissing(path: "areas[0].xcode", area: "app")])
    #expect(found.first?.description.contains("\"app\"") == true)
  }

  @Test("an [areas.xcode] on a swiftpm area, or with both workspace and project, fails")
  func xcodeTableMisplaced() {
    var core = BrownfieldConfigSample.coreArea
    core["xcode"] = BrownfieldConfigSample.appArea["xcode"]
    var app = BrownfieldConfigSample.appArea
    app["xcode"] = .table([
      "workspace": .string("App/App.xcworkspace"), "project": .string("App/App.xcodeproj"),
      "inclusion": .string("explicit"),
    ])
    #expect(
      issues(BrownfieldConfigSample.document(areas: [core, app])) == [
        .xcodeTableUnexpected(path: "areas[0].xcode", area: "core", kind: .swiftpm),
        .exactlyOne(path: "areas[1].xcode", keys: ["workspace", "project"]),
      ])
  }

  @Test("an [[allow]] with no reason fails naming its key — catches a waiver without a why")
  func allowNeedsReason() {
    var entry = BrownfieldConfigSample.allowEntry
    entry["reason"] = nil
    #expect(
      issues(BrownfieldConfigSample.document(allow: [entry])) == [
        .missingKey(path: "allow[0].reason")
      ])
  }

  @Test("an [[allow]] line_sha that isn't a SHA-256 fails — catches a line-number key")
  func allowNeedsHash() {
    var entry = BrownfieldConfigSample.allowEntry
    entry["line_sha"] = .string("42")
    #expect(
      issues(BrownfieldConfigSample.document(allow: [entry])) == [
        .outOfRange(path: "allow[0].line_sha", value: "42", allowed: "64 lowercase hex characters")
      ])
  }

  @Test("2 areas with 1 name fail naming the second — catches areas merged by name")
  func duplicateAreaName() {
    let found = issues(
      BrownfieldConfigSample.document(
        areas: [BrownfieldConfigSample.coreArea, BrownfieldConfigSample.coreArea]))
    #expect(found == [.duplicateName(path: "areas[1].name", name: "core")])
  }

  @Test("slice_budget_s = 0 fails — catches a slice tier with no budget")
  func zeroSliceBudget() {
    #expect(
      issues(BrownfieldConfigSample.document(brownfield: ["slice_budget_s": .integer(0)])) == [
        .outOfRange(path: "brownfield.slice_budget_s", value: "0", allowed: ">= 1")
      ])
  }

  @Test("a profile other than brownfield fails — catches an owned config read as brownfield")
  func wrongProfile() {
    guard case .table(var root) = BrownfieldConfigSample.document() else {
      Issue.record("the sample isn't a table")
      return
    }
    root["harness"] = .table(["profile": .string("default")])
    #expect(
      issues(.table(root)) == [
        .unknownEnumValue(path: "harness.profile", value: "default", allowed: ["brownfield"])
      ])
  }

  @Test("the state layout names each clone and worktree path under swift-harness")
  func stateLayout() {
    let layout = BrownfieldStateLayout(
      commonDir: URL(filePath: "/r/.git", directoryHint: .isDirectory),
      gitDir: URL(filePath: "/r/.git/worktrees/w", directoryHint: .isDirectory))
    #expect(layout.config.path == "/r/.git/swift-harness/config.toml")
    #expect(layout.settings.path == "/r/.git/swift-harness/settings.json")
    #expect(layout.discoverDirty.path == "/r/.git/swift-harness/discover/dirty.json")
    #expect(layout.discoverLast.path == "/r/.git/swift-harness/discover/last.json")
    #expect(layout.baseline(tree: "t1").path == "/r/.git/swift-harness/baseline/t1.json")
    #expect(layout.warmup(tree: "t1").path == "/r/.git/swift-harness/warmup/t1.json")
    #expect(layout.plan(slug: "p").path == "/r/.git/swift-harness/plans/p")
    #expect(layout.worktreeRoot.path == "/r/.git/worktrees/w/swift-harness")
    #expect(layout.scratchDirectory.path == "/r/.git/worktrees/w/swift-harness/scratch")
  }

  @Test(
    "each malformed part names its own key: schema, a missing table, a pack, an empty command, a negative budget — catches a reader that stops at the first issue"
  )
  func malformedPartsEachNamed() {
    var area = BrownfieldConfigSample.coreArea
    area["packs"] = .array([.string("redux")])
    area["lint"] = .string("  ")
    guard case .table(var root) = BrownfieldConfigSample.document(areas: [area]) else {
      Issue.record("the sample isn't a table")
      return
    }
    root["schema"] = .integer(2)
    root["brownfield"] = nil
    #expect(
      issues(.table(root)) == [
        .unsupportedSchema(found: 2), .missingKey(path: "brownfield"),
        .emptyValue(path: "areas[0].lint"),
        .unknownEnumValue(
          path: "areas[0].packs[0]", value: "redux",
          allowed: ["tca", "dependencies", "module-kinds"]),
      ])
    #expect(
      issues(BrownfieldConfigSample.document(brownfield: ["time_budget_min": .integer(-1)])) == [
        .outOfRange(path: "brownfield.time_budget_min", value: "-1", allowed: ">= 0")
      ])
    #expect(
      issues(.string("schema = 1")) == [
        .wrongType(path: "(root)", expected: "table", found: "string")
      ])
  }

  @Test("each xcode-table issue says what to change — catches an issue that names no area")
  func xcodeIssueDescriptions() {
    #expect(
      ConfigIssue.xcodeTableUnexpected(path: "areas[0].xcode", area: "core", kind: .swiftpm)
        .description
        == "areas[0].xcode: area \"core\" has kind \"swiftpm\", so it takes no [areas.xcode] table")
    #expect(
      ConfigIssue.exactlyOne(path: "areas[1].xcode", keys: ["workspace", "project"]).description
        == "areas[1].xcode: set exactly one of workspace, project")
  }

  @Test("a control character renders as a TOML \\u escape — catches a raw byte in config.toml")
  func controlCharacterEscaped() {
    let area = BrownfieldArea(
      name: "a", root: ".", language: .go, kind: .go, test: "go test\u{1}./...", testFiles: nil,
      lint: nil, build: nil, e2e: nil, testGlobs: [], packs: [], xcode: nil)
    let config = BrownfieldConfig(
      brownfield: BrownfieldConfigSample.config.brownfield, areas: [area], allow: [],
      buildPresets: [:])
    #expect(BrownfieldConfigTOML.render(config).contains("test = \"go test\\u0001./...\""))
  }

  @Test(
    "an applied proposal becomes the config area with each command under its key and no pack — catches a command filed under the wrong step"
  )
  func areaFromProposal() {
    let xcode = XcodeAreaConfig(
      workspace: nil, project: "App/App.xcodeproj", inclusion: .explicit, manifest: nil,
      schemes: ["App"])
    let proposed = ProposedArea(
      name: "app", root: "App", language: .swift, kind: .xcode, source: "App/App.xcodeproj",
      commands: [
        .test: Sourced(value: "make test", source: "Makefile", confidence: .found),
        .lint: Sourced(value: "swiftlint {files}", source: ".swiftlint.yml", confidence: .guessed),
        .build: Sourced(value: "xcodebuild build", source: "ci.yml", confidence: .orchestrator),
        .generate: Sourced(value: "xcodegen", source: "project.yml", confidence: .found),
      ],
      missing: [.testFiles: "no filter"], testGlobs: ["App/Tests/**"],
      xcode: Sourced(value: xcode, source: "App/App.xcodeproj", confidence: .found),
      generatedProjectTracked: nil)
    #expect(
      BrownfieldArea(proposed: proposed)
        == BrownfieldArea(
          name: "app", root: "App", language: .swift, kind: .xcode, test: "make test",
          testFiles: nil, lint: "swiftlint {files}", build: "xcodebuild build", e2e: nil,
          testGlobs: ["App/Tests/**"], packs: [], xcode: xcode))
  }

  @Test(
    "a snapshot of files lists them sorted and reads only those — catches a read past the listing")
  func snapshotFromFiles() {
    let tree = TrackedTreeSnapshot(
      files: ["web/package.json": Data("{}".utf8), "Cargo.toml": Data("[workspace]".utf8)])
    #expect(tree.paths == ["Cargo.toml", "web/package.json"])
    #expect(tree.read("Cargo.toml") == Data("[workspace]".utf8))
    #expect(tree.read("node_modules/x/package.json") == nil)
  }
}
