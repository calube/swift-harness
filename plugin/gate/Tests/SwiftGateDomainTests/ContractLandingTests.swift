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

/// The third price-tracker trial's contract `e54fcd53` on base `c1388265`, gated GREEN at `slice`
/// as run `20261005T055628Z-0c95049d`. Its task's `Writes` named `App/InterviewStarterApp.swift`,
/// the composition root that reads `-harness-scenario`, but the Bash call writing it was denied, so
/// the commit left it as at the base. `seam/` holds that file as the fixer later wrote it.
enum PriceTracker3 {
  static let task = "tracker-contract"
  static let tip = "e54fcd5341014acd58b264d16991ce817d4421e0"
  static let base = "c138826543e4cb838a6ea0ff3147225b164cb86f"
  static let runID = "20261005T055628Z-0c95049d"
  static let appFile = "App/InterviewStarterApp.swift"
  static let directory = Fixture.directory.appending(
    path: "BrownfieldTrial/price-tracker-3-contract", directoryHint: .isDirectory)

  static func planText() throws -> String {
    try String(
      contentsOf: Fixture.directory.appending(path: "BrownfieldTrial/price-tracker-3-PLAN.md"),
      encoding: .utf8)
  }

  static func writes() throws -> [String] {
    let plan = try LivePlanParser.parse(try planText())
    return try #require(plan.tasks.first { $0.id == task }).writes
  }

  /// Each file under `folder` (`base`, `contract` or `seam`), by its repository path.
  static func files(_ folder: String) throws -> [String: String] {
    let root = directory.appending(path: folder, directoryHint: .isDirectory)
    let walker = try #require(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    var files: [String: String] = [:]
    for case let url as URL in walker where !url.hasDirectoryPath {
      let path = String(
        url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
      files[path] = try String(contentsOf: url, encoding: .utf8)
    }
    return files
  }

  /// The contract commit as the import reads it, with `extra` committed on top.
  static func commit(adding extra: [String: String] = [:]) throws -> ContractLanding.Commit {
    let base = try files("base")
    let changed = try files("contract").merging(extra) { _, new in new }
    let atTip = base.merging(changed) { _, new in new }
    return ContractLanding.Commit(
      tip: tip, base: Self.base, changedFiles: changed.keys.sorted(), files: atTip.keys.sorted(),
      appSources: atTip.filter { ContractLanding.isAppSource($0.key, appRoots: ["."]) })
  }

  static var done: ContractLanding.Outcome {
    .done(
      TaskReturn(
        task: task, outcome: .readyToMerge, commits: [tip],
        gate: TaskReturn.Gate(tier: .slice, verdict: .green, runID: runID), review: nil,
        testsAdded: [], notes: "landed", designConflict: nil))
  }
}

@Suite("contract landing checks the commit holds its writes and the scenario seam")
struct ContractLandingCommitTests {
  @Test(
    "the trial's contract commit leaves only the app file of its Writes untouched; its directory entries are not checked — catches a contract accepted without a file its Writes names, or a directory entry flagged as a missing file"
  )
  func trialContractMissesTheAppFile() throws {
    let commit = try PriceTracker3.commit()
    #expect(
      ContractLanding.unlandedWrites(
        try PriceTracker3.writes(), changedFiles: commit.changedFiles, files: commit.files)
        == [PriceTracker3.appFile])
  }

  @Test(
    "a directory written without its trailing slash and a glob are never flagged, while a missing literal file is — catches a write-set entry that names many files read as 1 file"
  )
  func directoriesAndGlobsAreNotFiles() {
    let changed = ["Sources/Feature/View.swift"]
    let files = changed + ["Sources/Other/Model.swift", "README.md"]
    #expect(
      ContractLanding.unlandedWrites(
        [
          "Sources/Feature", "Sources/Other", "Sources/*.swift", "Sources/Feature/View.swift",
          "README.md",
        ],
        changedFiles: changed, files: files) == ["README.md"])
  }

  @Test(
    "the trial's plan launches its flows through -harness-scenario, and the memos plan, with no such argument, does not — catches the seam demanded of a plan whose flows never pass it"
  )
  func trialPlanNeedsTheSeam() throws {
    #expect(
      ContractLanding.needsScenarioSeam(planText: try PriceTracker3.planText(), hasFlowRows: true))
    #expect(
      !ContractLanding.needsScenarioSeam(planText: try PriceTracker3.planText(), hasFlowRows: false)
    )
    let memos = try String(
      contentsOf: Fixture.directory.appending(path: "BrownfieldTrial/memos-4-PLAN.md"),
      encoding: .utf8)
    #expect(!ContractLanding.needsScenarioSeam(planText: memos, hasFlowRows: true))
  }

  @Test(
    "the contract's sources name -harness-scenario only in a doc comment, so they don't read it, while the fixer's composition root does — catches a comment describing the seam taken for the seam"
  )
  func docCommentIsNotTheSeam() throws {
    let contract = try #require(try PriceTracker3.commit().appSources)
    #expect(contract.values.contains { $0.contains(SimSession.scenarioArgument) })
    #expect(!ContractLanding.readsScenarioArgument(contract))
    let fixed = try #require(
      try PriceTracker3.commit(adding: PriceTracker3.files("seam")).appSources)
    #expect(ContractLanding.readsScenarioArgument(fixed))
  }

  @Test(
    "an app source is a Swift file under an xcode area's root outside any …Tests folder — catches a UI test passing the argument counted as the app reading it"
  )
  func appSourcesSkipTests() {
    #expect(ContractLanding.isAppSource(PriceTracker3.appFile, appRoots: ["."]))
    #expect(
      ContractLanding.isAppSource(
        "Packages/APIClient/Sources/APIClient/Scenarios.swift", appRoots: ["."]))
    #expect(!ContractLanding.isAppSource("UITests/LaunchFlowUITests.swift", appRoots: ["."]))
    #expect(
      !ContractLanding.isAppSource(
        "Packages/AppFeature/Tests/AppCoreTests/AppFeatureTests.swift", appRoots: ["."]))
    #expect(!ContractLanding.isAppSource("App/Info.plist", appRoots: ["."]))
    #expect(!ContractLanding.isAppSource("Server/main.swift", appRoots: ["App"]))
    #expect(ContractLanding.isAppSource("App/Root.swift", appRoots: ["App"]))
  }

  @Test(
    "the trial's GREEN contract stays pending naming the untouched app file and the missing seam, and lands once the seam commit adds it — catches the contract the trial accepted without its app seam"
  )
  func trialContractStaysPendingUntilTheSeamLands() throws {
    let writes = try PriceTracker3.writes()
    guard
      case .pending(let reason) = ContractLanding.checked(
        PriceTracker3.done, writes: writes, commit: try PriceTracker3.commit())
    else {
      Issue.record("the trial's contract without its app file was accepted")
      return
    }
    #expect(reason.contains(ContractLanding.unlandedWriteRuleID), "\(reason)")
    #expect(reason.contains("`\(PriceTracker3.appFile)`"), "\(reason)")
    #expect(reason.contains(ContractLanding.scenarioSeamRuleID), "\(reason)")
    #expect(reason.contains(SimSession.scenarioArgument), "\(reason)")
    #expect(
      ContractLanding.checked(
        PriceTracker3.done, writes: writes,
        commit: try PriceTracker3.commit(adding: PriceTracker3.files("seam"))) == PriceTracker3.done
    )
  }
}
