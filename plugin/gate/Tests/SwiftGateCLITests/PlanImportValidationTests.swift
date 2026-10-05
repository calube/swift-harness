import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway brownfield clone holding the fourth memos trial's `config.toml` and a `PLAN.md`,
/// all in 1 temp directory, so nothing reaches this checkout's common dir.
private struct ValidationClone {
  static let slug = "spec"
  static let trial = Fixture.directory.appending(
    path: "BrownfieldTrial", directoryHint: .isDirectory)

  /// The trial's plan with the `## Validation` section Opus wrote for it.
  static var capturedPlan: String {
    get throws {
      try String(contentsOf: trial.appending(path: "memos-4-validation-PLAN.md"), encoding: .utf8)
    }
  }

  static var planWithoutSection: String {
    get throws { try String(contentsOf: trial.appending(path: "memos-4-PLAN.md"), encoding: .utf8) }
  }

  /// An Xcode area, added to the trial's 2 areas before its presets.
  static let xcodeArea = """
    [[areas]]
    name = "ios"
    root = "ios"
    language = "swift"
    kind = "xcode"
    build = "xcodebuild build -project ios/Memos.xcodeproj -scheme Memos"
    test_globs = []
    packs = []

    [areas.xcode]
    project = "ios/Memos.xcodeproj"
    inclusion = "synchronized"
    schemes = ["Memos"]


    """

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ])

  /// - Parameter files: repository-relative paths committed empty beside `store.go`, such as a
  ///   trial's tracked files.
  init(
    plan: String, xcodeArea: Bool = false, config fixture: String = "memos-4-config.toml",
    files: [String] = []
  ) async throws {
    root = try TestTemporaryDirectory.make("swiftgate-validation").resolvingSymlinksInPath()
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try Data("package store\n".utf8).write(to: root.appending(path: "store.go"))
    for file in files {
      let url = root.appending(path: file)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: url)
    }
    try await git("add", "-A")
    try await git("commit", "-q", "-m", "base")
    var config = try String(
      contentsOf: Self.trial.appending(path: fixture), encoding: .utf8)
    if xcodeArea {
      let presets = try #require(config.range(of: "[build.presets.brownfield]"))
      config.insert(contentsOf: Self.xcodeArea, at: presets.lowerBound)
    }
    try FileManager.default.createDirectory(at: planDirectory, withIntermediateDirectories: true)
    try Data(config.utf8).write(to: root.appending(path: ".git/swift-harness/config.toml"))
    try write(plan: plan)
  }

  func remove() { TestTemporaryDirectory.remove(root) }

  var planDirectory: URL {
    root.appending(path: ".git/swift-harness/plans/\(Self.slug)", directoryHint: .isDirectory)
  }

  var validationFile: URL { planDirectory.appending(path: "validation.json") }

  func write(plan: String) throws {
    try Data(plan.utf8).write(to: planDirectory.appending(path: "PLAN.md"))
  }

  func run() async -> PlanImportReport {
    await PlanImportRun.run(
      slug: Self.slug, root: root, git: LiveGit(runner: runner, repositoryRoot: root.path))
  }

  func exists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: planDirectory.appending(path: name).path)
  }

  @discardableResult
  func git(_ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    return output.stdout.text
  }
}

/// `text` with `old` replaced once; fails the test when `old` isn't there.
private func replacing(_ old: String, with new: String, in text: String) throws -> String {
  let range = try #require(text.range(of: old), "`\(old)` not in the plan")
  return text.replacingCharacters(in: range, with: new)
}

/// The 1-based line of the first line of `text` that contains `needle`.
private func line(of needle: String, in text: String) -> Int? {
  text.split(separator: "\n", omittingEmptySubsequences: false).firstIndex {
    $0.contains(needle)
  }.map { $0 + 1 }
}

@Suite("plan import validation table")
struct PlanImportValidationTests {
  @Test(
    "the Aidoku trial's plan, whose acceptance row named a test source file, fails the import at that row with validation-check-source-file and writes nothing, and imports once the row names the test and req-prompt's reason names its obstacle — catches the row qa run later ran as a path and read red on exit 126"
  )
  func aidokuSourceFileCheckFailsImport() async throws {
    let captured = try String(
      contentsOf: ValidationClone.trial.appending(path: "aidoku-validation-2-PLAN.md"),
      encoding: .utf8)
    let clone = try await ValidationClone(
      plan: captured, config: "aidoku-validation-config.toml")
    defer { clone.remove() }

    let report = await clone.run()

    #expect(report.status == .invalid, "\(report.message)")
    #expect(report.verdict == .red)
    let row = try #require(
      line(of: "`AidokuTests/LargeDownloadConfirmationTests.swift`", in: captured))
    #expect(
      report.message.contains("line \(row): \(PlanLintValidation.checkSourceFileRuleID)"),
      "\(report.message)")
    #expect(report.message.contains("test: <Target>/<Class>"), "\(report.message)")
    #expect(!clone.exists("ledger.json"))
    #expect(!clone.exists("validation.json"))

    let named = try replacing(
      "`AidokuTests/LargeDownloadConfirmationTests.swift`",
      with: "`test: AidokuTests/LargeDownloadConfirmationTests`", in: captured)
    try clone.write(
      plan: try replacing(
        "| req-prompt | | | | | needs", with: "| req-prompt | | | | | data: needs", in: named))
    let fixed = await clone.run()
    #expect(fixed.status == .imported, "\(fixed.message)")
    let table = try ValidationTableJSON.decode(Data(contentsOf: clone.validationFile))
    #expect(
      table.rows.first { $0.layer == .acceptance }?.check
        == "test: AidokuTests/LargeDownloadConfirmationTests")
  }

  @Test(
    "the tic-tac-toe trial's plan, whose screen task's requirements have only XCUITest acceptance rows, fails the import with validation-screen-without-flow naming each requirement and writes nothing; with each row's reason naming an obstacle it still fails on app-without-flow alone, and imports once 1 row is a flow — catches a UI plan imported with no flow row"
  )
  func ticTacToeScreenWithoutFlowFailsImport() async throws {
    let captured = try String(
      contentsOf: ValidationClone.trial.appending(path: "tic-tac-toe-1-PLAN.md"),
      encoding: .utf8)
    let clone = try await ValidationClone(plan: captured, config: "tic-tac-toe-1-config.toml")
    defer { clone.remove() }

    let report = await clone.run()

    #expect(report.status == .invalid, "\(report.message)")
    #expect(report.verdict == .red)
    for requirement in ["req-board-screen", "req-status-text", "req-new-game"] {
      let row = try #require(line(of: "| \(requirement) | acceptance |", in: captured))
      #expect(
        report.message.contains(
          "line \(row): \(PlanLintValidation.screenWithoutFlowRuleID): \(requirement)"),
        "\(report.message)")
    }
    #expect(!clone.exists("ledger.json"))
    #expect(!clone.exists("validation.json"))

    let check = "`test: InterviewStarterUITests/GameFlowUITests` | ttt-screen | ttt-screen |"
    let reasoned = captured.replacingOccurrences(
      of: check + " |", with: check + " system: the app has no flow runner here |")
    try clone.write(plan: reasoned)
    let excused = await clone.run()
    #expect(excused.status == .invalid, "\(excused.message)")
    #expect(excused.message.contains(PlanLintValidation.appWithoutFlowRuleID), "\(excused.message)")
    #expect(!excused.message.contains(PlanLintValidation.screenWithoutFlowRuleID))

    try clone.write(
      plan: reasoned.replacingOccurrences(
        of: "| req-new-game | acceptance |", with: "| req-new-game | flow |"))
    let flowed = await clone.run()
    #expect(flowed.status == .imported, "\(flowed.message)")
  }

  @Test(
    "the send-money trial's plan, every row a reason naming unit tests, fails the import with app-without-flow and a screen-without-flow per screen requirement, but not for req-decimal-money, which only the --contract task's stub ties to a screen — catches the trial's plan imported with no flow for 4 screens"
  )
  func sendMoneyReasonOnlyPlanFailsImport() async throws {
    let captured = try String(
      contentsOf: ValidationClone.trial.appending(path: "send-money-1-PLAN.md"), encoding: .utf8)
    let clone = try await ValidationClone(plan: captured, config: "send-money-1-config.toml")
    defer { clone.remove() }

    let report = await PlanImportRun.run(
      slug: ValidationClone.slug, root: clone.root,
      git: LiveGit(runner: clone.runner, repositoryRoot: clone.root.path),
      contract: .init(task: "send-money-contract", runID: "20261005T013039Z-242c4c56"))

    #expect(report.status == .invalid, "\(report.message)")
    #expect(report.message.contains(PlanLintValidation.appWithoutFlowRuleID), "\(report.message)")
    let screens = report.message.components(
      separatedBy: PlanLintValidation.screenWithoutFlowRuleID + ": "
    ).dropFirst().map {
      String($0.prefix { $0 != " " })
    }
    #expect(
      screens == [
        "req-contact-search", "req-contact-select", "req-continue-rule", "req-confirm-send",
        "req-send-success", "req-send-failure", "req-replace-screen",
      ], "\(report.message)")
    #expect(!clone.exists("ledger.json"))
  }

  @Test(
    "the price-tracker trial's plan, in a clone holding the starter's tracked files, fails the import with screen-without-flow for req-refresh, which only the reducer task covers, and obstacle-fakeable for req-load-states and req-chart-states at their rows, and imports once those 3 are flow rows — catches the trial's plan that excused journeys a fake APIClient could drive"
  )
  func priceTrackerNetworkReasonsFailImport() async throws {
    let captured = try String(
      contentsOf: ValidationClone.trial.appending(path: "price-tracker-1-PLAN.md"),
      encoding: .utf8)
    let files = try String(
      contentsOf: ValidationClone.trial.appending(path: "price-tracker-1-base-files.txt"),
      encoding: .utf8
    ).split(separator: "\n").map(String.init)
    let clone = try await ValidationClone(
      plan: captured, config: "price-tracker-1-config.toml", files: files)
    defer { clone.remove() }
    func run() async -> PlanImportReport {
      await PlanImportRun.run(
        slug: ValidationClone.slug, root: clone.root,
        git: LiveGit(runner: clone.runner, repositoryRoot: clone.root.path),
        contract: .init(task: "spec-contract", runID: "20261005T025011Z-b9aa0eba"))
    }

    let report = await run()

    #expect(report.status == .invalid, "\(report.message)")
    #expect(report.verdict == .red)
    let refresh = try #require(line(of: "| req-refresh |", in: captured))
    #expect(
      report.message.contains(
        "line \(refresh): \(PlanLintValidation.screenWithoutFlowRuleID): req-refresh "),
      "\(report.message)")
    for requirement in ["req-load-states", "req-chart-states"] {
      let row = try #require(line(of: "| \(requirement) |", in: captured))
      #expect(
        report.message.contains(
          "line \(row): \(PlanLintValidation.obstacleFakeableRuleID): \(requirement) "),
        "\(report.message)")
    }
    #expect(report.message.contains("`Packages/APIClient`"), "\(report.message)")
    #expect(!clone.exists("ledger.json"))
    #expect(!clone.exists("validation.json"))

    var flowed = captured
    for (requirement, flow) in [
      ("req-load-states", "load-failure"), ("req-refresh", "refresh"),
      ("req-chart-states", "chart-failure"),
    ] {
      let old = try #require(
        captured.split(separator: "\n").first { $0.hasPrefix("| \(requirement) |") })
      flowed = try replacing(
        String(old),
        with: "| \(requirement) | flow | `qa/\(flow).flow.json` | launch-wiring | spec-validation | |",
        in: flowed)
    }
    try clone.write(plan: flowed)
    let fixed = await run()
    #expect(fixed.status == .imported, "\(fixed.message)")
  }

  @Test(
    "the second send-money trial's re-import, with no --contract but the landed contract's return in the plan's returns, lints exactly as an import naming the contract does, and no finding names the done contract's UITests write — catches a re-import that reads the contract as a screen task, which the orchestrator then hid by editing its Writes"
  )
  func reimportExcludesLandedContract() async throws {
    let captured = try String(
      contentsOf: ValidationClone.trial.appending(path: "send-money-2-reimport-PLAN.md"),
      encoding: .utf8)
    let clone = try await ValidationClone(plan: captured, config: "send-money-2-config.toml")
    defer { clone.remove() }
    let returns = clone.planDirectory.appending(path: "returns", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: returns, withIntermediateDirectories: true)
    try Data(
      contentsOf: ValidationClone.trial.appending(path: "send-money-2-contract-return.json")
    ).write(to: returns.appending(path: "send-money-contract.json"))
    let git = LiveGit(runner: clone.runner, repositoryRoot: clone.root.path)

    let named = await PlanImportRun.run(
      slug: ValidationClone.slug, root: clone.root, git: git,
      contract: .init(task: "send-money-contract", runID: "20261005T024943Z-c1163c48"))
    let reimported = await PlanImportRun.run(slug: ValidationClone.slug, root: clone.root, git: git)

    #expect(!reimported.message.contains("`send-money-contract` writes"), "\(reimported.message)")
    #expect(reimported.status == named.status, "\(reimported.message)")
    if named.status == .invalid {
      #expect(reimported.message == named.message)
    }
  }

  @Test(
    "the send-money plan with its Validation section deleted fails the import with 1 app-without-flow naming the InterviewStarter area and the missing section, and writes nothing — catches a screen plan that skips every flow rule by leaving the section out"
  )
  func sendMoneyWithoutSectionFailsImport() async throws {
    let captured = try String(
      contentsOf: ValidationClone.trial.appending(path: "send-money-1-no-validation-PLAN.md"),
      encoding: .utf8)
    #expect(!captured.contains("## Validation"))
    let clone = try await ValidationClone(plan: captured, config: "send-money-1-config.toml")
    defer { clone.remove() }

    let report = await PlanImportRun.run(
      slug: ValidationClone.slug, root: clone.root,
      git: LiveGit(runner: clone.runner, repositoryRoot: clone.root.path),
      contract: .init(task: "send-money-contract", runID: "20261005T013039Z-242c4c56"))

    #expect(report.status == .invalid, "\(report.message)")
    #expect(report.verdict == .red)
    #expect(
      report.message.components(separatedBy: PlanLintValidation.appWithoutFlowRuleID).count == 2,
      "\(report.message)")
    #expect(report.message.contains("`InterviewStarter`"), "\(report.message)")
    #expect(report.message.contains("`## Validation`"), "\(report.message)")
    #expect(!report.message.contains(PlanLintValidation.screenWithoutFlowRuleID))
    #expect(!clone.exists("ledger.json"))
    #expect(!clone.exists("validation.json"))
  }

  @Test(
    "the captured plan's Validation table imports every row into validation.json beside the ledger — catches a row dropped between PLAN.md and the file qa run reads"
  )
  func importsEveryRow() async throws {
    let clone = try await ValidationClone(plan: ValidationClone.capturedPlan)
    defer { clone.remove() }

    let report = await clone.run()

    #expect(report.status == .imported, "\(report.message)")
    #expect(report.validationRows == 7)
    #expect(report.notes.isEmpty, "\(report.notes)")
    let table = try ValidationTableJSON.decode(Data(contentsOf: clone.validationFile))
    #expect(table.schemaVersion == 1)
    #expect(
      table.rows.map(\.requirement) == [
        "req-limit-field", "req-limit-validation", "req-count-on-resolve",
        "req-exhausted-not-found", "req-list-counts", "req-migrations", "req-panel-choice",
      ])
    #expect(table.rows.allSatisfy { $0.layer == .acceptance })
    #expect(
      table.rows.first?.check
        == "DRIVER=sqlite go test ./server/api/v1/test/ -run 'TestCreateMemoShareViewLimitOptional'"
    )
    #expect(table.rows.first?.runsAfter == ["share-view-limit-contract", "share-view-limit-api"])
    #expect(table.rows.last?.writer == "share-view-limit-web")
    #expect(table.rows.map { $0.reason == nil } == [false, false, true, false, true, false, false])
    #expect(table.unitOnly.map(\.requirement) == ["req-panel-text"])
    #expect(clone.exists("ledger.json"))
  }

  @Test(
    "a row with layer unit fails the import naming its line, and writes nothing — catches a layer read as free text"
  )
  func unitLayerFailsImport() async throws {
    let plan = try replacing(
      "| req-limit-validation | acceptance |", with: "| req-limit-validation | unit |",
      in: ValidationClone.capturedPlan)
    let clone = try await ValidationClone(plan: plan)
    defer { clone.remove() }

    let report = await clone.run()

    #expect(report.status == .invalid)
    #expect(report.verdict == .red)
    let row = try #require(line(of: "| req-limit-validation | unit |", in: plan))
    #expect(report.message.contains("line \(row)"), "\(report.message)")
    #expect(report.message.contains("`unit`"))
    #expect(!clone.exists("ledger.json"))
    #expect(!clone.exists("validation.json"))
  }

  @Test(
    "a plan with no Validation section imports as before with a note, and a validation.json left by an earlier import goes — catches a silent drop of the checks"
  )
  func noSectionImportsWithNote() async throws {
    let clone = try await ValidationClone(plan: ValidationClone.capturedPlan)
    defer { clone.remove() }
    #expect(await clone.run().status == .imported)
    #expect(clone.exists("validation.json"))

    try clone.write(plan: ValidationClone.planWithoutSection)
    let report = await clone.run()

    #expect(report.status == .imported, "\(report.message)")
    #expect(report.verdict == .green)
    #expect(report.tasks == 4)
    #expect(report.validationRows == nil)
    #expect(report.notes.count == 1)
    #expect(report.notes.first?.contains("`## Validation`") == true)
    #expect(report.notes.first?.contains("removed") == true)
    #expect(!clone.exists("validation.json"))
    let json = PlanImportRun.render(report, json: true)
    #expect(json.contains("\"notes\""))
  }

  @Test(
    "each validation rule fails the import naming its rule id and writes nothing, and a flow row imports once the repository has an Xcode area — catches a lint finding that never reaches the brownfield run"
  )
  func lintFindingsFailImport() async throws {
    let captured = try ValidationClone.capturedPlan
    let panelText = try #require(
      captured.split(separator: "\n").first { $0.hasPrefix("| req-panel-text |") })
    let cases: [(String, String, String)] = [
      (
        PlanLintValidation.uncoveredRuleID, String(panelText) + "\n", ""
      ),
      (
        PlanLintValidation.unknownTaskRuleID,
        "| share-view-limit-web | share-view-limit-web |",
        "| share-view-limit-ui | share-view-limit-web |"
      ),
      (
        PlanLintValidation.stateWithoutFlowRuleID, "| req-migrations | acceptance |",
        "| req-migrations | state |"
      ),
      (
        PlanLintValidation.flowWithoutIOSRuleID, "| req-panel-choice | acceptance |",
        "| req-panel-choice | flow |"
      ),
    ]
    for (ruleID, old, new) in cases {
      let clone = try await ValidationClone(plan: try replacing(old, with: new, in: captured))
      defer { clone.remove() }
      let report = await clone.run()
      #expect(report.status == .invalid, "\(ruleID): \(report.message)")
      #expect(report.message.contains(ruleID), "\(ruleID): \(report.message)")
      #expect(!clone.exists("ledger.json"), "\(ruleID)")
      #expect(!clone.exists("validation.json"), "\(ruleID)")
    }

    let flow = try replacing(
      "| req-panel-choice | acceptance |", with: "| req-panel-choice | flow |", in: captured)
    let ios = try await ValidationClone(plan: flow, xcodeArea: true)
    defer { ios.remove() }
    let report = await ios.run()
    #expect(report.status == .imported, "\(report.message)")
    let table = try ValidationTableJSON.decode(Data(contentsOf: ios.validationFile))
    #expect(table.rows.last?.layer == .flow)
  }
}
