import SwiftGateDomain
import Testing

@Suite("Plan state and design artifact guard")
struct PlanStateGuardTests {
  static let common = "/r/.git"
  static func layout() throws -> PlanStateLayout { try PlanStateLayout(commonDirectory: common) }
  static func feed() throws -> PlanStateLayout.Plan { try layout().plan("2026-09-24-feed") }
  static let doc = "/r/docs/feed/designs/offline.md"
  static let owners = [
    PlanStateGuard.PlanRecord(name: "a", lock: "session-a", design: .named(doc))
  ]

  static func guardedTargets() throws -> [PlanStateGuard.Target] {
    [.planFile(try feed()), .sharedPlanFile(try layout()), .designArtifact(document: doc)]
  }

  @Test(
    "files in a plan directory address that plan, in any letter case — catches a case-variant path slipping past on case-insensitive APFS",
    arguments: [
      "/r/.git/swift-harness/plans/2026-09-24-feed/ledger.json",
      "/r/.git/swift-harness/plans/2026-09-24-feed/plan.json",
      "/r/.git/Swift-Harness/PLANS/2026-09-24-feed/Ledger.JSON",
      "/r/.git/swift-harness/plans/2026-09-24-feed/notes/extra.json",
    ])
  func planFiles(path: String) throws {
    guard case .planFile(let plan)? = PlanStateGuard.target(ofResolvedPath: path) else {
      Issue.record("\(path) was not classified as a plan file")
      return
    }
    let expected = try Self.feed().directory
    #expect(plan.directory.lowercased() == expected.lowercased())
  }

  @Test(
    "the index and other files directly under the plans root are shared plan state — catches the index left writable by workers",
    arguments: [
      "/r/.git/swift-harness/plans/index.json", "/r/.git/swift-harness/plans/INDEX.json",
      "/r/.git/swift-harness/plans/stray.json",
    ])
  func sharedFiles(path: String) throws {
    guard case .sharedPlanFile(let layout)? = PlanStateGuard.target(ofResolvedPath: path) else {
      Issue.record("\(path) was not classified as shared plan state")
      return
    }
    let expected = try Self.layout().root
    #expect(layout.root.lowercased() == expected.lowercased())
  }

  @Test(
    "orchestrator.lock and the claim and index lock files are lock targets wherever they sit under a plans root — catches a hand-written claim or a lock file a holder deletes to race a claim",
    arguments: [
      "/r/.git/swift-harness/plans/2026-09-24-feed/orchestrator.lock",
      "/r/.git/swift-harness/plans/2026-09-24-feed/Orchestrator.LOCK",
      "/r/.git/swift-harness/plans/orchestrator.lock",
      "/r/.git/swift-harness/plans/claim.lock.0", "/r/.git/swift-harness/plans/claim.lock.guard",
      "/r/.git/swift-harness/plans/Index.Lock.0", "/r/.git/swift-harness/plans/index.lock.guard",
    ])
  func lockTarget(path: String) {
    #expect(PlanStateGuard.target(ofResolvedPath: path) == .orchestratorLock)
  }

  @Test(
    "a plan directory whose name no plan can have is denied to everyone — catches an unaddressable plan path treated as writable"
  )
  func malformedPlanPath() {
    let path = "/r/.git/swift-harness/plans/feed\nx/ledger.json"
    #expect(PlanStateGuard.target(ofResolvedPath: path) == .malformedPlanPath)
    #expect(
      PlanStateGuard.evaluate(
        .malformedPlanPath, locks: ["session-a"], environmentValue: "1", sessionID: "session-a",
        agentID: nil)?.ruleID == EditGuard.planStateRuleID)
  }

  @Test(
    "the outermost plans root decides the plan — catches a nested look-alike root choosing a plan whose lock the writer controls"
  )
  func outermostRootWins() throws {
    let path = "/r/.git/swift-harness/plans/2026-09-24-feed/swift-harness/plans/mine/ledger.json"
    let feed = try Self.feed()
    #expect(PlanStateGuard.target(ofResolvedPath: path) == .planFile(feed))
  }

  @Test(
    "design docs and every evidence file are artifacts of their design doc — catches workers editing an approved design, its claims or its amendments",
    arguments: [
      ("/r/docs/designs/2026-09-25-feed.md", "/r/docs/designs/2026-09-25-feed.md"),
      ("/r/docs/feed/designs/2026-09-25-feed.md", "/r/docs/feed/designs/2026-09-25-feed.md"),
      ("/r/docs/feed/sub/designs/offline.md", "/r/docs/feed/sub/designs/offline.md"),
      ("/r/DOCS/Feed/Designs/offline.MD", "/r/DOCS/Feed/Designs/offline.MD"),
      ("/wt/sibling/docs/feed/designs/offline.md", "/wt/sibling/docs/feed/designs/offline.md"),
      ("/r/docs/feed/designs/offline.evidence/claims.jsonl", PlanStateGuardTests.doc),
      ("/r/docs/feed/designs/offline.evidence/amendments.jsonl", PlanStateGuardTests.doc),
      ("/r/docs/feed/designs/offline.evidence/snapshots/UIKit/UIView.md", PlanStateGuardTests.doc),
      ("/r/docs/feed/designs/offline.evidence/captures/c1.txt", PlanStateGuardTests.doc),
      ("/r/docs/feed/designs/offline.evidence/probes/Probe_ev_x.swift", PlanStateGuardTests.doc),
      ("/r/docs/feed/designs/Offline.EVIDENCE/claims.jsonl", "/r/docs/feed/designs/Offline.md"),
    ])
  func designArtifacts(path: String, document: String) {
    #expect(PlanStateGuard.target(ofResolvedPath: path) == .designArtifact(document: document))
  }

  @Test(
    "ordinary files and look-alikes are not guarded — catches the guard blocking plans, ADRs and source",
    arguments: [
      "/r/docs/plans/2026-09-25-feed-plan.md", "/r/docs/feed/adrs/0001-queue.md",
      "/r/docs/feed/designs/diagrams/flow.md", "/r/designs/offline.md",
      "/r/docs/feed/designs/offline.txt", "/r/Sources/Feed/Feed.swift",
      "/r/.git/swift-harness/planner/ledger.json", "/r/swift-harness/docs/plans/x.md",
      "/r/docs/feed/designs/offline.evidence", "/r/.harness/plans/2026-09-24-feed/ledger.json",
    ])
  func unguarded(path: String) {
    #expect(PlanStateGuard.target(ofResolvedPath: path) == nil)
  }

  @Test(
    "a plan's files are writable only by the main session holding that plan's lock — catches session B rewriting plan A's ledger"
  )
  func holderOnly() throws {
    let target = PlanStateGuard.Target.planFile(try Self.feed())
    #expect(
      PlanStateGuard.evaluate(
        target, locks: ["session-a\n"], environmentValue: nil, sessionID: "session-a",
        agentID: nil) == nil)
    #expect(
      PlanStateGuard.evaluate(
        target, locks: ["session-a"], environmentValue: nil, sessionID: "session-b", agentID: nil)?
        .ruleID == EditGuard.planStateRuleID)
    #expect(
      PlanStateGuard.evaluate(
        target, locks: [], environmentValue: nil, sessionID: "session-a", agentID: nil)?.ruleID
        == EditGuard.planStateRuleID)
    #expect(
      PlanStateGuard.evaluate(
        target, locks: [""], environmentValue: nil, sessionID: "", agentID: nil)?.ruleID
        == EditGuard.planStateRuleID)
  }

  @Test(
    "a subagent is denied even with the lock and the override — catches workers inheriting their parent session's claim"
  )
  func subagentAlwaysDenied() throws {
    for target in try Self.guardedTargets() {
      #expect(
        PlanStateGuard.evaluate(
          target, locks: ["session-a"], plans: Self.owners, environmentValue: "1",
          sessionID: "session-a", agentID: "a1b2c3d4")?.ruleID == EditGuard.planStateRuleID)
    }
  }

  @Test(
    "the environment override lets a main session write plan state and design artifacts — catches the documented escape hatch breaking"
  )
  func environmentOverride() throws {
    for target in try Self.guardedTargets() {
      #expect(
        PlanStateGuard.evaluate(
          target, locks: [], environmentValue: "1", sessionID: "session-a", agentID: nil) == nil)
      #expect(
        PlanStateGuard.evaluate(
          target, locks: [], environmentValue: "0", sessionID: "session-a", agentID: nil)?.ruleID
          == EditGuard.planStateRuleID)
    }
  }

  @Test(
    "orchestrator.lock is never hand-edited, not even by its holder or with the override — catches a claim forged or stolen without swiftgate plan"
  )
  func lockNeverWritable() {
    #expect(
      PlanStateGuard.evaluate(
        .orchestratorLock, locks: ["session-a"], environmentValue: "1", sessionID: "session-a",
        agentID: nil)?.ruleID == EditGuard.planStateRuleID)
  }

  @Test(
    "the index needs any plan's lock held by this session — catches an unclaimed session writing shared state"
  )
  func anyLockForSharedState() throws {
    for target in [PlanStateGuard.Target.sharedPlanFile(try Self.layout())] {
      #expect(
        PlanStateGuard.evaluate(
          target, locks: ["other", "session-a"], environmentValue: nil, sessionID: "session-a",
          agentID: nil) == nil)
      #expect(
        PlanStateGuard.evaluate(
          target, locks: ["other"], environmentValue: nil, sessionID: "session-a", agentID: nil)?
          .ruleID == EditGuard.planStateRuleID)
    }
  }
}

@Suite("Design artifact ownership")
struct DesignOwnershipTests {
  static let docA = "/r/docs/feed/designs/offline.md"
  static let docB = "/r/docs/search/designs/search.md"
  static let plans = [
    PlanStateGuard.PlanRecord(name: "2026-09-24-feed", lock: "session-a", design: .named(docA)),
    PlanStateGuard.PlanRecord(name: "2026-09-25-search", lock: "session-b", design: .named(docB)),
  ]

  static func decide(
    _ document: String, session: String, plans: [PlanStateGuard.PlanRecord] = plans,
    environmentValue: String? = nil, agentID: String? = nil
  ) -> GuardViolation? {
    PlanStateGuard.evaluate(
      .designArtifact(document: document), locks: [], plans: plans,
      environmentValue: environmentValue, sessionID: session, agentID: agentID)
  }

  @Test(
    "only the holder of the plan whose plan.json names the design may write it — catches plan A's holder editing plan B's design"
  )
  func ownerOnly() {
    #expect(Self.decide(Self.docB, session: "session-b") == nil)
    #expect(Self.decide(Self.docA, session: "session-a") == nil)
    let crossed = Self.decide(Self.docB, session: "session-a")
    #expect(crossed?.ruleID == EditGuard.planStateRuleID)
    #expect(crossed?.reason.contains("2026-09-25-search") == true)
  }

  @Test(
    "a design no plan names is denied with the claim hint, even to a lock holder — catches an unowned design written by whoever holds any lock"
  )
  func unnamedDesign() {
    let violation = Self.decide("/r/docs/feed/designs/orphan.md", session: "session-a")
    #expect(violation?.ruleID == EditGuard.planStateRuleID)
    #expect(violation?.reason.contains("swiftgate plan claim <slug>") == true)
  }

  @Test(
    "a holder whose plan.json is unreadable is denied — catches a corrupt plan.json failing open"
  )
  func unreadablePlanFile() {
    let plans = [
      PlanStateGuard.PlanRecord(name: "2026-09-24-feed", lock: "session-a", design: .unreadable)
    ]
    let violation = Self.decide(Self.docA, session: "session-a", plans: plans)
    #expect(violation?.ruleID == EditGuard.planStateRuleID)
    #expect(violation?.reason.contains("plan.json") == true)
  }

  @Test(
    "the override allows any design to a main session but never to a subagent — catches the escape hatch breaking or leaking to workers"
  )
  func overrideAndSubagent() {
    #expect(Self.decide("/r/docs/x/designs/orphan.md", session: "s", environmentValue: "1") == nil)
    #expect(Self.decide(Self.docB, session: "s", plans: [], environmentValue: "1") == nil)
    #expect(
      Self.decide(Self.docB, session: "session-b", environmentValue: "1", agentID: "w")?.ruleID
        == EditGuard.planStateRuleID)
  }
}

@Suite("Sprint spec pages under the plan-state root")
struct SprintPageGuardTests {
  static let plans = "/r/.git/swift-harness/plans"
  static let sprints = plans + "/" + PlanStateLayout.sprintsDirectoryName

  /// The guard's verdict on a write, judged as the hook judges it: classify the path, read the
  /// locks its scope names from `locks`, then evaluate. A path outside plan state is `nil`.
  static func judge(
    _ path: String, isDirectory: Bool = false, locks: [String: String] = [:],
    environmentValue: String? = nil, sessionID: String = "session-a", agentID: String? = nil
  ) -> (classified: Bool, violation: GuardViolation?) {
    guard let target = PlanStateGuard.target(ofResolvedPath: path, isDirectory: isDirectory)
    else { return (false, nil) }
    let held: [String] =
      switch PlanStateGuard.lockScope(of: target) {
      case .none: []
      case .plan(let plan): locks[plan.directory].map { [$0] } ?? []
      case .everyPlan: Array(locks.values)
      }
    let violation = PlanStateGuard.evaluate(
      target, locks: held, environmentValue: environmentValue, sessionID: sessionID,
      agentID: agentID)
    return (true, violation)
  }

  @Test(
    "a main session with no claim writes a sprint page, in any letter case, and a subagent is denied it even with the override and another plan's lock — catches the sprints directory read as a plan whose lock no sprint holds, or workers rewriting the spec a sprint builds from",
    arguments: [
      sprints + "/login-flow.md", "/r/.git/Swift-Harness/PLANS/Sprints/Login-Flow.MD",
    ])
  func pageWritableByMainSessionOnly(path: String) throws {
    #expect(Self.judge(path).violation == nil, "\(path)")
    let feed = try PlanStateLayout(commonDirectory: "/r/.git").plan("2026-09-24-feed")
    let subagent = Self.judge(
      path, locks: [feed.directory: "session-a"], environmentValue: "1", agentID: "worker")
    #expect(subagent.violation?.ruleID == EditGuard.planStateRuleID, "\(path)")
  }

  @Test(
    "anything under sprints but a page directly in it is denied to everyone, holder and override included — catches the page allowance widening to nested paths, other files or the directory itself",
    arguments: [
      (sprints + "/login-flow/notes.md", false), (sprints + "/login-flow.json", false),
      (sprints + "/.md", false), (sprints, true), (sprints, false),
    ])
  func otherSprintPathsDenied(path: String, isDirectory: Bool) {
    #expect(
      PlanStateGuard.target(ofResolvedPath: path, isDirectory: isDirectory) == .malformedPlanPath,
      "\(path)")
    let verdict = Self.judge(
      path, isDirectory: isDirectory, locks: [Self.sprints: "session-a"], environmentValue: "1")
    #expect(verdict.violation?.ruleID == EditGuard.planStateRuleID, "\(path)")
  }

  @Test(
    "no plan may be named sprints in any letter case, and a page-shaped file inside a real plan still needs that plan's lock — catches a claimed plan's lock deciding the sprint pages, or the page allowance leaking to plan directories"
  )
  func sprintsIsNoPlanAndPlansKeepTheirLocks() throws {
    let layout = try PlanStateLayout(commonDirectory: "/r/.git")
    for name in ["sprints", "Sprints", "SPRINTS"] {
      #expect(throws: PlanStateLayoutError.invalidPlanName(name)) {
        _ = try layout.plan(name)
      }
    }
    #expect(try layout.plan("sprints-2026").directory == Self.plans + "/sprints-2026")
    let feed = try layout.plan("2026-09-24-feed")
    for path in [feed.directory + "/sprints/login-flow.md", feed.directory + "/login-flow.md"] {
      #expect(PlanStateGuard.target(ofResolvedPath: path) == .planFile(feed), "\(path)")
      #expect(Self.judge(path).violation?.ruleID == EditGuard.planStateRuleID, "\(path)")
      #expect(Self.judge(path, locks: [feed.directory: "session-a"]).violation == nil, "\(path)")
    }
    let other = Self.plans + "/sprints-2026/login-flow.md"
    #expect(Self.judge(other).violation?.ruleID == EditGuard.planStateRuleID)
  }
}
