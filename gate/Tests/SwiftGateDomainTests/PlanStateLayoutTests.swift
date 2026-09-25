import SwiftGateDomain
import Testing

@Suite("PlanStateLayout")
struct PlanStateLayoutTests {
  @Test(
    "index and per-plan files sit under swift-harness/plans in the common dir — catches plan state written beside the checkout"
  )
  func paths() throws {
    let layout = try PlanStateLayout(commonDirectory: "/repo/.git")
    #expect(layout.root == "/repo/.git/swift-harness/plans")
    #expect(layout.indexFile == "/repo/.git/swift-harness/plans/index.json")

    let plan = try layout.plan("2026-09-25-offline-queue")
    #expect(plan.directory == "/repo/.git/swift-harness/plans/2026-09-25-offline-queue")
    #expect(plan.planFile == "/repo/.git/swift-harness/plans/2026-09-25-offline-queue/plan.json")
    #expect(
      plan.ledgerFile == "/repo/.git/swift-harness/plans/2026-09-25-offline-queue/ledger.json")
    #expect(
      plan.orchestratorLock
        == "/repo/.git/swift-harness/plans/2026-09-25-offline-queue/orchestrator.lock")
  }

  @Test(
    "a trailing slash on the common dir does not double the separator — catches paths the edit guard fails to match"
  )
  func trailingSlash() throws {
    let layout = try PlanStateLayout(commonDirectory: "/repo/.git/")
    #expect(layout.indexFile == "/repo/.git/swift-harness/plans/index.json")
  }

  @Test("no layout path lies under .harness/ — catches plan state that task worktrees can't see")
  func nothingUnderHarness() throws {
    let layout = try PlanStateLayout(commonDirectory: "/work/app/.git")
    let plan = try layout.plan("2026-09-25-a")
    let all = [
      layout.root, layout.indexFile, plan.directory, plan.planFile, plan.ledgerFile,
      plan.orchestratorLock,
    ]
    for path in all {
      #expect(!path.split(separator: "/").contains(".harness"), "\(path)")
      #expect(path.hasPrefix("/work/app/.git/"), "\(path)")
    }
  }

  @Test(
    "a relative common dir is rejected — catches plan state resolved against whatever cwd the caller has"
  )
  func relativeCommonDirectory() {
    #expect(throws: PlanStateLayoutError.relativeCommonDirectory(".git")) {
      _ = try PlanStateLayout(commonDirectory: ".git")
    }
    #expect(throws: PlanStateLayoutError.relativeCommonDirectory("")) {
      _ = try PlanStateLayout(commonDirectory: "")
    }
  }

  @Test(
    "plan names that would escape the plans dir are rejected — catches a slug writing another plan's ledger or the index",
    arguments: ["", ".", "..", "../other", "a/b", "a\0b", "a\nb"])
  func invalidPlanName(name: String) throws {
    let layout = try PlanStateLayout(commonDirectory: "/repo/.git")
    #expect(throws: PlanStateLayoutError.invalidPlanName(name)) {
      _ = try layout.plan(name)
    }
  }
}
