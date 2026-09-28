import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
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
    let keptDesign = try scenario.planFileText(
      PlanStateScenario.planA, design: PlanStateScenario.designA)
    #expect(try await scenario.toolDecision(planA.planFile, writing: keptDesign) == nil)
    #expect(try await scenario.decision(planA.planFile) == "deny", "a plan.json that isn't one")
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

extension PlanStateScenario {
  /// The hook's decision on a Write (`content`) or Edit (`edit`) of `filePath` by the main
  /// session, from the recorded payload of that tool with its `tool_input` rewritten.
  func toolDecision(
    _ filePath: String, writing content: String? = nil,
    edit: (old: String, new: String, all: Bool)? = nil
  ) async throws -> String? {
    let fixture = edit == nil ? "pre-tool-use-write-ledger" : "pre-tool-use-edit-swift"
    var object = try #require(
      try JSONSerialization.jsonObject(with: harness.payload(fixture)) as? [String: Any])
    var input: [String: Any] = ["file_path": filePath]
    if let content { input["content"] = content }
    if let edit {
      input["old_string"] = edit.old
      input["new_string"] = edit.new
      input["replace_all"] = edit.all
    }
    object["tool_input"] = input
    let data = try JSONSerialization.data(withJSONObject: object)
    let dependencies = harness.dependencies
    let result = await HookRunner.run(.preToolUse, input: data) { _ in dependencies }
    guard result.stdout != nil else { return nil }
    let output = try harness.json(result)["hookSpecificOutput"] as? [String: String]
    return output?["permissionDecision"]
  }

  func planFileText(_ plan: String, design: String, tier: DesignTier = .standard) throws -> String {
    let file = PlanFile(
      schemaVersion: 1, slug: plan, design: design, designSha: "3f1c", approval: nil,
      clarifyChain: [], tier: tier, resume: "planned")
    return String(decoding: try PlanFileJSON.encode(file), as: UTF8.self)
  }
}

@Suite("PreToolUse sprint spec pages")
struct SprintPageWriteTests {
  static func sprints(_ scenario: PlanStateScenario) -> String {
    scenario.layout.root + "/" + PlanStateLayout.sprintsDirectoryName
  }

  @Test(
    "a main session holding no plan writes <plans>/sprints/<slug>.md with Write, and a subagent is denied it even with a lock and the override — catches the sprint skill's page write refused, or workers editing it"
  )
  func pageWritableByMainSessionOnly() async throws {
    var scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    let page = Self.sprints(scenario) + "/login-flow.md"

    #expect(try await scenario.decision(page) == nil)
    #expect(try await scenario.toolDecision(page, writing: "# Login flow\n") == nil)

    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    scenario.harness.environment = [OrchestratorMarker.environmentVariable: "1"]
    #expect(try await scenario.decision(page, subagent: true) == "deny")
  }

  @Test(
    "a nested path, a non-page file and the sprints directory's own name are denied to the main session, and a plan's files still need its lock — catches the page allowance widening past pages or unlocking plans"
  )
  func onlyPagesAllowed() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    try FileManager.default.createDirectory(
      atPath: Self.sprints(scenario) + "/existing", withIntermediateDirectories: true)
    try scenario.claim(PlanStateScenario.planB, by: PlanStateScenario.session)
    let planA = try scenario.layout.plan(PlanStateScenario.planA)

    for path in [
      Self.sprints(scenario) + "/login-flow/notes.md",
      Self.sprints(scenario) + "/login-flow.json",
      Self.sprints(scenario) + "/existing",
      Self.sprints(scenario),
      planA.directory + "/sprints/login-flow.md",
      planA.ledgerFile,
    ] {
      #expect(try await scenario.decision(path) == "deny", "\(path)")
    }
  }

  @Test(
    "plan claim refuses a plan named sprints and writes no lock — catches a plan taking the sprint pages' directory"
  )
  func claimSprintsRefused() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    let before = try scenario.planStateSnapshot()

    let design = "docs/counter/designs/orphan.md"
    for name in ["sprints", "Sprints"] {
      let report = await PlanLockRun.claim(
        slug: name, session: PlanStateScenario.session, design: design, root: scenario.root,
        git: scenario.harness.git)
      #expect(report.verdict == .blocked, "\(name)")
      #expect(report.message.contains("invalid plan name"), "\(report.message)")
    }
    #expect(try scenario.planStateSnapshot() == before)
    let control = await PlanLockRun.claim(
      slug: "sprints-2026", session: PlanStateScenario.session, design: design,
      root: scenario.root, git: scenario.harness.git)
    #expect(control.status == .claimed, "\(control.message)")
  }
}

@Suite("PreToolUse design ownership is exclusive")
struct DesignOwnershipHookTests {
  @Test(
    "a design two plans name is denied to both holders, naming both plans — catches plan B's holder co-owning plan A's design by naming it in its plan.json"
  )
  func sharedDesignDenied() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    try scenario.claim(PlanStateScenario.planA, by: "another-session")
    try scenario.claim(PlanStateScenario.planB, by: PlanStateScenario.session)
    try scenario.writePlanFile(PlanStateScenario.planB, design: PlanStateScenario.designA)
    let design = scenario.root.path + "/" + PlanStateScenario.designA

    #expect(try await scenario.decision(design) == "deny")
    let reason = try await scenario.reason(design)
    #expect(reason?.contains(PlanStateScenario.planA) == true, "\(reason ?? "")")
    #expect(reason?.contains(PlanStateScenario.planB) == true, "\(reason ?? "")")
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    #expect(try await scenario.decision(design) == "deny")
    #expect(
      try await scenario.decision(
        scenario.root.path + "/docs/counter/designs/offline.evidence/claims.jsonl") == "deny")
  }

  @Test(
    "the holder's Write or Edit of plan.json that repoints design is denied, and one that keeps it passes — catches a holder taking over another plan's design through its own plan.json"
  )
  func planFileRepointDenied() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    let planFile = try scenario.layout.plan(PlanStateScenario.planA).planFile
    let current = try String(contentsOfFile: planFile, encoding: .utf8)
    let planA = PlanStateScenario.planA

    let repointed = try scenario.planFileText(planA, design: PlanStateScenario.designB)
    #expect(try await scenario.toolDecision(planFile, writing: repointed) == "deny")
    let orphan = try scenario.planFileText(planA, design: "docs/counter/designs/orphan.md")
    #expect(try await scenario.toolDecision(planFile, writing: orphan) == "deny")
    #expect(try await scenario.toolDecision(planFile, writing: "{\"design\": ") == "deny")
    #expect(
      try await scenario.toolDecision(
        planFile,
        edit: (PlanStateScenario.designA, PlanStateScenario.designB, false)) == "deny")

    let retiered = try scenario.planFileText(planA, design: PlanStateScenario.designA, tier: .deep)
    #expect(try await scenario.toolDecision(planFile, writing: retiered) == nil)
    #expect(
      try await scenario.toolDecision(planFile, edit: ("\"planned\"", "\"reviewing\"", false))
        == nil)
    #expect(try String(contentsOfFile: planFile, encoding: .utf8) == current)
  }

  @Test(
    "a holder writing a missing or unreadable plan.json may name a design no other plan names, and not one another plan owns — catches repointing through a deleted plan.json"
  )
  func unreadablePlanFileNamesOnlyUnownedDesign() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    let planFile = try scenario.layout.plan(PlanStateScenario.planA).planFile
    try scenario.write(planFile, "{\"design\": ")
    let planA = PlanStateScenario.planA

    let owned = try scenario.planFileText(planA, design: PlanStateScenario.designB)
    #expect(try await scenario.toolDecision(planFile, writing: owned) == "deny")
    let unowned = try scenario.planFileText(planA, design: "docs/counter/designs/orphan.md")
    #expect(try await scenario.toolDecision(planFile, writing: unowned) == nil)
  }
}

@Suite("PreToolUse in a project nested below the git root")
struct NestedProjectDesignTests {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
  ]

  @Test(
    "in a project below the git root, `plan claim --design docs/…` lets the holder write that doc, and `evidence check` accepts the same value — catches the guard reading plan.json's design against the git toplevel while the other commands read it against the project"
  )
  func claimedDesignWritable() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let design = "docs/app/designs/offline.md"
    try repository.write("App/.swiftgate.toml", "")
    try repository.write("App/" + design, "# Offline\n")
    try repository.write("App/docs/app/designs/offline.evidence/claims.jsonl", "")
    let runner = LiveProcessRunner(baseEnvironment: Self.environment)
    let initialized = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["init", "-q"], workingDirectory: repository.root.path,
        timeout: .seconds(30)))
    #expect(initialized.status.isSuccess)
    let project = repository.root.appending(path: "App", directoryHint: .isDirectory)
    let git = LiveGit(runner: runner, repositoryRoot: project.path)

    let claim = await PlanLockRun.claim(
      slug: "2026-09-26-offline", session: PlanStateScenario.session, design: design, git: git)
    #expect(claim.verdict == .green, "\(claim.message)")
    let evidence = await EvidenceCheckRun.run(
      options: .init(design: design, at: nil, packageResolved: "Package.resolved", sdk: nil),
      root: project, runner: runner)
    #expect(evidence == .checked(claims: [], results: []))

    var text = try Fixture.text("Hooks/pre-tool-use-write-ledger.json")
    text = text.replacingOccurrences(
      of: PlanStateScenario.recordedPath, with: "\"\(project.path)/\(design)\"")
    text = text.replacingOccurrences(of: "\"/REPO", with: "\"\(project.path)")
    let dependencies = HookDependencies(
      git: git, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
      formatter: FakeSwiftFormatter(), xcode: FixedXcode(version: "26.2"),
      sweep: PendingOrphanCloneSweep(), commitJudge: DisabledCommitCommentJudge(),
      environment: [:])
    let result = await HookRunner.run(.preToolUse, input: Data(text.utf8)) { _ in dependencies }
    #expect(result.stdout == nil, "\(result.stdout ?? "")")
  }
}

/// Counts `git rev-parse --git-common-dir` calls on their way to a real runner, which is how a
/// test tells a warm plan-lock cache from a fresh read.
private final class CommonDirectoryCallCounter: ProcessRunner {
  private let runner: LiveProcessRunner
  private let calls = Mutex(0)

  init(runner: LiveProcessRunner) { self.runner = runner }

  var count: Int { calls.withLock { $0 } }

  func run(_ invocation: ProcessInvocation) async throws(ProcessRunnerError) -> ProcessOutput {
    if invocation.arguments.contains("--git-common-dir") { calls.withLock { $0 += 1 } }
    return try await runner.run(invocation)
  }
}

/// A real repository with a linked worktree from `git worktree add`, whose every payload names
/// the worktree through a symlinked alias, and plan state in the real git common dir.
private struct CachedGuardScenario {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]
  static let holder = "session-holder"
  static let other = "session-other"
  /// The same length as `designA`, so a repointed `plan.json` keeps its size.
  static let designC = "docs/counter/designs/online2.md"
  static let designZ = "docs/zed/designs/zed.md"
  static let planC = "2026-09-26-zed"

  let base: URL
  let worktree: URL
  /// ``worktree`` spelled through a symlink.
  let aliased: URL
  let layout: PlanStateLayout
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)
  let counter: CommonDirectoryCallCounter

  init() async throws {
    base = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-cached-guard-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    let real = base.appending(path: "real", directoryHint: .isDirectory)
    let alias = base.appending(path: "alias", directoryHint: .isDirectory)
    let main = real.appending(path: "app", directoryHint: .isDirectory)
    worktree = real.appending(path: "app-task", directoryHint: .isDirectory)
    aliased = alias.appending(path: "app-task", directoryHint: .isDirectory)
    counter = CommonDirectoryCallCounter(runner: runner)
    for (path, content) in [
      (ConfigLoader.fileName, ProbeRepository.config), (PlanStateScenario.designA, "# Offline\n"),
      (PlanStateScenario.designB, "# Search\n"), (Self.designC, "# Online\n"),
      (Self.designZ, "# Zed\n"),
    ] {
      try Self.write(main.appending(path: path).path, content)
    }
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    for arguments in [
      ["init", "-q", "-b", "main"], ["add", "-A"], ["commit", "-q", "-m", "base"],
      ["worktree", "add", "-q", "-b", "task", worktree.path],
    ] {
      let output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: main.path,
          timeout: .seconds(30)))
      #expect(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    }
    layout = try PlanStateLayout(
      commonDirectory: try await LiveGit(runner: runner, repositoryRoot: worktree.path)
        .commonDirectory())
    for (plan, design) in [
      (PlanStateScenario.planA, PlanStateScenario.designA),
      (PlanStateScenario.planB, PlanStateScenario.designB),
    ] {
      try writePlanFile(plan, design: design)
    }
  }

  func remove() { try? FileManager.default.removeItem(at: base) }

  static func write(_ absolute: String, _ content: String) throws {
    let url = URL(filePath: absolute)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  func writePlanFile(_ plan: String, design: String) throws {
    let file = PlanFile(
      schemaVersion: 1, slug: plan, design: design, designSha: "3f1c", approval: nil,
      clarifyChain: [], tier: .standard, resume: "planned")
    try Self.write(
      layout.plan(plan).planFile, String(decoding: try PlanFileJSON.encode(file), as: UTF8.self))
  }

  func claim(_ plan: String, by session: String) throws {
    try Self.write(try layout.plan(plan).orchestratorLock, session + "\n")
  }

  func release(_ plan: String) throws {
    try FileManager.default.removeItem(atPath: try layout.plan(plan).orchestratorLock)
  }

  func cacheFile(_ session: String) -> URL {
    worktree.appending(path: ".harness/hook-state/plan-lock-cache-\(session).json")
  }

  /// A Write of `design` (relative to the checkout) by `session`, as the hook reads it from stdin.
  func payload(_ design: String, session: String) throws -> Data {
    var text = try Fixture.text("Hooks/pre-tool-use-write-ledger.json")
    text = text.replacingOccurrences(
      of: "\"session_id\": \"\(PlanStateScenario.session)\"",
      with: "\"session_id\": \(String(decoding: try JSONEncoder().encode(session), as: UTF8.self))")
    text = text.replacingOccurrences(
      of: PlanStateScenario.recordedPath, with: "\"\(aliased.path)/\(design)\"")
    text = text.replacingOccurrences(of: "\"/REPO", with: "\"\(aliased.path)")
    return Data(text.utf8)
  }

  /// The hook's `hookSpecificOutput`, or `nil` when it leaves the write to the normal flow.
  func decide(_ design: String, session: String) async throws -> [String: String]? {
    let input = try payload(design, session: session)
    let counter = self.counter
    let result = await HookRunner.run(.preToolUse, input: input) { root in
      HookDependencies(
        git: LiveGit(runner: counter, repositoryRoot: root.path),
        swiftPM: FakeSwiftPM(serving: []), formatter: FakeSwiftFormatter(),
        xcode: FixedXcode(version: "26.2"), sweep: PendingOrphanCloneSweep(),
        commitJudge: DisabledCommitCommentJudge(), environment: [:])
    }
    guard let stdout = result.stdout else { return nil }
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
    return try #require(json["hookSpecificOutput"] as? [String: String])
  }

  func decision(_ design: String, session: String) async throws -> String? {
    try await decide(design, session: session)?["permissionDecision"]
  }
}

@Suite("PreToolUse guard with a warm plan-lock cache")
struct PreToolUseGuardCacheTests {
  fileprivate typealias Scenario = CachedGuardScenario

  @Test(
    "a lock released and re-acquired by another holder between hook calls decides each next write while git is asked once per session — catches a warm cache letting through a write a fresh lock read denies"
  )
  func lockChangesSeenThroughWarmCache() async throws {
    let scenario = try await CachedGuardScenario()
    defer { scenario.remove() }
    let design = PlanStateScenario.designA
    try scenario.claim(PlanStateScenario.planA, by: Scenario.holder)

    #expect(try await scenario.decide(design, session: Scenario.holder) == nil)
    #expect(try await scenario.decide(design, session: Scenario.holder) == nil)
    try scenario.release(PlanStateScenario.planA)
    #expect(try await scenario.decision(design, session: Scenario.holder) == "deny")
    try scenario.claim(PlanStateScenario.planA, by: Scenario.other)
    #expect(try await scenario.decision(design, session: Scenario.holder) == "deny")
    #expect(try await scenario.decide(design, session: Scenario.other) == nil)
    try scenario.release(PlanStateScenario.planA)
    try scenario.claim(PlanStateScenario.planA, by: Scenario.holder)
    #expect(try await scenario.decide(design, session: Scenario.holder) == nil)
    #expect(try await scenario.decision(design, session: Scenario.other) == "deny")

    #expect(scenario.counter.count == 2)
  }

  @Test(
    "the holder of plan A writing plan B's design is denied with a warm cache, claimed or not — catches a cached answer granting one plan's lock over another plan's design"
  )
  func crossPlanDeniedWithWarmCache() async throws {
    let scenario = try await CachedGuardScenario()
    defer { scenario.remove() }
    try scenario.claim(PlanStateScenario.planA, by: Scenario.holder)
    try scenario.claim(PlanStateScenario.planB, by: Scenario.other)

    #expect(try await scenario.decide(PlanStateScenario.designA, session: Scenario.holder) == nil)
    let denied = try await scenario.decide(PlanStateScenario.designB, session: Scenario.holder)
    #expect(denied?["permissionDecision"] == "deny")
    #expect(denied?["permissionDecisionReason"]?.contains(PlanStateScenario.planB) == true)
    try scenario.release(PlanStateScenario.planB)
    #expect(
      try await scenario.decision(PlanStateScenario.designB, session: Scenario.holder) == "deny")

    #expect(scenario.counter.count == 1)
  }

  @Test(
    "a plan.json repointed to another design of the same size after the cache warms is judged on the new design — catches a cached plan.json design"
  )
  func repointedDesignSeen() async throws {
    let scenario = try await CachedGuardScenario()
    defer { scenario.remove() }
    try scenario.claim(PlanStateScenario.planA, by: Scenario.holder)
    #expect(try await scenario.decide(PlanStateScenario.designA, session: Scenario.holder) == nil)

    try scenario.writePlanFile(PlanStateScenario.planA, design: Scenario.designC)

    #expect(
      try await scenario.decision(PlanStateScenario.designA, session: Scenario.holder) == "deny")
    #expect(try await scenario.decide(Scenario.designC, session: Scenario.holder) == nil)
    #expect(scenario.counter.count == 1)
  }

  @Test(
    "a plan created and claimed after the cache warms owns its design on the next call — catches a cached plans listing"
  )
  func planCreatedAfterWarmingSeen() async throws {
    let scenario = try await CachedGuardScenario()
    defer { scenario.remove() }
    #expect(try await scenario.decision(Scenario.designZ, session: Scenario.holder) == "deny")

    try scenario.writePlanFile(Scenario.planC, design: Scenario.designZ)
    try scenario.claim(Scenario.planC, by: Scenario.holder)

    #expect(try await scenario.decide(Scenario.designZ, session: Scenario.holder) == nil)
    #expect(scenario.counter.count == 1)
  }

  @Test(
    "a corrupt cache file gives the verdict a fresh read gives, with a note naming the file — catches a corrupt cache allowing silently or changing the verdict"
  )
  func corruptCacheSameVerdictWithNote() async throws {
    let scenario = try await CachedGuardScenario()
    defer { scenario.remove() }
    try scenario.claim(PlanStateScenario.planA, by: Scenario.holder)
    #expect(try await scenario.decide(PlanStateScenario.designA, session: Scenario.holder) == nil)
    let file = scenario.cacheFile(Scenario.holder)

    try Data("{\"schemaVersion\":".utf8).write(to: file)
    let denied = try await scenario.decide(PlanStateScenario.designB, session: Scenario.holder)
    #expect(denied?["permissionDecision"] == "deny")
    #expect(denied?["permissionDecisionReason"]?.contains(file.lastPathComponent) == true)

    try Data("not json".utf8).write(to: file)
    let allowed = try await scenario.decide(PlanStateScenario.designA, session: Scenario.holder)
    #expect(allowed?["permissionDecision"] == nil)
    #expect(allowed?["additionalContext"]?.contains(file.lastPathComponent) == true)

    #expect(try await scenario.decide(PlanStateScenario.designA, session: Scenario.holder) == nil)
    #expect(scenario.counter.count == 3)
  }

  @Test(
    "session B never reads session A's cache file — catches one session's cache deciding another's writes"
  )
  func sessionsNeverShareCache() async throws {
    let scenario = try await CachedGuardScenario()
    defer { scenario.remove() }
    try scenario.claim(PlanStateScenario.planA, by: Scenario.holder)
    try scenario.claim(PlanStateScenario.planB, by: Scenario.other)
    #expect(try await scenario.decide(PlanStateScenario.designA, session: Scenario.holder) == nil)
    try Data("{garbage".utf8).write(to: scenario.cacheFile(Scenario.holder))

    #expect(try await scenario.decide(PlanStateScenario.designB, session: Scenario.other) == nil)
    #expect(FileManager.default.fileExists(atPath: scenario.cacheFile(Scenario.other).path))
    #expect(
      try String(contentsOf: scenario.cacheFile(Scenario.holder), encoding: .utf8) == "{garbage")
  }

  @Test(
    "a session id with `/` or `..` names no cache file, reads plan state fresh and says so — catches a session id writing outside the hook-state directory"
  )
  func unsafeSessionNamesNoCachePath() async throws {
    let scenario = try await CachedGuardScenario()
    defer { scenario.remove() }
    for session in ["../../escape", "a/b", ".."] {
      try scenario.claim(PlanStateScenario.planA, by: session)
      let output = try await scenario.decide(PlanStateScenario.designA, session: session)
      #expect(output?["permissionDecision"] == nil, "\(session)")
      #expect(output?["additionalContext"]?.contains("plan-lock cache is off") == true)
      #expect(
        try await scenario.decision(PlanStateScenario.designB, session: session) == "deny")
    }
    let state = scenario.worktree.appending(path: ".harness")
    let written = FileManager.default.enumerator(atPath: state.path)?.allObjects as? [String]
    #expect((written ?? []).allSatisfy { !$0.contains("escape") && !$0.contains("plan-lock") })
    #expect(!FileManager.default.fileExists(atPath: scenario.base.appending(path: "escape").path))
  }

  @Test(
    "12 real hook processes racing on one session's empty cache each decide correctly, across a release and a re-claim, and leave a cache the next call trusts — catches a torn or interleaved cache write"
  )
  func racingHookProcessesStayCorrect() async throws {
    let scenario = try await CachedGuardScenario()
    defer { scenario.remove() }
    let binary = Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path
    let runner = scenario.runner
    let profiles = scenario.base.appending(path: "swiftgate-%p.profraw").path
    try scenario.claim(PlanStateScenario.planA, by: Scenario.holder)

    for round in 0..<3 {
      if round == 1 { try scenario.release(PlanStateScenario.planA) }
      if round == 2 { try scenario.claim(PlanStateScenario.planA, by: Scenario.holder) }
      if round > 0 { try FileManager.default.removeItem(at: scenario.cacheFile(Scenario.holder)) }
      let inputs = try (0..<12).map { index in
        let design = index.isMultiple(of: 2) ? PlanStateScenario.designA : PlanStateScenario.designB
        return (design, try scenario.payload(design, session: Scenario.holder))
      }
      let outcomes = try await withThrowingTaskGroup(of: (String, String).self) { group in
        for (design, input) in inputs {
          group.addTask {
            let output = try await runner.run(
              ProcessInvocation(
                executable: binary, arguments: ["hook", "pre-tool-use"],
                environmentOverlay: ["LLVM_PROFILE_FILE": profiles],
                workingDirectory: scenario.base.path, standardInput: input,
                timeout: .seconds(60)))
            return (design, output.stdout.text)
          }
        }
        return try await group.reduce(into: []) { $0.append($1) }
      }
      for (design, stdout) in outcomes {
        let allowed = design == PlanStateScenario.designA && round != 1
        #expect(
          stdout.contains("\"deny\"") == !allowed, "round \(round), \(design): \(stdout)")
        #expect(!stdout.contains("plan-lock cache"), "round \(round): \(stdout)")
      }
    }

    #expect(try await scenario.decide(PlanStateScenario.designA, session: Scenario.holder) == nil)
    #expect(scenario.counter.count == 0)
  }
}
