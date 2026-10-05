import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// Answers each check with the exit status of 1 captured `xcodebuild test` run from
/// `Xcresult/<scenario>.status`, as the row's `-only-testing:` command would end.
private final class ReplayedXcodebuild: QACheckRunning {
  private let requests = Mutex<[QACheckRequest]>([])
  let scenario: String

  init(_ scenario: String) {
    self.scenario = scenario
  }

  var recorded: [QACheckRequest] { requests.withLock { $0 } }

  func run(_ request: QACheckRequest) async -> QACheckOutput {
    requests.withLock { $0.append(request) }
    do {
      let status = try Fixture.text("Xcresult/\(scenario).status")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return QACheckOutput(exit: .exited(Int32(status) ?? -1))
    } catch {
      return QACheckOutput(exit: .launchFailed("replaying \(scenario): \(error)"))
    }
  }
}

@Suite("qa run counts the tests an xcode acceptance check ran")
struct QARunXcodeTestCountTests {
  static let id = "CounterUISnapshotTests/ProbePassXCTests/testNoSuchTest"
  static let test =
    "xcodebuild test -scheme CounterFeature-Package -destination 'platform=iOS Simulator,name=iPhone 17'"

  /// A brownfield config with 1 `xcode` area, whose test command takes `-only-testing:`.
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
    name = "App"
    root = "."
    language = "swift"
    kind = "xcode"
    test = "\(test)"
    test_globs = ["Tests/**/*.swift"]
    packs = []

    [areas.xcode]
    workspace = "App.xcworkspace"
    inclusion = "synchronized"
    schemes = ["App"]
    """

  static func repo() async throws -> QARepo {
    let repo = try await QARunTestCountTests.featureRepo([
      validationRow("req-reset", .acceptance, "test: \(id)", after: ["f"])
    ])
    try Data(config.utf8).write(to: repo.root.appending(path: ".git/swift-harness/config.toml"))
    return repo
  }

  @Test(
    "a `test:` row in an xcode area whose captured bundle ran no test (xcodebuild exit 0) is red at base and unverified after, and its command writes the bundle under the run's qa folder — catches -only-testing on a missing test passing at the merge base"
  )
  func noTestRan() async throws {
    let repo = try await Self.repo()
    defer { repo.remove() }
    let base = ReplayedXcodebuild("missing-test")

    let atBase = await repo.run(
      QARunRun.Options(atBase: true), checks: base,
      xcresults: FakeXcresultReader(scenario: "missing-test"))
    let after = await repo.run(
      QARunRun.Options(), suffix: 2, checks: ReplayedXcodebuild("missing-test"),
      xcresults: FakeXcresultReader(scenario: "missing-test"))

    #expect(atBase.rows.map(\.result) == [.red], "\(atBase.message) \(atBase.rows.map(\.message))")
    #expect(atBase.rows.first?.message == "exit 0, but no test matched `\(Self.id)`")
    #expect(after.rows.map(\.result) == [.unverified], "\(after.rows.map(\.message))")
    // A brownfield checkout keeps its runs under the git common dir.
    let bundle = repo.root.appending(
      path:
        ".git/swift-harness/runs/\(try #require(atBase.runID))/qa/01-req-reset.acceptance.xcresult"
    ).path
    #expect(
      base.recorded.first?.program
        == .command(Self.test + " -only-testing:'\(Self.id)' -resultBundlePath '\(bundle)'"))
  }

  @Test(
    "a `test:` row in an xcode area whose captured bundle ran 1 passing test passes, says 1 test passed and lists the bundle and its saved test summary beside its output as evidence — catches a row read as running nothing, a pass whose only evidence is `exit 0`, and a report with nothing small to link in the bundle's place"
  )
  func oneTestPasses() async throws {
    let repo = try await Self.repo()
    defer { repo.remove() }

    let report = await repo.run(
      QARunRun.Options(), checks: ReplayedXcodebuild("one-test"),
      xcresults: FakeXcresultReader(scenario: "one-test"))

    #expect(report.rows.map(\.result) == [.pass], "\(report.rows.map(\.message))")
    #expect(report.rows.first?.message == "exit 0, 1 test passed")
    #expect(
      report.rows.first?.evidence
        == [
          "qa/01-req-reset.acceptance.txt", "qa/01-req-reset.acceptance.xcresult",
          "qa/01-req-reset.acceptance.tests.json",
        ])
    let summary = repo.root.appending(
      path:
        ".git/swift-harness/runs/\(try #require(report.runID))/qa/01-req-reset.acceptance.tests.json"
    )
    #expect(try Data(contentsOf: summary) == (try Fixture.data("Xcresult/one-test.tests.json")))
  }

  @Test(
    "a red `test:` row in an xcode area names its captured bundle's first failure message — catches a red row whose message is only `exit 65`"
  )
  func redRowNamesBundleFailure() async throws {
    let repo = try await Self.repo()
    defer { repo.remove() }

    let report = await repo.run(
      QARunRun.Options(), checks: ReplayedXcodebuild("fail"),
      xcresults: FakeXcresultReader(scenario: "fail"))

    #expect(report.rows.map(\.result) == [.red])
    #expect(
      report.rows.first?.message
        == "exit 65: XcresultProbeTests.swift:15: XCTAssertEqual failed: (\"4\") is not equal to "
        + "(\"5\") - 2 + 2 should be 5",
      "\(report.rows.map(\.message))")
  }
}
