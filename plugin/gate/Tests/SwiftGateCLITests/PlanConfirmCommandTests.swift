import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("plan confirm binds a spec page's confirmation to its bytes")
struct PlanConfirmCommandTests {
  static let plan = "2026-09-28-postcode"
  static let other = "5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d"
  static let now = Date(timeIntervalSince1970: 1_790_236_800)
  static let clearQuote =
    "Spec: \"Clear empties every field and clears every error, and the saved address is unchanged.\""

  static func fixture(_ file: String) -> String {
    Fixture.directory.appending(path: "spec-page/\(file)").path
  }

  /// The captured recipient-postcode page with its Clear slice's quote replaced by `none`, so the
  /// page is GREEN but needs the user's confirm.
  static func pageWithNoneSlice() throws -> String {
    let page = try Fixture.text("spec-page/recipient-postcode.page.txt")
    try #require(page.contains(clearQuote), "the captured page no longer holds the Clear quote")
    return page.replacingOccurrences(of: clearQuote, with: "Spec: none")
  }

  /// Claims `slug` as a spec-page plan for `session` and writes `page` as its spec page.
  static func claimed(
    _ scenario: PlanStateScenario, slug: String = plan,
    session: String = PlanStateScenario.session, page: String?
  ) async throws -> String {
    let claim = await PlanLockRun.claim(
      slug: slug, session: session, specPage: true, root: scenario.root,
      git: scenario.harness.git)
    try #require(claim.status == .claimed, "\(claim.message)")
    try PlanIndex(plans: []).encode().write(to: URL(filePath: scenario.layout.indexFile))
    let path = try scenario.layout.plan(slug).directory + "/" + PlanFile.SpecPageSource.fileName
    if let page { try scenario.write(path, page) }
    return path
  }

  static func confirm(
    _ scenario: PlanStateScenario, slug: String = plan,
    session: String? = PlanStateScenario.session, by: String, spec: String
  ) async -> PlanConfirmReport {
    await PlanConfirmRun.run(
      slug: slug, session: session, by: by, specPath: fixture(spec), git: scenario.harness.git,
      now: now)
  }

  static func planFile(_ scenario: PlanStateScenario, slug: String = plan) throws -> PlanFile {
    let path = try scenario.layout.plan(slug).planFile
    return try PlanFileJSON.decode(try #require(FileManager.default.contents(atPath: path)))
  }

  static func indexEntry(_ scenario: PlanStateScenario, slug: String = plan) throws
    -> PlanSummary?
  {
    let data = try #require(FileManager.default.contents(atPath: scenario.layout.indexFile))
    return try PlanIndex.decode(data).plans.first { $0.slug == slug }
  }

  /// The bytes of plan.json and index.json, to show a refusal wrote nothing.
  static func state(_ scenario: PlanStateScenario, slug: String = plan) throws -> [Data?] {
    [
      FileManager.default.contents(atPath: try scenario.layout.plan(slug).planFile),
      FileManager.default.contents(atPath: scenario.layout.indexFile),
    ]
  }

  @Test(
    "--by spec-quotes on a page with a Spec: none slice is refused as plan-confirm.needs-user and writes nothing — catches the skill skipping the user's confirm on its own reading"
  )
  func specQuotesRefusedWhenConfirmRequired() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    _ = try await Self.claimed(scenario, page: try Self.pageWithNoneSlice())
    let before = try Self.state(scenario)

    let report = await Self.confirm(
      scenario, by: "spec-quotes", spec: "recipient-postcode.spec.txt")

    #expect(report.status == .refused, "\(report.message)")
    #expect(report.rule == .needsUser)
    #expect(report.verdict.exitCode == 1)
    #expect(report.confirm == .required)
    #expect(report.message.contains("--by user"), "\(report.message)")
    #expect(try Self.state(scenario) == before)
    #expect(try Self.planFile(scenario).specPageSource?.approval == nil)
  }

  @Test(
    "--by user on a page with a Spec: none slice records the page's sha, who and when, and sets the index to approved — catches a confirmation not bound to the bytes it confirmed"
  )
  func userConfirmRecordsPageSha() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    let page = try Self.pageWithNoneSlice()
    _ = try await Self.claimed(scenario, page: page)
    let sha = SpecPageCheck.pageSha(Data(page.utf8))

    let report = await Self.confirm(scenario, by: "user", spec: "recipient-postcode.spec.txt")

    #expect(report.status == .confirmed, "\(report.message)")
    #expect(report.verdict.exitCode == 0)
    #expect(report.pageSha == sha)
    #expect(report.by == .user)
    let source = try #require(try Self.planFile(scenario).specPageSource)
    #expect(source.pageSha == sha)
    #expect(source.approval == PlanFile.PageApproval(pageSha: sha, by: .user, at: Self.now))
    #expect(try Self.indexEntry(scenario)?.status == PlanStatus.approved.rawValue)
  }

  @Test(
    "--by spec-quotes on a captured page whose every slice quotes its spec is recorded as spec-quotes — catches a needs-user check that refuses every skip"
  )
  func specQuotesRecordedWhenSkippable() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    let page = try Fixture.text("spec-page/task-status.page.txt")
    _ = try await Self.claimed(scenario, page: page)

    let report = await Self.confirm(scenario, by: "spec-quotes", spec: "task-status.spec.txt")

    #expect(report.status == .confirmed, "\(report.message)")
    #expect(report.confirm == .skippable)
    let sha = SpecPageCheck.pageSha(Data(page.utf8))
    #expect(
      try Self.planFile(scenario).specPageSource?.approval
        == PlanFile.PageApproval(pageSha: sha, by: .specQuotes, at: Self.now))
    #expect(try Self.indexEntry(scenario)?.status == PlanStatus.approved.rawValue)
  }

  @Test(
    "a RED page is refused as plan-confirm.page-red under --by user and --by spec-quotes, naming its findings and writing nothing — catches a user confirm waving through a page the check fails"
  )
  func redPageRefusedUnderEitherApprover() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    _ = try await Self.claimed(
      scenario, page: try Fixture.text("spec-page/shipping-address.page.txt"))
    let before = try Self.state(scenario)

    for by in ["user", "spec-quotes"] {
      let report = await Self.confirm(scenario, by: by, spec: "shipping-address.spec.txt")
      #expect(report.status == .refused, "\(by): \(report.message)")
      #expect(report.rule == .pageRed, "\(by)")
      #expect(report.verdict.exitCode == 1, "\(by)")
      #expect(report.findings.map(\.ruleID).contains("spec-page.too-long"), "\(by)")
      #expect(report.message.contains("spec-page.too-long"), "\(by): \(report.message)")
    }
    #expect(try Self.state(scenario) == before)
  }

  @Test(
    "a session without the plan's lock exits 1 naming the holder, including one that holds another plan's lock, and writes nothing — catches a confirm from outside the plan's lock, or one plan's lock granting another's"
  )
  func notHolderRefused() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    let page = try Fixture.text("spec-page/task-status.page.txt")
    _ = try await Self.claimed(scenario, page: page)
    let mine = "2026-09-28-mine"
    _ = try await Self.claimed(scenario, slug: mine, session: Self.other, page: page)
    let before = try Self.state(scenario)

    let foreign = await Self.confirm(
      scenario, session: Self.other, by: "user", spec: "task-status.spec.txt")
    #expect(foreign.status == .notHeld, "\(foreign.message)")
    #expect(foreign.verdict.exitCode == 1)
    #expect(foreign.holder == PlanStateScenario.session)
    #expect(try Self.state(scenario) == before)

    _ = await PlanLockRun.release(
      slug: Self.plan, session: PlanStateScenario.session, force: false,
      git: scenario.harness.git)
    let unclaimed = await Self.confirm(scenario, by: "user", spec: "task-status.spec.txt")
    #expect(unclaimed.status == .notHeld, "\(unclaimed.message)")
    #expect(unclaimed.verdict.exitCode == 1)
    #expect(unclaimed.holder == nil)
    #expect(try Self.planFile(scenario).specPageSource?.approval == nil)
  }

  @Test(
    "a design plan is refused with exit 2, naming it and its design, and plan.json is left as it was — catches a confirm writing a page approval onto a design plan"
  )
  func designPlanRefused() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    let before = try Self.state(scenario, slug: PlanStateScenario.planA)

    let report = await Self.confirm(
      scenario, slug: PlanStateScenario.planA, by: "user", spec: "task-status.spec.txt")

    #expect(report.verdict.exitCode == 2)
    #expect(report.status == .blocked)
    #expect(report.message.contains("design plan"), "\(report.message)")
    #expect(report.message.contains(PlanStateScenario.designA), "\(report.message)")
    #expect(try Self.state(scenario, slug: PlanStateScenario.planA) == before)
  }

  @Test(
    "a missing page, an unreadable spec file, an unknown --by or no --session exits 2 and writes nothing — catches an unreadable input read as a confirmable page"
  )
  func unreadableInputsBlocked() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    let path = try await Self.claimed(scenario, page: nil)
    let before = try Self.state(scenario)

    let missingPage = await Self.confirm(scenario, by: "user", spec: "task-status.spec.txt")
    #expect(missingPage.verdict.exitCode == 2, "\(missingPage.message)")
    #expect(missingPage.message.contains(path), "\(missingPage.message)")

    try scenario.write(path, try Fixture.text("spec-page/task-status.page.txt"))
    let missingSpec = await Self.confirm(scenario, by: "user", spec: "absent.spec.txt")
    #expect(missingSpec.verdict.exitCode == 2, "\(missingSpec.message)")
    #expect(missingSpec.message.contains("absent.spec.txt"), "\(missingSpec.message)")

    let unknown = await Self.confirm(scenario, by: "reviewer", spec: "task-status.spec.txt")
    #expect(unknown.verdict.exitCode == 2)
    #expect(unknown.message.contains("spec-quotes"), "\(unknown.message)")

    let anonymous = await Self.confirm(
      scenario, session: nil, by: "user", spec: "task-status.spec.txt")
    #expect(anonymous.verdict.exitCode == 2)
    #expect(anonymous.message.contains("--session"), "\(anonymous.message)")

    #expect(try Self.state(scenario) == before)
  }

  @Test(
    "--json prints every key, null when absent, and a refusal's rule id — catches a key the skill reads going missing"
  )
  func jsonKeys() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    _ = try await Self.claimed(scenario, page: try Self.pageWithNoneSlice())

    let refused = await Self.confirm(
      scenario, by: "spec-quotes", spec: "recipient-postcode.spec.txt")
    let text = PlanConfirmRun.render(refused, format: .json)
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "\(text)")
    #expect(
      Set(object.keys)
        == [
          "command", "plan", "status", "verdict", "rule", "holder", "by", "confirm", "pageSha",
          "findings", "message",
        ])
    #expect(object["command"] as? String == "plan confirm")
    #expect(object["status"] as? String == "refused")
    #expect(object["verdict"] as? String == "RED")
    #expect(object["rule"] as? String == "plan-confirm.needs-user")
    #expect(object["confirm"] as? String == "required")
    #expect(object["by"] as? String == "spec-quotes")
    #expect(object["holder"] is NSNull)

    let human = PlanConfirmRun.render(refused, format: .human)
    #expect(human.hasPrefix("plan confirm: RED plan-confirm.needs-user"), "\(human)")
  }

  @Test(
    "plan confirm parses its documented arguments and resolves to its own leaf — catches a skill calling an unregistered command"
  )
  func registered() async throws {
    let parsed = try await SwiftGate.asyncParseAsRoot([
      "plan", "confirm", Self.plan, "--by", "user", "--spec", "spec.md", "--session", "s1",
      "--json",
    ])
    #expect(type(of: parsed).configuration.commandName == "confirm")
  }
}
