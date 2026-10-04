import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A reader a test scripts: the real readers are their own tasks' work, and these tests are about
/// what discovery does with whatever the readers propose.
private struct ScriptedReader: EcosystemReader {
  let propose: @Sendable (TrackedTreeSnapshot) -> [ProposedArea]
  func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] { propose(tree) }
}

/// Proposes 1 area per tracked build file of the given names, rooted at its directory, so a
/// fixture's whole listing goes through discovery the way a real reader's would.
private struct BuildFileReader: EcosystemReader {
  let names: Set<String>
  func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    tree.paths.compactMap { path in
      let parts = path.split(separator: "/")
      guard let name = parts.last, names.contains(String(name)), tree.read(path) != nil else {
        return nil
      }
      let root = parts.count == 1 ? "." : parts.dropLast().joined(separator: "/")
      return area(name: root == "." ? "root" : root, root: root, kind: .command, source: path)
    }
  }
}

private func area(
  name: String, root: String, language: AreaLanguage = .other, kind: AreaKind,
  source: String, commands: [AreaStep: Sourced<String>] = [:], missing: [AreaStep: String] = [:]
) -> ProposedArea {
  ProposedArea(
    name: name, root: root, language: language, kind: kind, source: source, commands: commands,
    missing: missing, testGlobs: [], xcode: nil, generatedProjectTracked: nil)
}

/// A captured `F/Discover/<owner>-<repo>/` repository as discover sees it: its listing, and the
/// bytes of each signal file read on demand.
private func fixtureTree(_ name: String) throws -> TrackedTreeSnapshot {
  let directory = Fixture.directory.appending(path: "Discover/\(name)", directoryHint: .isDirectory)
  let listing = try String(
    contentsOf: directory.appending(path: "ls-files.txt"), encoding: .utf8)
  let paths = listing.split(separator: "\n").map(String.init)
  let tree = directory.appending(path: "tree", directoryHint: .isDirectory)
  return TrackedTreeSnapshot(
    paths: paths, read: { try? Data(contentsOf: tree.appending(path: $0)) })
}

@Suite("discover proposes and applies")
struct DiscoverTests {
  @Test(
    "a CI command for an area replaces the reader's guess and names the workflow as its source — catches guesses outranking what CI runs"
  )
  func ciOutranksGuess() throws {
    let tree = try fixtureTree("tauri-apps-tauri")
    let reader = ScriptedReader { _ in
      [
        area(
          name: "api", root: "packages/api", language: .typescript, kind: .node,
          source: "packages/api/package.json",
          commands: [
            .build: Sourced(
              value: "npm run build", source: "packages/api/package.json", confidence: .guessed)
          ])
      ]
    }

    let proposal = Discover.propose(tree: tree, head: "abc", dirty: [], readers: [reader])

    let build = try #require(proposal.areas.first?.commands[.build])
    #expect(build.value == "pnpm build")
    #expect(build.source == ".github/workflows/check-generated-files.yml")
    #expect(build.confidence == .found)
    let table = ProposalTable.render(proposal, milliseconds: 12, appliedTo: nil)
    let row = try #require(table.split(separator: "\n").first { $0.hasPrefix("api ") })
    #expect(row.contains(".github/workflows/check-generated-files.yml"))
    #expect(row.contains("pnpm build"))
    #expect(!row.contains("cd packages/api"))
  }

  @Test(
    "a value a build file states stays over a CI command, and a root CI command never lands on a nested area — catches mining that overwrites found values or misattributes"
  )
  func foundValuesStayAndRootCommandsStayAtRoot() throws {
    let tree = try fixtureTree("pocketbase-pocketbase")
    let reader = ScriptedReader { _ in
      [
        area(
          name: "core", root: ".", language: .go, kind: .go, source: "go.mod",
          commands: [
            .test: Sourced(value: "go test -count=1 ./...", source: "go.mod", confidence: .found)
          ]),
        area(
          name: "ui", root: "ui", language: .javascript, kind: .node, source: "ui/package.json",
          missing: [.lint: "no lint script"]),
      ]
    }

    let proposal = Discover.propose(tree: tree, head: "abc", dirty: [], readers: [reader])

    let core = try #require(proposal.areas.first { $0.name == "core" })
    #expect(core.commands[.test]?.value == "go test -count=1 ./...")
    #expect(
      core.commands[.lint] == Sourced(value: "make lint", source: "Makefile", confidence: .found))
    let ui = try #require(proposal.areas.first { $0.name == "ui" })
    #expect(ui.commands[.lint] == nil)
    #expect(ui.missing[.lint] == "no lint script")
    #expect(
      ui.commands[.build]
        == Sourced(
          value: "npm run build", source: ".github/workflows/release.yaml",
          confidence: .found))
  }

  @Test(
    "a CI command that changes into an area or points a directory flag at it is rebased onto the area root — catches mined commands that fail where the runner runs them"
  )
  func minedCommandsRebaseOntoAreaRoot() throws {
    let tree = try fixtureTree("tauri-apps-tauri")
    let areas = [
      area(
        name: "cli-js", root: "packages/cli", language: .javascript, kind: .node,
        source: "packages/cli/package.json"),
      area(
        name: "tauri-cli", root: "crates/tauri-cli", language: .rust, kind: .cargo,
        source: "crates/tauri-cli/Cargo.toml"),
    ]

    let mined = CICommandMining.commands(in: tree, areas: areas)

    let cliTests = mined.filter {
      $0.area == "cli-js" && $0.step == .test && $0.source == ".github/workflows/test-cli-js.yml"
    }
    #expect(cliTests.map(\.command) == ["pnpm test"])
    #expect(cliTests.map(\.confidence) == [.found])
    let cargoBuilds = mined.filter {
      $0.area == "tauri-cli" && $0.source == ".github/workflows/docker.yml"
    }
    #expect(cargoBuilds.map(\.command) == ["cargo build"])
    #expect(
      mined.allSatisfy { !$0.command.hasPrefix("cd packages") && !$0.command.hasPrefix("cd ./") })
  }

  @Test(
    "a CI command that reaches an area only by package name stays as run from the repository root, guessed, with a source note — catches a root command passed off as runnable in the area"
  )
  func unrebasableCommandStaysAtRepositoryRoot() throws {
    let tree = try fixtureTree("pola-rs-polars")
    let reader = ScriptedReader { _ in
      [
        area(
          name: "polars", root: "crates/polars", language: .rust, kind: .cargo,
          source: "crates/polars/Cargo.toml", missing: [.test: "none found"])
      ]
    }

    let mined = CICommandMining.commands(in: tree, areas: reader.areas(in: tree))
    let polars = try #require(
      Discover.propose(tree: tree, head: "abc", dirty: [], readers: [reader]).areas.first)

    let named = try #require(
      mined.first { $0.command.hasSuffix("cargo test --all-features -p polars --test it") })
    #expect(named.command == "cd ../.. && cargo test --all-features -p polars --test it")
    #expect(named.confidence == .guessed)
    #expect(
      named.source == ".github/workflows/test-rust.yml (runs from the repository root)")
    let test = try #require(polars.commands[.test])
    #expect(test.confidence == .guessed)
    #expect(test.value.hasPrefix("cd ../.. && "))
    #expect(polars.missing[.test] == nil)
  }

  @Test(
    "a mined command fills a missing step and clears its missing line — catches a step both commanded and missing"
  )
  func minedCommandFillsMissing() throws {
    let tree = try fixtureTree("pocketbase-pocketbase")
    let reader = ScriptedReader { _ in
      [area(name: "core", root: ".", kind: .go, source: "go.mod", missing: [.test: "none found"])]
    }

    let core = try #require(
      Discover.propose(tree: tree, head: "abc", dirty: [], readers: [reader]).areas.first)

    #expect(core.commands[.test]?.source == ".github/workflows/release.yaml")
    #expect(core.commands[.test]?.value == "go test ./...")
    #expect(core.missing[.test] == nil)
  }

  @Test(
    "the largest captured fixture proposes in under 5 s with every reader and the miner — catches a discover that misses its budget on a large tree"
  )
  func largestFixtureWithinBudget() throws {
    let tree = try fixtureTree("ggml-org-llama.cpp")
    let readers =
      EcosystemReaders.all + [
        BuildFileReader(names: ["CMakeLists.txt", "pyproject.toml", "Package.swift"])
      ]
    let clock = ContinuousClock()

    let start = clock.now
    let proposal = Discover.propose(tree: tree, head: "abc", dirty: [], readers: readers)
    let elapsed = clock.now - start

    #expect(tree.paths.count > 3_000)
    #expect(proposal.areas.count >= 3)
    #expect(elapsed < .seconds(5), "proposed in \(elapsed)")
  }

  @Test(
    "2 readers proposing the same area name get distinct names, so the config they write loads — catches a duplicate name failing config.toml"
  )
  func duplicateNamesAreMadeDistinct() {
    let tree = TrackedTreeSnapshot(files: [:])
    let first = ScriptedReader { _ in
      [area(name: "app", root: "App", kind: .swiftpm, source: "App/Package.swift")]
    }
    let second = ScriptedReader { _ in
      [area(name: "app", root: "app", kind: .node, source: "app/package.json")]
    }

    let names = Discover.propose(tree: tree, head: "abc", dirty: [], readers: [first, second])
      .areas.map(\.name)

    #expect(names.count == 2)
    #expect(Set(names).count == 2)
    #expect(names.first == "app")
  }

  @Test(
    "--set records the orchestrator as source and --drop leaves the step missing with its reason — catches an edit that loses who made it"
  )
  func editsSetAndDrop() throws {
    let proposal = DiscoverProposal(
      head: "abc",
      areas: [
        area(
          name: "web", root: "web", kind: .node, source: "web/package.json",
          commands: [
            .lint: Sourced(value: "npx eslint .", source: "web/package.json", confidence: .guessed),
            .build: Sourced(value: "npm run build", source: "web/package.json", confidence: .found),
          ],
          missing: [.test: "no test script"])
      ], dirty: [])
    let edits = try DiscoverEdit.parse(
      sets: ["web.test=npm --prefix web test -- {tests}"], drops: ["web.build"],
      reason: "build needs a private registry")

    let result = try Discover.applying(carried: [], new: edits, to: proposal)

    let web = try #require(result.proposal.areas.first)
    #expect(
      web.commands[.test]
        == Sourced(
          value: "npm --prefix web test -- {tests}", source: DiscoverEdit.orchestratorSource,
          confidence: .orchestrator))
    #expect(web.missing[.test] == nil)
    #expect(web.commands[.build] == nil)
    #expect(web.missing[.build] == "build needs a private registry")
    #expect(web.commands[.lint]?.confidence == .guessed)
    #expect(result.applied.count == 2)
    #expect(
      DiscoverRunEvent(proposal: result.proposal, milliseconds: 1, edited: result.applied.count)
        .edited == 2)
  }

  @Test(
    "a new edit replaces a carried one for the same step, and a carried edit whose area is gone is reported stale — catches a rediscovery losing or misapplying the orchestrator's fixes"
  )
  func carriedEdits() throws {
    let proposal = DiscoverProposal(
      head: "abc", areas: [area(name: "web", root: "web", kind: .node, source: "web/package.json")],
      dirty: [])
    let carried = [
      DiscoverEdit(area: "web", step: .lint, change: .set(command: "old lint")),
      DiscoverEdit(area: "web", step: .test, change: .set(command: "npm test")),
      DiscoverEdit(area: "gone", step: .test, change: .drop(reason: "removed")),
    ]
    let new = [DiscoverEdit(area: "web", step: .lint, change: .set(command: "new lint"))]

    let result = try Discover.applying(carried: carried, new: new, to: proposal)

    let web = try #require(result.proposal.areas.first)
    #expect(web.commands[.lint]?.value == "new lint")
    #expect(web.commands[.test]?.value == "npm test")
    #expect(result.applied.count == 2)
    #expect(result.stale == [carried[2]])
  }

  @Test("a new edit naming an unknown area fails naming it — catches a typo silently ignored")
  func unknownAreaFails() {
    let proposal = DiscoverProposal(head: "abc", areas: [], dirty: [])
    #expect(throws: DiscoverEditError.unknownArea("wbe")) {
      try Discover.applying(
        carried: [], new: [DiscoverEdit(area: "wbe", step: .lint, change: .set(command: "x"))],
        to: proposal)
    }
  }

  @Test(
    "the edit parser rejects a drop with no reason, a set with no command, generate, an unknown step and a step edited twice — catches an edit the config can't hold",
    arguments: [
      ([String](), ["web.lint"], String?.none, DiscoverEditError.dropNeedsReason),
      (["web.lint"], [], nil, .malformedSet("web.lint")),
      (["web.lint="], [], nil, .malformedSet("web.lint=")),
      (["web.generate=xcodegen"], [], nil, .stepHasNoKey(.generate)),
      (["web.lnt=x"], [], nil, .unknownStep("lnt")),
      ([], ["web"], "r", .malformedDrop("web")),
      (["web.lint=x"], ["web.lint"], "r", .conflicting("web.lint")),
    ])
  func parseRejects(sets: [String], drops: [String], reason: String?, error: DiscoverEditError) {
    #expect(throws: error) {
      try DiscoverEdit.parse(sets: sets, drops: drops, reason: reason)
    }
  }

  @Test(
    "the edit parser splits the area at the step's dot and keeps every = in the command — catches a command cut at its first ="
  )
  func parseKeepsCommand() throws {
    let edits = try DiscoverEdit.parse(
      sets: ["api.v2.test=pytest -k 'a=b'"], drops: [], reason: nil)
    #expect(
      edits == [DiscoverEdit(area: "api.v2", step: .test, change: .set(command: "pytest -k 'a=b'"))]
    )
  }

  @Test(
    "a rediscovery keeps the existing allow entries, settings and presets and takes its areas from the proposal — catches discover --apply wiping a waiver"
  )
  func configKeepsExisting() {
    let allow = BrownfieldAllow(
      rule: "neutral.unsafe-shortcut", path: "api/x.py", lineSHA: String(repeating: "a", count: 64),
      reason: "checked by the parser")
    let existing = BrownfieldConfig(
      brownfield: BrownfieldSettings(
        discoveredAt: "old", sliceBudgetSeconds: 45, timeBudgetMinutes: 90, sensitive: ["auth/**"]),
      areas: [
        BrownfieldArea(
          name: "stale", root: "stale", language: .go, kind: .go, test: "go test", testFiles: nil,
          lint: nil, build: nil, e2e: nil, testGlobs: [], packs: [], xcode: nil)
      ], allow: [allow], buildPresets: ["brownfield": Discover.brownfieldPreset])
    let proposal = DiscoverProposal(
      head: "new",
      areas: [
        area(
          name: "web", root: "web", kind: .node, source: "web/package.json",
          commands: [
            .test: Sourced(value: "npm test", source: "web/package.json", confidence: .found)
          ])
      ], dirty: [])

    let config = Discover.config(from: proposal, keeping: existing)

    #expect(config.brownfield.discoveredAt == "new")
    #expect(config.brownfield.sliceBudgetSeconds == 45)
    #expect(config.brownfield.timeBudgetMinutes == 90)
    #expect(config.brownfield.sensitive == ["auth/**"])
    #expect(config.allow == [allow])
    #expect(config.areas.map(\.name) == ["web"])
    #expect(config.areas.first?.test == "npm test")
  }

  @Test(
    "a first discovery writes the brownfield preset and the default slice budget — catches a clone with no preset for build start"
  )
  func configFresh() {
    let config = Discover.config(
      from: DiscoverProposal(head: "abc", areas: [], dirty: []), keeping: nil)

    #expect(config.brownfield.discoveredAt == "abc")
    #expect(config.brownfield.sliceBudgetSeconds == 30)
    #expect(config.buildPresets["brownfield"] == Discover.brownfieldPreset)
    #expect(Discover.brownfieldPreset.taskGate == .tier(.slice))
    #expect(Discover.brownfieldPreset.taskProof == .prove)
  }

  @Test(
    "the table prints a row per value with source and confidence, the inclusion of an Xcode area, and a missing line per step — catches a proposal printed without its provenance"
  )
  func tableRows() {
    let proposal = DiscoverProposal(
      head: "abc",
      areas: [
        area(
          name: "api", root: "api", language: .python, kind: .python, source: "api/pyproject.toml",
          commands: [
            .test: Sourced(
              value: "pytest api/tests", source: "api/pyproject.toml", confidence: .found)
          ], missing: [.lint: "no linter configured"]),
        ProposedArea(
          name: "app", root: "App", language: .swift, kind: .xcode, source: "App/Project.swift",
          commands: [:], missing: [:], testGlobs: [],
          xcode: Sourced(
            value: XcodeAreaConfig(
              workspace: "App/App.xcworkspace", project: nil, inclusion: .tuist,
              manifest: "App/Project.swift", schemes: ["App"]), source: "App/Project.swift",
            confidence: .found), generatedProjectTracked: false),
      ], dirty: [])

    let lines = ProposalTable.render(proposal, milliseconds: 1_800, appliedTo: "/c/config.toml")
      .split(separator: "\n").map(String.init)

    #expect(lines.first == "swiftgate discover · 2 areas · 1.8s · applied to /c/config.toml")
    #expect(lines.contains { $0.hasPrefix("area ") && $0.contains("confidence") })
    let test = lines.first { $0.hasPrefix("api ") && $0.contains("pytest api/tests") }
    #expect(test?.contains("api/pyproject.toml") == true)
    #expect(test?.hasSuffix("found") == true)
    let inclusion = lines.first { $0.hasPrefix("app ") && $0.contains("inclusion") }
    #expect(inclusion?.contains("tuist (manifest App/Project.swift)") == true)
    #expect(lines.last == "missing: api lint (no linter configured)")
  }

  @Test(
    "last.json round-trips a proposal with its sources, confidences, missing reasons and edits — catches the warm-up reading back a different proposal"
  )
  func recordRoundTrip() throws {
    let proposal = DiscoverProposal(
      head: "abc",
      areas: [
        ProposedArea(
          name: "app", root: "App", language: .swift, kind: .xcode, source: "App/project.yml",
          commands: [
            .build: Sourced(
              value: "xcodebuild build", source: "App/project.yml", confidence: .guessed),
            .test: Sourced(value: "make test", source: "Makefile", confidence: .orchestrator),
          ], missing: [.lint: "none"], testGlobs: ["App/Tests/**"],
          xcode: Sourced(
            value: XcodeAreaConfig(
              workspace: nil, project: "App/App.xcodeproj", inclusion: .xcodegen,
              manifest: "App/project.yml", schemes: ["App"]), source: "App/project.yml",
            confidence: .found), generatedProjectTracked: true)
      ], dirty: ["notes.txt"])
    let edits = [DiscoverEdit(area: "app", step: .test, change: .set(command: "make test"))]

    let data = try JSONEncoder().encode(DiscoverRecord(proposal: proposal, edits: edits))
    let decoded = try JSONDecoder().decode(DiscoverRecord.self, from: data)

    #expect(decoded.proposal == proposal)
    #expect(decoded.edits == edits)
  }
}
