import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The fifth price-tracker trial. Its contract declared `AccessibilityID.Watchlist.bottom` as "a
/// 1 pt element pinned to the bottom safe area" without placing it; the watchlist worker added it
/// as the last `List` row, so the refresh drag pulled nothing; the fixer moved it into
/// `.safeAreaInset(edge: .bottom, spacing: 0)` and the refresh row passed.
private enum PriceTracker5 {
  static let view = "Packages/AppFeature/Sources/AppUI/WatchlistView.swift"

  static func plan() throws -> LivePlan {
    try LivePlanParser.parse(
      try String(
        contentsOf: Fixture.directory.appending(path: "BrownfieldTrial/price-tracker-5-PLAN.md"),
        encoding: .utf8))
  }

  /// `WatchlistView.swift` as `stage` (`contract`, `worker` or `fixer`) committed it.
  static func sources(_ stage: String) throws -> [String: String] {
    [
      view: try String(
        contentsOf: Fixture.directory.appending(
          path: "BrownfieldTrial/price-tracker-5-watchlist/\(stage)/\(view)"),
        encoding: .utf8)
    ]
  }

  static func refreshRows() throws -> [String] {
    let plan = try plan()
    let flows = try #require(plan.validation).table.rows.filter { $0.layer == .flow }
    return ContractLanding.refreshRequirements(
      flowRequirements: flows.map(\.requirement),
      titles: Dictionary(
        plan.requirements.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }))
  }

  static func commit(_ stage: String) throws -> ContractLanding.Commit {
    let sources = try sources(stage)
    return ContractLanding.Commit(
      tip: "c414b67c56e76c7743592eb26718bfc571177065",
      base: "15ef6183ec2c4965be3211acd4f06a4458a9d080", changedFiles: [view], files: [view],
      appSources: nil,
      refresh: ContractLanding.Refresh(requirements: try refreshRows(), sources: sources))
  }

  static let done = ContractLanding.Outcome.done(
    TaskReturn(
      task: "spec-contract", outcome: .readyToMerge,
      commits: ["c414b67c56e76c7743592eb26718bfc571177065"],
      gate: TaskReturn.Gate(tier: .slice, verdict: .green, runID: "20261005T093249Z-dfaf0bc0"),
      review: nil, testsAdded: [], notes: "landed", designConflict: nil))
}

@Suite("contract landing checks the refresh drag's bottom marker is pinned")
struct ContractLandingRefreshMarkerTests {
  @Test(
    "the trial plan's pull-to-refresh requirement is its 1 refresh flow row, and its retry and chart rows are not — catches a refresh row the marker check never asks about"
  )
  func trialPlanHasOneRefreshRow() throws {
    #expect(try PriceTracker5.refreshRows() == ["req-refresh"])
  }

  @Test(
    "the contract's stub view that only declares the id and the worker's view that adds it as the last List row pin nothing, while the fixer's .safeAreaInset(edge: .bottom) marker does — catches a drag target that scrolls with the rows"
  )
  func onlyTheSafeAreaInsetPins() throws {
    #expect(!ContractLanding.pinsBottomMarker(try PriceTracker5.sources("contract")))
    #expect(!ContractLanding.pinsBottomMarker(try PriceTracker5.sources("worker")))
    #expect(ContractLanding.pinsBottomMarker(try PriceTracker5.sources("fixer")))
  }

  @Test(
    "a bottom inset named only in a comment, and a top inset carrying the error banner's id, pin nothing — catches a described or wrong-edge marker taken for the pinned one"
  )
  func commentsAndTopInsetsDoNotPin() throws {
    let fixer = try #require(try PriceTracker5.sources("fixer")[PriceTracker5.view])
    let bottom = try #require(fixer.range(of: ".safeAreaInset(edge: .bottom"))
    let topOnly = fixer.replacingCharacters(in: bottom, with: "// .safeAreaInset(edge: .bottom")
    #expect(topOnly.contains(".safeAreaInset(edge: .top"))
    #expect(!ContractLanding.pinsBottomMarker([PriceTracker5.view: topOnly]))
  }

  @Test(
    "the trial's GREEN contract stays pending under plan-import.refresh-marker-unplaced naming req-refresh, and so does the worker's List-row marker, while the fixer's pinned marker lands it — catches the contract the trial imported with its marker unplaced"
  )
  func trialContractStaysPendingUntilTheMarkerIsPinned() throws {
    for stage in ["contract", "worker"] {
      guard
        case .pending(let reason) = ContractLanding.checked(
          PriceTracker5.done, writes: [], commit: try PriceTracker5.commit(stage))
      else {
        Issue.record("the \(stage) view's unpinned marker was accepted")
        continue
      }
      #expect(reason.contains(ContractLanding.refreshMarkerRuleID), "\(reason)")
      #expect(reason.contains("req-refresh"), "\(reason)")
      #expect(reason.contains(".safeAreaInset(edge: .bottom"), "\(reason)")
    }
    #expect(
      ContractLanding.checked(
        PriceTracker5.done, writes: [], commit: try PriceTracker5.commit("fixer"))
        == PriceTracker5.done)
  }
}
