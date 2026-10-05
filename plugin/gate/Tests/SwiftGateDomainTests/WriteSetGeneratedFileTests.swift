import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("generated files go with the package or project they belong to")
struct WriteSetGeneratedFileTests {
  struct TrialFix: Decodable {
    let task: String
    let writeSet: [String]
    let changed: [String]
    let notesName: [String]
  }

  /// The 2 merge fixers' returns a brownfield trial's `build check-return --fix` failed.
  static func trialFixes() throws -> [String: TrialFix] {
    let fixes = try JSONDecoder().decode(
      [TrialFix].self, from: Data(try Fixture.text("BrownfieldTrial/trial-fix-returns.json").utf8))
    return Dictionary(uniqueKeysWithValues: fixes.map { ($0.task, $0) })
  }

  /// The write-set rules `check-return --fix` gives the fix, with notes naming `notesName`.
  static func writeSetRules(_ fix: TrialFix) -> [TaskReturnFinding.Rule] {
    let taskReturn = TaskReturn(
      task: fix.task, outcome: .readyToMerge, commits: ["abc1"],
      gate: .init(tier: .merge, verdict: .green, runID: "r"), review: nil, testsAdded: [],
      notes: "Changed " + fix.notesName.joined(separator: " and "), designConflict: nil)
    let evidence = TaskReturnEvidence(
      branch: "p/fix-\(fix.task)", branchExists: true, commits: ["abc1": .onBranch],
      gateRun: .init(tier: .merge, verdict: .green, headCommit: "abc1full", dirty: false),
      taskGate: .merge, taskStatus: nil,
      filesOutsideWriteSet: WriteSet.outsideChanges(fix.changed, writeSet: fix.writeSet),
      explainedEditsAllowed: true, reviewRequired: false, taskGateStepsRequired: false,
      lastCommit: "abc1full")
    return TaskReturnCheck.findings(taskReturn, evidence: evidence).map(\.rule)
      .filter { [.outsideWriteSet, .outsideWriteSetUnexplained].contains($0) }
  }

  @Test(
    "the trial fixer whose notes named the package sources it fixed passes with the Package.resolved swift test wrote beside them — catches a RED check-return and a round trip for a lockfile no one wrote by hand"
  )
  func trialLockfileGoesWithItsPackage() throws {
    let fix = try #require(try Self.trialFixes()["root-flow"])
    #expect(fix.changed.contains("Packages/RecordClient/Package.resolved"))
    #expect(!fix.notesName.contains("Packages/RecordClient/Package.resolved"))
    #expect(Self.writeSetRules(fix) == [])
  }

  @Test(
    "the trial fixer's hand edit of a shared scheme in a project no write set names still needs its note — catches a generated-file rule wide enough to wave through a fixer emptying the scheme's test action"
  )
  func trialSchemeEditStillNeedsItsNote() throws {
    let fix = try #require(try Self.trialFixes()["keypad-rules"])
    #expect(Self.writeSetRules(fix) == [.outsideWriteSetUnexplained])
  }

  @Test(
    "a package's lockfile is inside when the write set writes in that package, and an Xcode project's shared schemes and package lockfile when it writes in that project — catches a worker's own test run or scheme save read as spreading"
  )
  func generatedFilesInsideTheirOwner() {
    #expect(
      WriteSet.outsideChanges(
        ["Packages/A/Package.resolved", "Packages/A/Sources/A/A.swift"],
        writeSet: ["Packages/A/Sources/"]) == [])
    #expect(
      WriteSet.outsideChanges(["Packages/A/Package.resolved"], writeSet: ["Packages/A/Package.swift"])
        == [])
    #expect(WriteSet.outsideChanges(["Package.resolved"], writeSet: ["Package.swift"]) == [])
    let project = [
      "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme",
      "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
      "App.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
    ]
    #expect(WriteSet.outsideChanges(project, writeSet: ["App.xcodeproj/project.pbxproj"]) == [])
    #expect(
      WriteSet.outsideChanges(
        ["App.xcworkspace/xcshareddata/swiftpm/Package.resolved"],
        writeSet: ["App.xcworkspace/contents.xcworkspacedata"]) == [])
  }

  @Test(
    "a lockfile or scheme of a package or project the write set never writes in stays outside, a root lockfile needs the root manifest, and a project's pbxproj is never generated — catches a rule that frees every lockfile and project file"
  )
  func generatedFilesOutsideTheirOwner() {
    #expect(
      WriteSet.outsideChanges(["Packages/B/Package.resolved"], writeSet: ["Packages/A/"])
        == ["Packages/B/Package.resolved"])
    #expect(
      WriteSet.outsideChanges(["Package.resolved"], writeSet: ["Sources/App/"])
        == ["Package.resolved"])
    #expect(
      WriteSet.outsideChanges(
        ["App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"], writeSet: ["App/AppView.swift"])
        == ["App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"])
    #expect(
      WriteSet.outsideChanges(
        ["App.xcodeproj/project.pbxproj"],
        writeSet: ["App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"])
        == ["App.xcodeproj/project.pbxproj"])
  }
}
