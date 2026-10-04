import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// Answers each check with 1 captured `swift test` run from `SwiftTest/`: its exit status, stdout
/// and stderr, and, unless `writesReport` is false, its reports copied to `$QA_JUNIT` and the
/// companion path beside it, as `--xunit-output "$QA_JUNIT"` writes them.
private final class ReplayedSwiftTest: QACheckRunning {
  private let requests = Mutex<[QACheckRequest]>([])
  let scenario: String
  let writesReport: Bool

  init(_ scenario: String, writesReport: Bool = true) {
    self.scenario = scenario
    self.writesReport = writesReport
  }

  var recorded: [QACheckRequest] { requests.withLock { $0 } }

  func run(_ request: QACheckRequest) async -> QACheckOutput {
    requests.withLock { $0.append(request) }
    do {
      if writesReport, let junit = request.environment[QACheckJudgement.reportVariable] {
        for (name, path) in [
          ("\(scenario).xml", junit),
          ("\(scenario)-swift-testing.xml", JUnitReports.companionPaths(of: junit)[0]),
        ] {
          try Fixture.data("SwiftTest/\(name)").write(to: URL(filePath: path))
        }
      }
      let status = try Fixture.text("SwiftTest/\(scenario).status")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return QACheckOutput(
        exit: .exited(Int32(status) ?? -1), stdout: try Fixture.text("SwiftTest/\(scenario).stdout"),
        stderr: try Fixture.text("SwiftTest/\(scenario).stderr"))
    } catch {
      return QACheckOutput(exit: .launchFailed("replaying \(scenario): \(error)"))
    }
  }
}

@Suite("qa run counts the tests an acceptance check ran")
struct QARunTestCountTests {
  static let id = "ProbeTests.ResetTests/testResetShowsZero"

  /// A brownfield config with 1 SwiftPM area whose narrowed test command writes `{junit}`.
  static let config = """
    schema = 1

    [harness]
    profile = "brownfield"

    [brownfield]
    discovered_at = "3091ef26e593d303e34afed70bc8c5997c105f80"
    slice_budget_s = 30
    time_budget_min = 0
    sensitive = []

    [[areas]]
    name = "Probe"
    root = "."
    language = "swift"
    kind = "swiftpm"
    test = "swift test --parallel --xunit-output {junit}"
    test_files = "swift test --parallel --filter {tests} --xunit-output {junit}"
    test_globs = ["Tests/**/*.swift"]
    packs = []
    """

  /// A repository on a `feature` branch 1 commit past `main`, with `rows` under task `f`.
  static func featureRepo(_ rows: [ValidationRow], brownfield: Bool = false) async throws
    -> QARepo
  {
    let repo = try await QARepo()
    // A brownfield clone's merge base is taken against its plan branch.
    try await repo.git("branch", BrownfieldRunReport.planBranch(slug: QARepo.slug))
    try await repo.git("checkout", "-q", "-b", "feature")
    try Data("new\n".utf8).write(to: repo.root.appending(path: "feature.txt"))
    try await repo.git("add", "-A")
    try await repo.git("commit", "-q", "-m", "feature")
    if brownfield {
      try Data(config.utf8).write(to: repo.root.appending(path: ".git/swift-harness/config.toml"))
    }
    try repo.plan(rows, tasks: ["f": .done])
    return repo
  }

  @Test(
    "a `test:` row whose filter matched nothing (captured swift test: exit 0, tests=\"0\") is red at the merge base and unverified after the merge, naming the id — catches --at-base passing a test that exists only on the branch"
  )
  func testFormRanNoTest() async throws {
    let repo = try await Self.featureRepo(
      [validationRow("req-reset", .acceptance, "test: \(Self.id)", after: ["f"])],
      brownfield: true)
    defer { repo.remove() }
    let base = ReplayedSwiftTest("no-match")
    let merged = ReplayedSwiftTest("no-match")

    let atBase = await repo.run(QARunRun.Options(atBase: true), checks: base)
    let after = await repo.run(QARunRun.Options(), suffix: 2, checks: merged)

    #expect(atBase.rows.map(\.result) == [.red], "\(atBase.message) \(atBase.rows.map(\.message))")
    #expect(atBase.rows.first?.message.contains("no test matched `\(Self.id)`") == true)
    #expect(!atBase.findings.map(\.ruleID).contains(QAReport.checkPassesAtBaseRuleID))
    #expect(after.rows.map(\.result) == [.unverified], "\(after.rows.map(\.message))")
    #expect(after.rows.first?.message.contains("no test matched `\(Self.id)`") == true)
    #expect(after.findings.map(\.ruleID) == [QAReport.checkUnverifiedRuleID])
    let junit = try #require(base.recorded.first?.environment[QACheckJudgement.reportVariable])
    #expect(base.recorded.first?.program == .command(
      "swift test --parallel --filter '\(Self.id)' --xunit-output '\(junit)'"))
  }

  @Test(
    "a plain command that wrote its swift test report to $QA_JUNIT and ran no test is red at base and unverified after — catches a report of 0 tests read as a pass"
  )
  func plainCommandReportRanNoTest() async throws {
    let check = "swift test --parallel --filter 'ProbeTests\\.NoSuchTest' --xunit-output \"$QA_JUNIT\""
    let repo = try await Self.featureRepo([
      validationRow("req-reset", .acceptance, check, after: ["f"])
    ])
    defer { repo.remove() }

    let atBase = await repo.run(QARunRun.Options(atBase: true), checks: ReplayedSwiftTest("no-match"))
    let after = await repo.run(QARunRun.Options(), suffix: 2, checks: ReplayedSwiftTest("no-match"))

    #expect(atBase.rows.map(\.result) == [.red], "\(atBase.message) \(atBase.rows.map(\.message))")
    #expect(atBase.rows.first?.message.contains("no test matched") == true)
    #expect(after.rows.map(\.result) == [.unverified], "\(after.rows.map(\.message))")
    #expect(after.rows.first?.message.contains("no test matched `\(check)`") == true)
  }

  @Test(
    "a plain command that wrote no report keeps exit-status semantics: the same captured exit 0 passes — catches every command row asked for a test report"
  )
  func plainCommandWithoutReportPasses() async throws {
    let repo = try await Self.featureRepo([
      validationRow("req-reset", .acceptance, "swift test --filter NoSuchTest", after: ["f"])
    ])
    defer { repo.remove() }

    let report = await repo.run(
      QARunRun.Options(), checks: ReplayedSwiftTest("no-match", writesReport: false))

    #expect(report.rows.map(\.result) == [.pass], "\(report.rows.map(\.message))")
  }

  @Test(
    "a red row with a report names its first real failure message, skipping XCTest's placeholder `failure` — catches a red row whose message is only `exit 1`"
  )
  func redRowNamesReportFailure() async throws {
    let repo = try await Self.featureRepo(
      [validationRow("req-reset", .acceptance, "test: \(Self.id)", after: ["f"])],
      brownfield: true)
    defer { repo.remove() }

    let report = await repo.run(QARunRun.Options(), checks: ReplayedSwiftTest("fail"))

    #expect(report.rows.map(\.result) == [.red])
    #expect(
      report.rows.first?.message == "exit 1: Expectation failed: (double(3) → 6) == 7 (error)",
      "\(report.rows.map(\.message))")
  }

  @Test(
    "a red row with no report names its last non-empty stderr line, with the run's own paths made relative — catches a red row whose message is only `exit 1`"
  )
  func redRowNamesLastStderrLine() async throws {
    let check =
      "echo progress; echo 'first' >&2; "
      + "echo \"want 1 2 0, got 0 1 0 in $QA_EVIDENCE_DIR/logs/os.log\" >&2; echo >&2; exit 1"
    let repo = try await Self.featureRepo([
      validationRow("req-reset", .acceptance, check, after: ["f"])
    ])
    defer { repo.remove() }

    let report = await repo.run(QARunRun.Options())

    #expect(report.rows.map(\.result) == [.red])
    #expect(
      report.rows.first?.message == "exit 1: want 1 2 0, got 0 1 0 in logs/os.log",
      "\(report.rows.map(\.message))")
    #expect(report.rows.first?.exitStatus == 1)
  }
}
