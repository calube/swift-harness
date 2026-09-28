import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("spec-page plans through plan claim, plan set, the edit guard and design-diff")
struct SpecPagePlanCommandTests {
  static let plan = "2026-09-28-reading-list"
  static let other = "5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d"

  static func claim(
    _ scenario: PlanStateScenario, session: String = PlanStateScenario.session,
    design: String? = nil, specPage: Bool = true, tier: String? = nil
  ) async -> PlanLockReport {
    await PlanLockRun.claim(
      slug: plan, session: session, design: design, specPage: specPage, tier: tier,
      root: scenario.root, git: scenario.harness.git)
  }

  static func planFile(_ scenario: PlanStateScenario) throws -> PlanFile {
    let path = try scenario.layout.plan(plan).planFile
    return try PlanFileJSON.decode(try #require(FileManager.default.contents(atPath: path)))
  }

  static func text(_ file: PlanFile) throws -> String {
    String(decoding: try PlanFileJSON.encode(file), as: UTF8.self)
  }

  @Test(
    "plan claim --spec-page seeds a spec-page plan naming no design, and --design or --tier with it exits 2 writing nothing — catches a spec-page claim that seeds a design plan or quietly drops a flag"
  )
  func claimSeedsSpecPage() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    let before = try scenario.planStateSnapshot()

    for (design, tier) in [("docs/reading/designs/reading-list.md", nil), (nil, "quick")] {
      let refused = await Self.claim(scenario, design: design, tier: tier)
      #expect(refused.verdict.exitCode == 2, "\(refused.message)")
      #expect(refused.message.contains("--spec-page"), "\(refused.message)")
    }
    #expect(try scenario.planStateSnapshot() == before)

    let neither = await Self.claim(scenario, specPage: false)
    #expect(neither.verdict.exitCode == 2)
    #expect(neither.message.contains("--spec-page"), "\(neither.message)")

    let claimed = await Self.claim(scenario)
    #expect(claimed.status == .claimed, "\(claimed.message)")
    #expect(claimed.message.contains(PlanFile.SpecPageSource.fileName), "\(claimed.message)")
    let seeded = try Self.planFile(scenario)
    #expect(seeded == PlanFile.seedSpecPage(slug: Self.plan))
    #expect(seeded.designSource == nil)
  }

  @Test(
    "after plan claim --spec-page the holder may Write spec-page.md, another session and a subagent may not, and plan.json keeps its kind — catches a spec-page plan's page open to anyone, or the guard reading a spec-page plan.json as unreadable"
  )
  func pageWritableByHolderOnly() async throws {
    var scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    #expect(await Self.claim(scenario).status == .claimed)
    let plan = try scenario.layout.plan(Self.plan)
    let page = plan.directory + "/" + PlanFile.SpecPageSource.fileName

    #expect(try await scenario.toolDecision(page, writing: "# Reading list\n") == nil)
    #expect(try await scenario.decision(page, subagent: true) == "deny")

    var hashed = try Self.planFile(scenario)
    hashed = PlanFile(
      schemaVersion: hashed.schemaVersion, slug: hashed.slug,
      source: .specPage(
        PlanFile.SpecPageSource(
          path: PlanFile.SpecPageSource.fileName, pageSha: "9b1e", approval: nil)),
      surfaceCommit: nil, resume: "confirming")
    #expect(try await scenario.toolDecision(plan.planFile, writing: try Self.text(hashed)) == nil)
    let designed = PlanFile.seed(
      slug: Self.plan, design: "docs/counter/designs/orphan.md", tier: nil)
    let gained = try await scenario.toolDecision(plan.planFile, writing: try Self.text(designed))
    #expect(gained == "deny")

    _ = await PlanLockRun.release(
      slug: Self.plan, session: PlanStateScenario.session, force: false, git: scenario.harness.git)
    #expect(await Self.claim(scenario, session: Self.other).status == .claimed)
    #expect(try await scenario.toolDecision(page, writing: "# Reading list\n") == "deny")

    scenario.harness.environment = [OrchestratorMarker.environmentVariable: "1"]
    #expect(try await scenario.decision(page, subagent: true) == "deny")
  }

  @Test(
    "plan set --resume on a spec-page plan keeps its page, confirmation and surface commit, and --tier is refused leaving plan.json as it was — catches plan set rewriting a spec-page plan as a design plan or dropping a field"
  )
  func planSetKeepsSpecPageFields() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    #expect(await Self.claim(scenario).status == .claimed)
    let path = try scenario.layout.plan(Self.plan).planFile
    let confirmed = PlanFile(
      schemaVersion: 1, slug: Self.plan,
      source: .specPage(
        PlanFile.SpecPageSource(
          path: PlanFile.SpecPageSource.fileName, pageSha: "9b1e",
          approval: PlanFile.PageApproval(
            pageSha: "9b1e", by: .user, at: Date(timeIntervalSince1970: 1_790_236_800)))),
      surfaceCommit: "4d9a0c2", resume: "framing")
    try scenario.write(path, try Self.text(confirmed))

    let resumed = await PlanSetRun.run(
      slug: Self.plan, session: PlanStateScenario.session, tier: nil, resume: "building",
      git: scenario.harness.git)
    #expect(resumed.status == .updated, "\(resumed.message)")
    let expected = PlanFile(
      schemaVersion: 1, slug: Self.plan, source: confirmed.source, surfaceCommit: "4d9a0c2",
      resume: "building")
    #expect(try Self.planFile(scenario) == expected)

    let before = FileManager.default.contents(atPath: path)
    let retiered = await PlanSetRun.run(
      slug: Self.plan, session: PlanStateScenario.session, tier: "deep", resume: nil,
      git: scenario.harness.git)
    #expect(retiered.verdict.exitCode == 2)
    #expect(retiered.message.contains("spec-page plan"), "\(retiered.message)")
    #expect(FileManager.default.contents(atPath: path) == before)
  }

  @Test(
    "plan set on a design plan keeps its surface commit — catches a re-scope dropping the plan's surface"
  )
  func planSetKeepsDesignSurface() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    let path = try scenario.layout.plan(PlanStateScenario.planA).planFile
    let current = try PlanFileJSON.decode(try #require(FileManager.default.contents(atPath: path)))
    let surfaced = PlanFile(
      schemaVersion: 1, slug: current.slug, source: current.source, surfaceCommit: "4d9a0c2",
      resume: current.resume)
    try scenario.write(path, try Self.text(surfaced))

    let report = await PlanSetRun.run(
      slug: PlanStateScenario.planA, session: PlanStateScenario.session, tier: "deep",
      resume: nil, git: scenario.harness.git)
    #expect(report.status == .updated, "\(report.message)")
    let updated = try PlanFileJSON.decode(try #require(FileManager.default.contents(atPath: path)))
    #expect(updated.surfaceCommit == "4d9a0c2")
    #expect(updated.designSource?.tier == .deep)
  }

  @Test(
    "design-diff --chain on a spec-page plan exits 2 naming the plan as a spec-page plan — catches a plan with no design read as one whose design is empty"
  )
  func chainRefusesSpecPagePlan() async throws {
    let scratch = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-spec-page-chain-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let path = scratch.appending(path: "plan.json").path
    try PlanFileJSON.encode(PlanFile.seedSpecPage(slug: Self.plan)).write(to: URL(filePath: path))

    let report = await DesignDiffRun.chain(
      planPath: path, workingDirectory: scratch, git: FakeGit(changed: [], mergeBase: "base"))
    #expect(report.verdict.exitCode == 2)
    #expect(report.status == .noDesign)
    #expect(report.message.contains("spec-page plan"), "\(report.message)")
    #expect(report.message.contains(path), "\(report.message)")
  }
}
