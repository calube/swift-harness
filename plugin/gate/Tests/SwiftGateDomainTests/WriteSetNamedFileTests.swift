import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("a fixer's notes name an edit outside its write set by any path ending that fits 1 changed file")
struct WriteSetNamedFileTests {
  /// The write-set rules `check-return --fix` gives `taskReturn`, whose branch changed `changed`.
  static func writeSetRules(
    _ taskReturn: TaskReturn, changed: [String], writeSet: [String]
  ) -> [TaskReturnFinding.Rule] {
    let evidence = TaskReturnEvidence(
      branch: "p/fix-\(taskReturn.task)", branchExists: true,
      commits: Dictionary(uniqueKeysWithValues: taskReturn.commits.map { ($0, .onBranch) }),
      gateRun: .init(tier: .slice, verdict: .green, headCommit: "full", dirty: false),
      taskGate: .slice, taskStatus: nil,
      filesOutsideWriteSet: WriteSet.outsideChanges(changed, writeSet: writeSet),
      changedFiles: changed, explainedEditsAllowed: true, reviewRequired: false,
      taskGateStepsRequired: false, lastCommit: "full")
    return TaskReturnCheck.findings(taskReturn, evidence: evidence).map(\.rule)
      .filter { [.outsideWriteSet, .outsideWriteSetUnexplained].contains($0) }
  }

  static func fixReturn(notes: String) -> TaskReturn {
    TaskReturn(
      task: "views", outcome: .readyToMerge, commits: ["abc1"],
      gate: .init(tier: .slice, verdict: .green, runID: "r"), review: nil, testsAdded: [],
      notes: notes, designConflict: nil)
  }

  @Test(
    "send-money-4's fixer, whose notes say only AppView.swift changed, explains the 1 file it changed outside send-flow-core's write set — catches a correct fix sent back RED for naming its file without the repo path"
  )
  func trialFixerNamedItsFileByName() throws {
    let folder = "BuildReturn/send-money-4"
    let taskReturn = try TaskReturnJSON.decode(try Fixture.data("\(folder)/fix-send-flow-core.json"))
    let changed = try Fixture.text("\(folder)/fix-send-flow-core.changed.txt")
      .split(whereSeparator: \.isNewline).map(String.init)
    let writeSet = try JSONDecoder().decode(
      [String].self, from: try Fixture.data("\(folder)/send-flow-core.write-set.json"))
    let outside = "Packages/AppFeature/Sources/AppUI/AppView.swift"
    #expect(WriteSet.outsideChanges(changed, writeSet: writeSet) == [outside])
    #expect(!taskReturn.notes.contains(outside))

    #expect(Self.writeSetRules(taskReturn, changed: changed, writeSet: writeSet) == [])
  }

  @Test(
    "a path ending that fits 2 changed files, or a file name only part of a longer name, explains nothing — catches a bare name waving through a second file of the same name"
  )
  func ambiguousOrPartialNamesExplainNothing() {
    let changed = [
      "Packages/Feature/Sources/UI/AppView.swift", "Packages/Other/Sources/UI/AppView.swift",
      "Packages/Feature/Sources/Core/Store.swift",
    ]
    let writeSet = ["Packages/Feature/Sources/Core/"]
    #expect(
      Self.writeSetRules(Self.fixReturn(notes: "Only AppView.swift changed."), changed: changed,
        writeSet: writeSet) == [.outsideWriteSetUnexplained])
    #expect(
      Self.writeSetRules(
        Self.fixReturn(notes: "Changed Feature/Sources/UI/AppView.swift and Other/Sources/UI/AppView.swift."),
        changed: changed, writeSet: writeSet) == [])

    let one = ["Packages/Feature/Sources/UI/AppView.swift", "Packages/Feature/Sources/Core/Store.swift"]
    #expect(
      Self.writeSetRules(Self.fixReturn(notes: "Only MyAppView.swift changed."), changed: one,
        writeSet: writeSet) == [.outsideWriteSetUnexplained])
    #expect(
      Self.writeSetRules(Self.fixReturn(notes: "Only UI/AppView.swift changed."), changed: one,
        writeSet: writeSet) == [])
  }
}
