import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// A throwaway git common dir plus the paths `plan claim` and `plan release` act on.
private struct LockScenario {
  static let plan = "2026-09-25-search"
  static let alice = "5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d"
  static let bob = "9a8b7c6d-5e4f-4a3b-2c1d-0e9f8a7b6c5d"
  static let design = "docs/search/designs/search.md"

  let shared = SharedPlanState()
  var git: FakeGit { shared.git() }

  var lockFile: String {
    get throws {
      try PlanStateLayout(commonDirectory: shared.commonDirectory.path).plan(Self.plan)
        .orchestratorLock
    }
  }

  func lockContents() throws -> String? {
    FileManager.default.contents(atPath: try lockFile).map { String(decoding: $0, as: UTF8.self) }
  }

  func claim(
    _ session: String?, plan: String = Self.plan, design: String? = Self.design,
    tier: String? = nil
  ) async -> PlanLockReport {
    await PlanLockRun.claim(slug: plan, session: session, design: design, tier: tier, git: git)
  }

  func planFile() throws -> PlanFile? {
    let path = try PlanStateLayout(commonDirectory: shared.commonDirectory.path).plan(Self.plan)
      .planFile
    return try FileManager.default.contents(atPath: path).map { try PlanFileJSON.decode($0) }
  }

  func release(_ session: String?, force: Bool = false) async -> PlanLockReport {
    await PlanLockRun.release(slug: Self.plan, session: session, force: force, git: git)
  }

  func planStateFiles() -> [String] {
    let root = shared.commonDirectory.appending(path: "swift-harness").path
    return (FileManager.default.subpaths(atPath: root) ?? []).sorted()
  }
}

@Suite("plan claim and plan release")
struct PlanClaimCommandTests {
  @Test(
    "claiming an unheld plan creates its directory and a lock holding exactly the session id and a newline — catches a lock the guard's trimmed comparison can't match"
  )
  func claimWritesSessionID() async throws {
    let scenario = LockScenario()
    defer { scenario.shared.remove() }

    let report = await scenario.claim(LockScenario.alice)

    #expect(report.verdict == .green)
    #expect(report.status == .claimed)
    #expect(try scenario.lockContents() == LockScenario.alice + "\n")
    #expect(
      scenario.planStateFiles() == [
        "plans", "plans/\(LockScenario.plan)", "plans/\(LockScenario.plan)/orchestrator.lock",
        "plans/\(LockScenario.plan)/plan.json",
      ])
  }

  @Test(
    "of many sessions claiming one plan at once exactly one wins and the rest are told who holds it — catches two orchestrators on one ledger"
  )
  func concurrentClaimsHaveOneWinner() async throws {
    let scenario = LockScenario()
    defer { scenario.shared.remove() }
    let plan = try PlanStateLayout(commonDirectory: scenario.shared.commonDirectory.path)
      .plan(LockScenario.plan)
    let sessions = (0..<32).map { "session-\($0)-\(UUID().uuidString)" }
    let outcomes = Mutex<[Result<PlanLock.ClaimOutcome, PlanLockError>]>([])

    DispatchQueue.concurrentPerform(iterations: sessions.count) { index in
      let outcome = Result { () throws(PlanLockError) in
        try PlanLock(plan: plan).claim(session: sessions[index])
      }
      outcomes.withLock { $0.append(outcome) }
    }

    let all = try outcomes.withLock { $0 }.map { try $0.get() }
    #expect(all.count == sessions.count)
    #expect(all.filter { $0 == .claimed }.count == 1)
    let winner = try #require(try scenario.lockContents())
    #expect(sessions.map { $0 + "\n" }.contains(winner))
    let holder = String(winner.dropLast())
    #expect(all.filter { $0 == .heldByOther(holder: holder) }.count == sessions.count - 1)
    #expect(scenario.planStateFiles().count == 3, "no temporary files left behind")
  }

  @Test(
    "re-claiming by the holder succeeds without touching the lock — catches a skill's retry failing"
  )
  func reclaimIsNoOp() async throws {
    let scenario = LockScenario()
    defer { scenario.shared.remove() }
    _ = await scenario.claim(LockScenario.alice)
    let before = try FileManager.default.attributesOfItem(atPath: try scenario.lockFile)

    let report = await scenario.claim(LockScenario.alice)

    #expect(report.verdict == .green)
    #expect(report.status == .alreadyHeld)
    #expect(try scenario.lockContents() == LockScenario.alice + "\n")
    let after = try FileManager.default.attributesOfItem(atPath: try scenario.lockFile)
    #expect(before[.systemFileNumber] as? Int == after[.systemFileNumber] as? Int)
  }

  @Test(
    "claiming a plan another session holds exits 1, names the holder and leaves the lock alone — catches a second session taking over a live plan"
  )
  func claimHeldByOtherRefused() async throws {
    let scenario = LockScenario()
    defer { scenario.shared.remove() }
    _ = await scenario.claim(LockScenario.alice)

    let report = await scenario.claim(LockScenario.bob)

    #expect(report.verdict == .red)
    #expect(report.status == .heldByOther)
    #expect(report.holder == LockScenario.alice)
    #expect(PlanLockRun.render(report, format: .human).contains(LockScenario.alice))
    #expect(try scenario.lockContents() == LockScenario.alice + "\n")
  }

  @Test(
    "release removes the holder's lock but refuses a non-holder, leaving the lock — catches one session freeing another's plan"
  )
  func releaseOnlyByHolder() async throws {
    let scenario = LockScenario()
    defer { scenario.shared.remove() }
    _ = await scenario.claim(LockScenario.alice)

    let refused = await scenario.release(LockScenario.bob)
    #expect(refused.verdict == .red)
    #expect(refused.status == .heldByOther)
    #expect(PlanLockRun.render(refused, format: .human).contains(LockScenario.alice))
    #expect(try scenario.lockContents() == LockScenario.alice + "\n")

    let released = await scenario.release(LockScenario.alice)
    #expect(released.verdict == .green)
    #expect(released.status == .released)
    #expect(try scenario.lockContents() == nil)

    let again = await scenario.release(LockScenario.alice)
    #expect(again.verdict == .green)
    #expect(again.status == .notClaimed)
  }

  @Test(
    "release --force removes another session's lock and reports whose it was — catches a silent takeover"
  )
  func forcedReleaseReportsOverride() async throws {
    let scenario = LockScenario()
    defer { scenario.shared.remove() }
    _ = await scenario.claim(LockScenario.alice)

    let report = await scenario.release(nil, force: true)

    #expect(report.verdict == .green)
    #expect(report.status == .forceReleased)
    #expect(report.holder == LockScenario.alice)
    #expect(PlanLockRun.render(report, format: .human).contains("overrode"))
    #expect(PlanLockRun.render(report, format: .json).contains(LockScenario.alice))
    #expect(try scenario.lockContents() == nil)
    #expect(await scenario.claim(LockScenario.bob).status == .claimed)
  }

  @Test(
    "an invalid plan name or a missing, empty or whitespace-bearing session exits 2 and writes nothing — catches a lock the guard can never match",
    arguments: [
      ("../escape", LockScenario.alice as String?), ("", LockScenario.alice),
      ("a/b", LockScenario.alice),
      (LockScenario.plan, nil), (LockScenario.plan, ""), (LockScenario.plan, "  "),
      (LockScenario.plan, "two words"), (LockScenario.plan, "line\nbreak"),
    ])
  func invalidInputBlocked(plan: String, session: String?) async throws {
    let scenario = LockScenario()
    defer { scenario.shared.remove() }

    let claim = await scenario.claim(session, plan: plan)
    #expect(claim.verdict == .blocked)
    #expect(scenario.planStateFiles().isEmpty)

    _ = await scenario.claim(LockScenario.alice)
    let release = await PlanLockRun.release(
      slug: plan, session: session, force: false, git: scenario.git)
    #expect(release.verdict == .blocked)
    #expect(try scenario.lockContents() == LockScenario.alice + "\n")
  }

  @Test("outside a git repository both commands exit 2 — catches a claim silently landing nowhere")
  func noRepositoryBlocked() async throws {
    let git = FakeGit(
      failure: .commandFailed(
        arguments: ["rev-parse"], status: .exited(128), stderr: "not a git repository"))
    let claim = await PlanLockRun.claim(
      slug: LockScenario.plan, session: LockScenario.alice, git: git)
    let release = await PlanLockRun.release(
      slug: LockScenario.plan, session: LockScenario.alice, force: true, git: git)
    #expect(claim.verdict == .blocked)
    #expect(release.verdict == .blocked)
  }

  @Test(
    "the edit guard allows the claiming session's ledger write after a claim and denies it after release — catches a lock format the guard reads differently"
  )
  func guardHonoursClaimAndRelease() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    let ledger = try scenario.layout.plan(PlanStateScenario.planA).ledgerFile
    let git = scenario.harness.git
    #expect(try await scenario.decision(ledger) == "deny")

    let claim = await PlanLockRun.claim(
      slug: PlanStateScenario.planA, session: PlanStateScenario.session, git: git)
    #expect(claim.status == .claimed)
    #expect(try await scenario.decision(ledger) == nil)

    let release = await PlanLockRun.release(
      slug: PlanStateScenario.planA, session: PlanStateScenario.session, force: false, git: git)
    #expect(release.status == .released)
    #expect(try await scenario.decision(ledger) == "deny")
  }

  @Test(
    "a claim with --design lets the claiming session write that design doc, denies every other session, and denies everyone once a second plan names it — catches every design-doc write being denied at frame, or a design co-owned"
  )
  func claimWithDesignOpensTheDesignDoc() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    let design = "docs/frame/designs/frame.md"
    let document = scenario.root.path + "/" + design
    let git = scenario.harness.git
    #expect(try await scenario.decision(document) == "deny")

    let other = await PlanLockRun.claim(
      slug: "2026-09-26-frame-other", session: LockScenario.bob, design: design, tier: nil, git: git
    )
    #expect(other.status == .claimed)
    #expect(try await scenario.decision(document) == "deny", "another session's plan names it")

    _ = await PlanLockRun.release(
      slug: "2026-09-26-frame-other", session: LockScenario.bob, force: false, git: git)
    let claim = await PlanLockRun.claim(
      slug: "2026-09-26-frame-other", session: PlanStateScenario.session, design: design,
      tier: "standard", git: git)
    #expect(claim.status == .claimed)
    #expect(try await scenario.decision(document) == nil)

    try scenario.writePlanFile("2026-09-26-frame-copy", design: design)
    #expect(try await scenario.decision(document) == "deny", "a second plan names it")
  }

  @Test(
    "the seed plan.json names the design, has no sha yet and survives a re-claim naming another design — catches a re-claim clobbering the plan"
  )
  func seedPlanFile() async throws {
    let scenario = LockScenario()
    defer { scenario.shared.remove() }

    #expect(await scenario.claim(LockScenario.alice, tier: "deep").status == .claimed)
    let seed = try #require(try scenario.planFile())
    #expect(seed.slug == LockScenario.plan)
    #expect(seed.design == LockScenario.design)
    #expect(seed.designSha == nil)
    #expect(seed.approval == nil)
    #expect(seed.tier == .deep)
    #expect(try PlanFileJSON.decode(try PlanFileJSON.encode(seed)) == seed)

    let again = await scenario.claim(LockScenario.alice, design: "docs/other/designs/other.md")
    #expect(again.status == .alreadyHeld)
    #expect(try scenario.planFile() == seed)
  }

  @Test(
    "a new plan claimed without --design exits 2 and writes nothing; an existing plan needs none — catches a plan the guard can never tie to a doc"
  )
  func newPlanNeedsDesign() async throws {
    let scenario = LockScenario()
    defer { scenario.shared.remove() }

    let report = await scenario.claim(LockScenario.alice, design: nil)
    #expect(report.verdict == .blocked)
    #expect(report.message.contains("--design"))
    #expect(scenario.planStateFiles().isEmpty)

    _ = await scenario.claim(LockScenario.alice)
    _ = await scenario.release(LockScenario.alice)
    #expect(await scenario.claim(LockScenario.bob, design: nil).status == .claimed)
  }

  @Test(
    "a --design outside a docs designs directory, absolute, climbing or not markdown, or an unknown --tier, exits 2 and writes nothing — catches a plan naming a doc the guard doesn't cover",
    arguments: [
      ("/abs/docs/designs/a.md", nil as String?), ("docs/designs/../a.md", nil),
      ("docs/x/../designs/a.md", nil), ("docs/designs/a.txt", nil), ("docs/a.md", nil),
      ("designs/a.md", nil), ("docs/designs/", nil), ("", nil), ("docs//designs/a.md", nil),
      ("./docs/designs/a.md", nil), (LockScenario.design, "huge"),
    ])
  func badDesignBlocked(design: String, tier: String?) async throws {
    let scenario = LockScenario()
    defer { scenario.shared.remove() }

    let report = await scenario.claim(LockScenario.alice, design: design, tier: tier)

    #expect(report.verdict == .blocked)
    #expect(scenario.planStateFiles().isEmpty)
  }
}
