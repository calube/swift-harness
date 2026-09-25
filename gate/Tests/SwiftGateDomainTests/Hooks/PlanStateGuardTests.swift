import SwiftGateDomain
import Testing

@Suite("Plan state and design artifact guard")
struct PlanStateGuardTests {
  static let common = "/r/.git"
  static func layout() throws -> PlanStateLayout { try PlanStateLayout(commonDirectory: common) }
  static func feed() throws -> PlanStateLayout.Plan { try layout().plan("2026-09-24-feed") }
  static func guardedTargets() throws -> [PlanStateGuard.Target] {
    [.planFile(try feed()), .sharedPlanFile(try layout()), .designArtifact]
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
    "orchestrator.lock is its own target wherever it sits under a plans root — catches a hand-written claim",
    arguments: [
      "/r/.git/swift-harness/plans/2026-09-24-feed/orchestrator.lock",
      "/r/.git/swift-harness/plans/2026-09-24-feed/Orchestrator.LOCK",
      "/r/.git/swift-harness/plans/orchestrator.lock",
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
    "design docs and every evidence file are design artifacts — catches workers editing an approved design, its claims or its amendments",
    arguments: [
      "/r/docs/designs/2026-09-25-feed.md",
      "/r/docs/feed/designs/2026-09-25-feed.md",
      "/r/docs/feed/sub/designs/offline.md",
      "/r/DOCS/Feed/Designs/offline.MD",
      "/wt/sibling/docs/feed/designs/offline.md",
      "/r/docs/feed/designs/offline.evidence/claims.jsonl",
      "/r/docs/feed/designs/offline.evidence/amendments.jsonl",
      "/r/docs/feed/designs/offline.evidence/snapshots/UIKit/UIView.md",
      "/r/docs/feed/designs/offline.evidence/captures/c1.txt",
      "/r/docs/feed/designs/offline.evidence/probes/Probe_ev_x.swift",
      "/r/docs/feed/designs/Offline.EVIDENCE/claims.jsonl",
    ])
  func designArtifacts(path: String) {
    #expect(PlanStateGuard.target(ofResolvedPath: path) == .designArtifact)
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
          target, locks: ["session-a"], environmentValue: "1", sessionID: "session-a",
          agentID: "a1b2c3d4")?.ruleID == EditGuard.planStateRuleID)
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
    "the index and design artifacts need any plan's lock held by this session — catches an unclaimed session writing shared state"
  )
  func anyLockForSharedState() throws {
    for target in [PlanStateGuard.Target.sharedPlanFile(try Self.layout()), .designArtifact] {
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
