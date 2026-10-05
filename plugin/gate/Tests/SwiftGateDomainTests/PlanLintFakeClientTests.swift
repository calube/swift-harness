import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The price-tracker trial's plan as `plan import` accepted it: the requirements `plan.json`
/// holds, the table `validation.json` holds, and the tasks `PLAN.md` lists.
private enum PriceTrackerPlan {
  static let contract = "spec-contract"
  static let starter = [PlanLintValidation.AppArea(name: "InterviewStarter", root: ".")]
  static let trial = Fixture.directory.appending(
    path: "BrownfieldTrial", directoryHint: .isDirectory)

  static func text(_ name: String) throws -> String {
    try String(contentsOf: trial.appending(path: name), encoding: .utf8)
  }

  /// The files tracked at the trial's base commit.
  static var baseFiles: [String] {
    get throws {
      try text("price-tracker-1-base-files.txt").split(separator: "\n").map(String.init)
    }
  }

  static func findings(clientModules: [String]) throws -> [Finding] {
    let plan = try LivePlanParser.parse(try text("price-tracker-1-PLAN.md"))
    let table = try ValidationTableJSON.decode(
      Data(contentsOf: trial.appending(path: "price-tracker-1-validation.json")))
    let imported = try JSONSerialization.jsonObject(
      with: Data(contentsOf: trial.appending(path: "price-tracker-1-plan.json")))
    let requirements = try #require(
      ((imported as? [String: Any])?["livePlan"] as? [String: Any])?["requirements"]
        as? [[String: Any]]
    ).compactMap { $0["id"] as? String }
    return try PlanLintValidation.findings(
      table: table, requirements: requirements, taskIDs: Set(plan.tasks.map(\.id)),
      hasIOSArea: true, file: "validation.json",
      tasks: plan.tasks.map {
        PlanLintValidation.TaskWrites(id: $0.id, covers: $0.covers, writes: $0.writes)
      },
      appAreas: starter, contractTask: contract, clientModules: clientModules)
  }

  static func requirements(_ findings: [Finding], _ ruleID: String) -> [String] {
    findings.filter { $0.ruleID == ruleID }.map { String($0.message.prefix { $0 != " " }) }
  }
}

@Suite("plan-lint validation: a reducer's requirement is on screen, and a client fake removes a network obstacle")
struct PlanLintFakeClientTests {
  @Test(
    "the starter's base files hold 2 dependency-client modules, Packages/APIClient and Packages/LogClient, each named once at its outermost folder, and no *ClientLive or test folder — catches a repository whose injectable client goes unseen"
  )
  func starterClientModules() throws {
    #expect(
      PlanLintValidation.clientModules(in: try PriceTrackerPlan.baseFiles)
        == ["Packages/APIClient", "Packages/LogClient"])
    #expect(
      PlanLintValidation.clientModules(in: [
        "Sources/Engine/Engine.swift", "App/APIClient.md", "Tests/FooClientTests/A.swift",
      ]).isEmpty)
  }

  @Test(
    "the price-tracker trial's imported table: req-refresh, covered only by app-core writing AppCore/WatchlistFeature.swift, is screen-without-flow; req-load-states and req-chart-states, excused by network: while Packages/APIClient is in the app's area, are obstacle-fakeable; req-chart-cancel's system:, the client task's req-client and the contract's req-existing-tests stay clear — catches the trial's plan imported with error, retry and refresh journeys that a fake client could drive"
  )
  func priceTrackerNeedsFakeClientFlows() throws {
    let modules = PlanLintValidation.clientModules(in: try PriceTrackerPlan.baseFiles)

    let findings = try PriceTrackerPlan.findings(clientModules: modules)

    #expect(
      PriceTrackerPlan.requirements(findings, PlanLintValidation.screenWithoutFlowRuleID)
        == ["req-refresh"], "\(findings.map(\.message))")
    let fakeable = findings.filter { $0.ruleID == PlanLintValidation.obstacleFakeableRuleID }
    #expect(
      PriceTrackerPlan.requirements(fakeable, PlanLintValidation.obstacleFakeableRuleID)
        == ["req-load-states", "req-chart-states"], "\(findings.map(\.message))")
    #expect(fakeable.allSatisfy { $0.message.contains("`Packages/APIClient`") })
    #expect(fakeable.allSatisfy { $0.message.contains("`network:`") })
    #expect(fakeable.allSatisfy { $0.message.contains("launch argument") })
    #expect(findings.count == 3, "\(findings.map(\.message))")
    #expect(findings.allSatisfy { $0.severity == .major })
  }

  @Test(
    "with no client module in the repository, network: still excuses req-load-states and req-chart-states, and req-refresh is still on screen — catches a network obstacle refused where no fake could serve the flow"
  )
  func networkExcusesWithoutClient() throws {
    let findings = try PriceTrackerPlan.findings(clientModules: [])

    #expect(findings.map(\.ruleID) == [PlanLintValidation.screenWithoutFlowRuleID])
    #expect(
      PriceTrackerPlan.requirements(findings, PlanLintValidation.screenWithoutFlowRuleID)
        == ["req-refresh"])
  }

  @Test(
    "a client module outside the app's area leaves network: excusing, and only the network kind is refused: a hardware: reason with the client present still excuses — catches a fake demanded of a client the app can't select, or of an obstacle no client serves"
  )
  func fakeableOnlyInsideTheArea() throws {
    let elsewhere = [PlanLintValidation.AppArea(name: "app", root: "Packages/AppFeature")]
    let table = ValidationTable(
      rows: [],
      unitOnly: [
        .init(requirement: "req-a", reason: "network: the simulator can't fail a request"),
        .init(requirement: "req-b", reason: "hardware: needs a camera"),
      ])
    let tasks = [
      PlanLintValidation.TaskWrites(
        id: "core", covers: ["req-a", "req-b"],
        writes: ["Packages/AppFeature/Sources/AppCore/ScanFeature.swift"])
    ]
    func findings(_ modules: [String]) throws -> [Finding] {
      try PlanLintValidation.findings(
        table: table, requirements: ["req-a", "req-b"], taskIDs: ["core"], hasIOSArea: true,
        file: "PLAN.md", tasks: tasks, appAreas: elsewhere, clientModules: modules)
        .filter { $0.ruleID != PlanLintValidation.appWithoutFlowRuleID }
    }

    #expect(try findings(["Packages/APIClient"]).isEmpty)
    let inside = try findings(["Packages/AppFeature/Sources/ScanClient"])
    #expect(inside.map(\.ruleID) == [PlanLintValidation.obstacleFakeableRuleID])
    #expect(inside.first?.message.hasPrefix("req-a ") == true, "\(inside.map(\.message))")
  }
}
