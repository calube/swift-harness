import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `build finish` run from the user's checkout of a brownfield clone, as pos-checkout-1's
/// orchestrator ran it, while the final `qa run` is still in the plan checkout's own store.
@Suite("build finish reads the qa runs of every checkout")
struct BuildFinishStoresTests {
  static let finalRun = "20261005T124225Z-b49370a4"
  static let slug = "spec"

  /// pos-checkout-1's `plan.json` and `validation.json` as plan `spec`'s state in `scenario`'s
  /// clone: a live plan with a validation table.
  static func writePlan(in scenario: PlanBranchScenario) throws -> PlanStateLayout.Plan {
    let plan = try PlanStateLayout(commonDirectory: scenario.common).plan(slug)
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    try Fixture.data("BrownfieldTrial/pos-checkout-1-plan.json")
      .write(to: URL(filePath: plan.directory + "/plan.json"))
    try Fixture.data("BrownfieldTrial/pos-checkout-1-validation.json")
      .write(to: URL(filePath: plan.directory + "/" + ValidationTable.fileName))
    return plan
  }

  /// The trial's final qa run report, written into `checkout`'s own runs.
  static func writeFinalRun(in checkout: String) throws {
    let file = RunStore(worktreeRoot: URL(filePath: checkout, directoryHint: .isDirectory)).state
      .url(RunLayout.runsDirectory, directoryHint: .isDirectory)
      .appending(path: "\(finalRun)/\(QAReport.directory)/\(QAReport.fileName)")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Fixture.data("BrownfieldTrial/pos-checkout-1-final-qa-report.json").write(to: file)
  }

  @Test(
    "finish from the user's checkout reads pos-checkout-1's GREEN final run b49370a4 from the plan checkout's store and records it — catches a finish that asks for a qa run --final that already exists"
  )
  func finishReadsThePlanCheckoutsFinalRun() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let plan = try Self.writePlan(in: scenario)
    try Self.writeFinalRun(in: scenario.checkout)

    let read = BuildFinishRun.newestValidation(
      plan: plan, slug: Self.slug, root: scenario.user, qaRun: Self.finalRun)

    let validation = try read.get()
    #expect(validation?.runID == Self.finalRun)
    #expect(validation?.verdict == .green)
  }

  @Test(
    "finish with no final run in any checkout refuses and names each store it searched, the user's and the plan checkout's — catches a refusal that leaves the orchestrator guessing where the run went"
  )
  func missingRunNamesTheStoresSearched() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let plan = try Self.writePlan(in: scenario)

    let read = BuildFinishRun.newestValidation(
      plan: plan, slug: Self.slug, root: scenario.user, qaRun: Self.finalRun)

    guard case .failure(let refusal) = read else {
      Issue.record("expected a refusal, got \(read)")
      return
    }
    let stores = QARunHistory.runsDirectories(
      sharing: URL(filePath: scenario.checkout, directoryHint: .isDirectory))
    #expect(stores.count >= 2, "\(stores)")
    for store in stores {
      #expect(refusal.message.contains(store.standardizedFileURL.path), "\(refusal.message)")
    }
    #expect(refusal.message.contains("qa run --plan spec --final"), "\(refusal.message)")
  }
}
