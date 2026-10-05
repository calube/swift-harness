import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The sixth send-money trial's account-client fixer edited the contacts screen, which
/// contacts-feature had merged, after a combined run over account-client and amount-feature was
/// RED in the contact-search row; its return read `outside-write-set-unexplained`.
@Suite("fixer write set from recorded plan state")
struct FixerWriteSetTests {
  @Test(
    "account-client's fixer is credited contacts-feature, merged with its branch gone, and amount-feature, the branch its red run took in, so its edit to the contacts screen is inside its write set, while with no red run it isn't — catches a carried or merged owner's files read as unexplained once its branch is deleted"
  )
  func creditsCarriedAndMergedOwners() throws {
    let ledger = try LedgerJSON.decode(Fixture.data("BrownfieldTrial/send-money-6-ledger.json"))
    let combined = try QAReportJSON.decode(
      Fixture.data("BrownfieldTrial/send-money-6-qa-combined-before-merge.json"))
    let changed = try Fixture.text("BrownfieldTrial/send-money-6-fix-account-client-files.txt")
      .split(separator: "\n").map(String.init)
    let own = try #require(ledger.tasks.first { $0.id == "account-client" })

    let credited = FixerWriteSet.credited(
      task: own.id, tasks: ledger.tasks, reports: [combined])
    let none = FixerWriteSet.credited(task: own.id, tasks: ledger.tasks, reports: [])

    #expect(Set(credited.map(\.id)) == ["contacts-feature", "amount-feature", "send-flow"])
    #expect(
      WriteSet.outsideChanges(changed, writeSet: own.writeSet + credited.flatMap(\.writeSet))
        == [])
    #expect(none.isEmpty)
    #expect(WriteSet.outsideChanges(changed, writeSet: own.writeSet) == changed)
  }
}
