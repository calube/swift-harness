import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The sixth send-money trial's cutoff priced amount-feature's fix, whose branch held
/// account-client's unmerged branch, as if no validation row ran before its merge.
@Suite("cutoff: a fix branch that carries another task's branch")
struct CutoffCarriedBranchTests {
  static let mergedAtCutoff: Set<String> = [
    "spec-contract", "spec-validation", "contacts-feature", "amount-input", "send-flow",
  ]

  @Test(
    "the fix branch carrying account-client reads GREEN from the fixer's run over both, which passed every row amount-feature owns, not as needing no run — catches a cutoff reason that says no row runs before a merge that lands 5 rows' code"
  )
  func carriedBranchRowsCount() throws {
    let table = try ValidationTableJSON.decode(
      Fixture.data("BrownfieldTrial/send-money-6-validation.json"))
    let fixer = try QAReportJSON.decode(
      Fixture.data("BrownfieldTrial/send-money-6-qa-fixer-before-merge.json"))
    let merge = try #require(fixer.trialMerge)

    func standing(carried: [QATrialMerge.Branch]) -> CutoffQA {
      CutoffQA.of(
        table: table, merged: Self.mergedAtCutoff, plan: "spec", task: "amount-feature",
        reports: [fixer], branch: merge.branch, tip: merge.tip, base: merge.base,
        latestCheck: nil, carried: carried)
    }

    #expect(standing(carried: []) == .notNeeded)
    #expect(standing(carried: merge.alongside) == .green(runID: try #require(fixer.runID)))
  }
}

@Suite("qa run --deadline")
struct QARunDeadlineOptionTests {
  static let now = Date(timeIntervalSince1970: 1_791_000_000)

  @Test(
    "whole seconds count from now and an ISO 8601 time is taken as written, while words, 0 s and a time already past read as no deadline — catches a --deadline that silently bounds nothing or ends the run at once"
  )
  func parses() throws {
    let seconds = try #require(QARunDeadline.parse("160", now: Self.now))
    #expect(seconds.at == Self.now.addingTimeInterval(160))
    #expect(seconds.name == QARunDeadline.optionName)
    let iso = try #require(QARunDeadline.parse("2026-10-05T10:00:21Z", now: Self.now))
    #expect(iso.at == (try Date("2026-10-05T10:00:21Z", strategy: .iso8601)))
    #expect(QARunDeadline.parse("soon", now: Self.now) == nil)
    #expect(QARunDeadline.parse("0", now: Self.now) == nil)
    #expect(QARunDeadline.parse("2020-01-01T00:00:00Z", now: Self.now) == nil)
  }

  @Test(
    "the earlier of a box's cutoff and a --deadline bounds the run, whichever comes first — catches a --deadline that pushes a run past its box"
  )
  func earlierWins() {
    let box = QARunDeadline(at: Self.now.addingTimeInterval(300), name: "the run's cutoff")
    let option = QARunDeadline(at: Self.now.addingTimeInterval(160), name: QARunDeadline.optionName)
    #expect(QARunDeadline.earlier(box, option) == option)
    #expect(QARunDeadline.earlier(option, box) == option)
    #expect(QARunDeadline.earlier(nil, box) == box)
    #expect(QARunDeadline.earlier(nil, nil) == nil)
  }
}
