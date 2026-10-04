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

  init(plan: String, xcodeArea: Bool = false) async throws {
    root = try TestTemporaryDirectory.make("swiftgate-validation").resolvingSymlinksInPath()
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try Data("package store\n".utf8).write(to: root.appending(path: "store.go"))
    try await git("add", "-A")
    try await git("commit", "-q", "-m", "base")
    var config = try String(
      contentsOf: Self.trial.appending(path: "memos-4-config.toml"), encoding: .utf8)
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
