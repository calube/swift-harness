import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The fourth memos trial's contract: committed as `6fc0cb61` on `swift-harness/spec`, gated at
/// `slice` before the commit and at `merge` after it, both GREEN.
private enum Memos4 {
  static let task = "share-view-limit-contract"
  static let planBranch = "swift-harness/spec"
  static let contractCommit = "6fc0cb61bbcb569586d7c60bd7765126ec7912cb"
  static let base = "0d989707f82c33f74bb852edd8965ec88fcf041b"
  static let mergeGate = "20261004T141215Z-31ad3958"
  static let preCommitSlice = "20261004T141123Z-945b3a7e"
  static let doctor = "20261004T141210Z-00ea6cf2"
  static let redSlice = "20261004T124744Z-9d7ec113"

  static func history() throws -> [RunHistoryRecord] {
    let directory = Fixture.directory.appending(path: "BrownfieldTrial")
    let lines = try ["memos-4-history.jsonl", "memos-3-red-slice.history.jsonl"].map {
      try Data(contentsOf: directory.appending(path: $0))
    }
    let decoded = lines.map(RunHistoryJSON.decode)
    #expect(decoded.allSatisfy { $0.invalidLines == 0 })
    return decoded.flatMap(\.records)
  }

  static func outcome(_ runID: String, tip: String? = contractCommit) throws
    -> ContractLanding.Outcome
  {
    ContractLanding.outcome(
      task: task, runID: runID, history: try history(), planBranch: planBranch,
      planBranchTip: tip)
  }
}

@Suite("contract landing")
struct ContractLandingTests {
  @Test(
    "a GREEN gate run of the plan branch tip makes the contract a done return citing that commit and run — catches a landed contract left pending after import"
  )
  func greenGateAtTipIsDone() throws {
    guard case .done(let taskReturn) = try Memos4.outcome(Memos4.mergeGate) else {
      Issue.record("the memos-4 contract's GREEN merge gate left it pending")
      return
    }
    #expect(taskReturn.task == Memos4.task)
    #expect(taskReturn.outcome == .readyToMerge)
    #expect(taskReturn.commits == [Memos4.contractCommit])
    #expect(
      taskReturn.gate == TaskReturn.Gate(tier: .merge, verdict: .green, runID: Memos4.mergeGate))
    #expect(taskReturn.designConflict == nil)
    #expect(taskReturn.notes.contains(Memos4.contractCommit))
    #expect(taskReturn.notes.contains(Memos4.planBranch))
  }

  @Test(
    "a RED gate run keeps the contract pending and says so — catches import marking it done with a RED gate"
  )
  func redGateStaysPending() throws {
    guard
      case .pending(let reason) = try Memos4.outcome(
        Memos4.redSlice, tip: "f975b462c8db9705a19db48782c0c723da45a3a3")
    else {
      Issue.record("a RED slice made the contract done")
      return
    }
    #expect(reason.contains(Memos4.redSlice))
    #expect(reason.contains("RED"))
  }

  @Test(
    "a GREEN gate run made before the commit, at the base, keeps the contract pending — catches a gate that never saw the contract commit"
  )
  func preCommitGateStaysPending() throws {
    guard case .pending(let reason) = try Memos4.outcome(Memos4.preCommitSlice) else {
      Issue.record("the slice run at the base made the contract done")
      return
    }
    #expect(reason.contains(Memos4.base))
    #expect(reason.contains(Memos4.contractCommit))
  }

  @Test(
    "a gate run of a tip that moved past it keeps the contract pending — catches a later commit riding on an older gate"
  )
  func movedTipStaysPending() throws {
    let tip = "a00308810b883b7e3de7bebd0b8bd80fb63a6063"
    guard case .pending(let reason) = try Memos4.outcome(Memos4.mergeGate, tip: tip) else {
      Issue.record("a gate of 6fc0cb61 vouched for a later tip")
      return
    }
    #expect(reason.contains(tip))
  }

  @Test(
    "a run that is not a brownfield check, or not in the history, or a missing plan branch keeps the contract pending — catches a doctor run or a typo standing in for a gate"
  )
  func nonGateRunsStayPending() throws {
    for (runID, tip, expected) in [
      (Memos4.doctor, Memos4.contractCommit, "doctor"),
      ("20261004T000000Z-00000000", Memos4.contractCommit, "20261004T000000Z-00000000"),
      (Memos4.mergeGate, nil, Memos4.planBranch),
    ] {
      guard case .pending(let reason) = try Memos4.outcome(runID, tip: tip) else {
        Issue.record("\(runID) made the contract done")
        continue
      }
      #expect(reason.contains(expected), "\(reason)")
    }
  }
}
