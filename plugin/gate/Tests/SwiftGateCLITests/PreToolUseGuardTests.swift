import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Replays the recorded Write payloads against a probe repository with real plan state on disk,
/// so path resolution and lock reads run against the filesystem the live hook sees.
struct PlanStateScenario {
  static let session = "8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f"
  static let recordedPath = "\"/REPO/.harness/plans/2026-09-24-counter/ledger.json\""
  static let planA = "2026-09-24-counter"
  static let planB = "2026-09-25-search"
  static let designA = "docs/counter/designs/offline.md"
  static let designB = "docs/search/designs/search.md"

  var harness: HookHarness
  /// Canonical, as `Git.commonDirectory()` reports it.
  let common: String
  let layout: PlanStateLayout

  init(gitFailure: GitError? = nil) throws {
    harness = try HookHarness()
    let commonURL = harness.root.appending(path: ".git", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: commonURL, withIntermediateDirectories: true)
    common = CanonicalPath.of(commonURL)
    layout = try PlanStateLayout(commonDirectory: common)
    harness.git = FakeGit(
      changed: [], mergeBase: "base", commonDirectory: common, failure: gitFailure)
    for (plan, design) in [(Self.planA, Self.designA), (Self.planB, Self.designB)] {
      try write(layout.plan(plan).ledgerFile, "{}\n")
      try writePlanFile(plan, design: design)
    }
    try write(layout.indexFile, "{}\n")
    try harness.repository.write("docs/counter/designs/offline.md", "# Offline\n")
    try harness.repository.write("docs/counter/designs/offline.evidence/claims.jsonl", "")
    try harness.repository.write(Self.designB, "# Search\n")
    try harness.repository.write("docs/counter/designs/orphan.md", "# Orphan\n")
  }

  func writePlanFile(_ plan: String, design: String) throws {
    let file = PlanFile(
      schemaVersion: 1, slug: plan, design: design, designSha: "3f1c", approval: nil,
      clarifyChain: [], tier: .standard, resume: "planned")
    try write(
      layout.plan(plan).planFile, String(decoding: try PlanFileJSON.encode(file), as: UTF8.self))
  }

  var root: URL { harness.repository.root }

  func write(_ absolute: String, _ content: String) throws {
    let url = URL(filePath: absolute)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  func claim(_ plan: String, by session: String) throws {
    try write(try layout.plan(plan).orchestratorLock, session + "\n")
  }

  func symlink(_ relative: String, to destination: String) throws {
    let link = root.appending(path: relative)
    try FileManager.default.createDirectory(
      at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
  }

  /// `"deny"`, or `nil` when the call is left to the normal permission flow.
  func decision(
    _ filePath: String, subagent: Bool = false, cwd: URL? = nil
  ) async throws -> String? {
    try await output(filePath, subagent: subagent, cwd: cwd)?["permissionDecision"]
  }

  /// The denial's reason, or `nil` when the call is allowed.
  func reason(_ filePath: String) async throws -> String? {
    try await output(filePath)?["permissionDecisionReason"]
  }

  private func output(
    _ filePath: String, subagent: Bool = false, cwd: URL? = nil
  ) async throws -> [String: String]? {
    let (result, _) = try await harness.run(
      .preToolUse, subagent ? "pre-tool-use-write-ledger-subagent" : "pre-tool-use-write-ledger",
      cwd: cwd, replacing: [Self.recordedPath: "\"\(filePath)\""])
    guard result.stdout != nil else { return nil }
    return try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
  }

  /// Every file under the plans root with its contents.
  func planStateSnapshot() throws -> [String: String] {
    var snapshot: [String: String] = [:]
    let enumerator = FileManager.default.enumerator(atPath: layout.root)
    while let relative = enumerator?.nextObject() as? String {
      let path = layout.root + "/" + relative
      var isDirectory: ObjCBool = false
      FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      snapshot[relative] =
        isDirectory.boolValue ? "<dir>" : try String(contentsOfFile: path, encoding: .utf8)
    }
    return snapshot
  }
}

@Suite("PreToolUse plan state and design artifact guard")
struct PreToolUseGuardTests {
  @Test(
    "a subagent's writes to a design doc, its claims and amendments, a ledger, plan.json and the index are denied, even with the lock and the override — catches workers editing design or plan state"
  )
  func subagentDenied() async throws {
    var scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    scenario.harness.environment = [OrchestratorMarker.environmentVariable: "1"]
    let root = scenario.root.path
    let plan = try scenario.layout.plan(PlanStateScenario.planA)

    for path in [
      root + "/docs/counter/designs/offline.md",
      root + "/docs/counter/designs/offline.evidence/claims.jsonl",
      root + "/docs/counter/designs/offline.evidence/amendments.jsonl",
      plan.ledgerFile, plan.planFile, scenario.layout.indexFile,
    ] {
      #expect(try await scenario.decision(path, subagent: true) == "deny", "\(path)")
    }
  }

  @Test(
    "relative, dot-dot (lexical and physical), symlinked, dangling-symlink, case-variant, linked-worktree and sibling-worktree forms are denied like the canonical path — catches path-form bypass"
  )
  func pathFormsDenied() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    let root = scenario.root
    let designs = root.appending(path: "docs/counter/designs").path
    try FileManager.default.createDirectory(
      atPath: designs + "/sub", withIntermediateDirectories: true)
    try scenario.symlink("links/plans", to: scenario.layout.root)
    try scenario.symlink("links/designs", to: designs)
    try scenario.symlink("links/sub", to: designs + "/sub")
    try scenario.symlink("links/alias.md", to: designs + "/offline.md")
    try scenario.symlink("links/pending.md", to: designs + "/not-yet-written.md")
    try scenario.symlink("links/relative-plans", to: "../.git/swift-harness/plans")
    try scenario.symlink("docs/counter/designs/away", to: root.appending(path: "XUnitProbe").path)
    let sibling = root.appending(path: "worktrees/sibling-task")
    try FileManager.default.createDirectory(
      at: sibling.appending(path: "docs/counter/designs"), withIntermediateDirectories: true)
    let nested = root.appending(path: "XUnitProbe", directoryHint: .isDirectory)
    let upper = scenario.common.replacingOccurrences(of: "/.git", with: "/.GIT")

    let forms: [(path: String, cwd: URL?)] = [
      ("../.git/swift-harness/plans/2026-09-24-counter/ledger.json", nested),
      ("../docs/counter/designs/offline.md", nested),
      ("docs/counter/designs/offline.evidence/claims.jsonl", root),
      (root.path + "/XUnitProbe/../docs/counter/designs/offline.md", nil),
      (root.path + "/links/plans/2026-09-24-counter/ledger.json", nil),
      (root.path + "/links/relative-plans/index.json", nil),
      (root.path + "/links/designs/offline.md", nil),
      (root.path + "/links/sub/../offline.md", nil),
      (designs + "/away/../offline.md", nil),
      (root.path + "/links/alias.md", nil),
      (root.path + "/links/pending.md", nil),
      (upper + "/Swift-Harness/Plans/2026-09-24-COUNTER/Ledger.json", nil),
      (root.path + "/DOCS/Counter/Designs/Offline.MD", nil),
      (
        scenario.common + "/worktrees/task/../../swift-harness/plans/2026-09-24-counter/plan.json",
        nil
      ),
      (sibling.path + "/docs/counter/designs/offline.md", nil),
    ]
    for form in forms {
      #expect(
        try await scenario.decision(form.path, cwd: form.cwd) == "deny",
        "\(form.path) from \(form.cwd?.path ?? "the repository root")")
    }
  }

  @Test(
    "the lock holder may write its own plan by any path form, and nobody else's — catches session B rewriting plan A's ledger, or resolution sending the holder to the wrong lock"
  )
  func holderScoped() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    try scenario.claim(PlanStateScenario.planB, by: "another-session")
    try scenario.symlink("links/plans", to: scenario.layout.root)
    let planA = try scenario.layout.plan(PlanStateScenario.planA)
    let planB = try scenario.layout.plan(PlanStateScenario.planB)

    #expect(try await scenario.decision(planA.ledgerFile) == nil)
    #expect(try await scenario.decision(planA.planFile) == nil)
    #expect(
      try await scenario.decision(
        scenario.root.path + "/links/plans/2026-09-24-counter/ledger.json") == nil)
    #expect(try await scenario.decision(scenario.layout.indexFile) == nil)
    #expect(
      try await scenario.decision(scenario.root.path + "/docs/counter/designs/offline.md") == nil)
    #expect(try await scenario.decision(planB.ledgerFile) == "deny")
    #expect(try await scenario.decision(planB.planFile) == "deny")
    #expect(
      try await scenario.decision(
        scenario.root.path + "/links/plans/2026-09-25-search/ledger.json") == "deny")
  }

  @Test(
    "hand edits of orchestrator.lock are denied to the holder, the override and a new plan — catches a claim forged or stolen without swiftgate plan"
  )
  func lockFileDenied() async throws {
    var scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    scenario.harness.environment = [OrchestratorMarker.environmentVariable: "1"]

    for plan in [PlanStateScenario.planA, PlanStateScenario.planB, "2026-09-26-new"] {
      let lock = try scenario.layout.plan(plan).orchestratorLock
      #expect(try await scenario.decision(lock) == "deny", "\(plan)")
    }
  }

  @Test(
    "a main session with no claim is denied plan state and design artifacts, and the override lets it through — catches writes before a claim and a broken escape hatch"
  )
  func unclaimedAndOverride() async throws {
    var scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    let targets = [
      try scenario.layout.plan(PlanStateScenario.planA).ledgerFile, scenario.layout.indexFile,
      scenario.root.path + "/docs/counter/designs/offline.evidence/claims.jsonl",
    ]
    for target in targets {
      #expect(try await scenario.decision(target) == "deny", "\(target)")
    }
    scenario.harness.environment = [OrchestratorMarker.environmentVariable: "1"]
    for target in targets {
      #expect(try await scenario.decision(target) == nil, "\(target)")
    }
  }

  @Test(
    "when git can't name the common dir, a design write is denied despite a held lock — catches the guard failing open"
  )
  func gitFailureFailsClosed() async throws {
    let scenario = try PlanStateScenario(
      gitFailure: .unparseableOutput(command: "git rev-parse --git-common-dir", detail: "none"))
    defer { scenario.harness.repository.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)

    #expect(
      try await scenario.decision(scenario.root.path + "/docs/counter/designs/offline.md")
        == "deny")
  }

  @Test(
    "the guard reads locks and never writes plan state, allowed or denied — catches the guard claiming a plan as a side effect"
  )
  func neverWrites() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    let before = try scenario.planStateSnapshot()

    _ = try await scenario.decision(try scenario.layout.plan(PlanStateScenario.planA).ledgerFile)
    _ = try await scenario.decision(try scenario.layout.plan("2026-09-26-new").ledgerFile)
    _ = try await scenario.decision(scenario.layout.indexFile, subagent: true)
    _ = try await scenario.decision(scenario.root.path + "/docs/counter/designs/offline.md")

    #expect(try scenario.planStateSnapshot() == before)
  }

  @Test(
    "ordinary source edits pass and a guarded write is decided, fastest of 5 under 50ms — catches the guard blocking normal work or slowing every edit"
  )
  func ordinaryAndFast() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }

    #expect(
      try await scenario.decision(scenario.root.path + "/XUnitProbe/Sources/Probe/Probe.swift")
        == nil)
    #expect(try await scenario.decision(scenario.root.path + "/docs/plans/2026-09-25-x.md") == nil)

    // A fresh scenario per sample so every repeat decides against the same, untouched plan state.
    let samples = try await Latency.samples {
      let fresh = try PlanStateScenario()
      defer { fresh.harness.repository.remove() }
      let (_, milliseconds) = try await fresh.harness.run(
        .preToolUse, "pre-tool-use-write-ledger-subagent",
        replacing: [PlanStateScenario.recordedPath: "\"\(fresh.layout.indexFile)\""])
      return milliseconds
    }
    #expect(samples.min()! < 50, "ordinaryAndFast samples: \(samples)ms, budget: 50ms")
  }

  @Test(
    "a design and its evidence are writable only by the holder of the plan whose plan.json names it — catches plan A's holder editing plan B's design"
  )
  func designOwnedByNamingPlan() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    let root = scenario.root.path
    let designB = root + "/" + PlanStateScenario.designB
    let evidenceB = root + "/docs/search/designs/search.evidence/claims.jsonl"
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    try scenario.claim(PlanStateScenario.planB, by: "another-session")

    #expect(try await scenario.decision(designB) == "deny")
    #expect(try await scenario.decision(evidenceB) == "deny")
    #expect(try await scenario.reason(designB)?.contains(PlanStateScenario.planB) == true)

    try scenario.claim(PlanStateScenario.planA, by: "another-session")
    try scenario.claim(PlanStateScenario.planB, by: PlanStateScenario.session)
    try scenario.symlink("links/search", to: root + "/docs/search/designs")
    #expect(try await scenario.decision(designB) == nil)
    #expect(try await scenario.decision(evidenceB) == nil)
    #expect(try await scenario.decision(root + "/links/search/search.md") == nil)
    #expect(try await scenario.decision(root + "/" + PlanStateScenario.designA) == "deny")
  }

  @Test(
    "a design no plan names is denied to a lock holder with the claim hint, and the override allows it — catches unowned designs written by any holder"
  )
  func unnamedDesignDenied() async throws {
    var scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    let orphan = scenario.root.path + "/docs/counter/designs/orphan.md"
    let newDesign = scenario.root.path + "/docs/fresh/designs/fresh.md"

    for path in [orphan, newDesign] {
      #expect(try await scenario.decision(path) == "deny", "\(path)")
      #expect(
        try await scenario.reason(path)?.contains("swiftgate plan claim <slug>") == true, "\(path)")
    }
    scenario.harness.environment = [OrchestratorMarker.environmentVariable: "1"]
    #expect(try await scenario.decision(orphan) == nil)
    #expect(try await scenario.decision(newDesign) == nil)
  }

  @Test(
    "a holder whose plan.json is corrupt is denied its design — catches an unreadable plan.json failing open"
  )
  func corruptPlanFileDenied() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    try scenario.write(
      try scenario.layout.plan(PlanStateScenario.planA).planFile, "{\"design\": ")

    let design = scenario.root.path + "/" + PlanStateScenario.designA
    #expect(try await scenario.decision(design) == "deny")
    #expect(try await scenario.reason(design)?.contains("plan.json") == true)
  }
}
