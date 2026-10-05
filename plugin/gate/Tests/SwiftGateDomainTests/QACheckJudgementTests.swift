import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("QACheckJudgement")
struct QACheckJudgementTests {
  static func input(
    _ end: QACheckJudgement.End, stdout: String = "", stderr: String = "", report: Data? = nil,
    atBase: Bool = false, roots: [String] = ["/work/tree"]
  ) -> QACheckJudgement.Input {
    QACheckJudgement.Input(
      end: end, stdout: stdout, stderr: stderr, report: report, reference: "ProbeTests.Pass",
      atBase: atBase, roots: roots)
  }

  /// Both reports of 1 captured `swift test` scenario, combined as a run reads them.
  static func report(_ scenario: String) throws -> Data? {
    JUnitReports.combined([
      try Fixture.data("SwiftTest/\(scenario).xml"),
      try Fixture.data("SwiftTest/\(scenario)-swift-testing.xml"),
    ])
  }

  /// The test tree of 1 captured `xcodebuild test` result bundle.
  static func bundle(_ scenario: String) throws -> QACheckJudgement.ResultBundle {
    .tests(try Fixture.data("Xcresult/\(scenario).tests.json"))
  }

  static func xcode(
    _ end: QACheckJudgement.End, _ bundle: QACheckJudgement.ResultBundle, stderr: String = "",
    atBase: Bool = false
  ) -> QACheckJudgement {
    QACheckJudgement.judge(
      QACheckJudgement.Input(
        end: end, stdout: "", stderr: stderr, report: nil, resultBundle: bundle,
        reference: "CounterUISnapshotTests/ProbePassXCTests/testNoSuchTest", atBase: atBase,
        roots: ["/work/tree"]))
  }

  @Test(
    "the captured bundle of an -only-testing run on a missing test (exit 0, no test case) is red at base and unverified after, naming the id — catches xcodebuild's exit 0 read as a pass"
  )
  func bundleWithNoTestRan() throws {
    let base = Self.xcode(.exited(0), try Self.bundle("missing-test"), atBase: true)
    let after = Self.xcode(.exited(0), try Self.bundle("missing-test"))

    #expect(base.result == .red, "\(base)")
    #expect(
      base.message
        == "exit 0, but no test matched `CounterUISnapshotTests/ProbePassXCTests/testNoSuchTest`")
    #expect(after.result == .unverified, "\(after)")
    #expect(after.message.contains("no test matched"), "\(after)")
  }

  @Test(
    "the captured bundle of 1 real test that passed passes on exit 0 and says 1 test passed — catches every bundle read as running nothing, and a pass that hides how many tests it ran"
  )
  func bundleWithOneTestPasses() throws {
    #expect(
      Self.xcode(.exited(0), try Self.bundle("one-test"), atBase: true)
        == QACheckJudgement(result: .pass, message: "exit 0, 1 test passed"))
  }

  @Test(
    "a red xcodebuild row names the captured bundle's first failure message, not stderr's last line — catches a red row whose reason is `** TEST FAILED **`"
  )
  func bundleFailureNamesFirstMessage() throws {
    let judgement = Self.xcode(
      .exited(65), try Self.bundle("fail"), stderr: "** TEST FAILED **\n")

    #expect(judgement.result == .red)
    #expect(
      judgement.message
        == "exit 65: XcresultProbeTests.swift:15: XCTAssertEqual failed: (\"4\") is not equal to "
        + "(\"5\") - 2 + 2 should be 5",
      "\(judgement)")
  }

  @Test(
    "a bundle that couldn't be read after exit 0 shows no test ran: red at base, unverified after, naming why — catches a missing bundle read as a pass"
  )
  func unreadBundle() throws {
    let unread = QACheckJudgement.ResultBundle.unread("xcresulttool failed (exit 64)")

    let base = Self.xcode(.exited(0), unread, atBase: true)
    let after = Self.xcode(.exited(0), unread)

    #expect(base.result == .red, "\(base)")
    #expect(after.result == .unverified, "\(after)")
    #expect(after.message.contains("xcresulttool failed (exit 64)"), "\(after)")
  }

  @Test(
    "the captured passing swift test report, which ran 2 tests, passes on exit 0 and says 2 tests passed — catches a count read from the wrong element"
  )
  func passingReportPasses() throws {
    let judgement = QACheckJudgement.judge(Self.input(.exited(0), report: try Self.report("pass")))

    #expect(judgement == QACheckJudgement(result: .pass, message: "exit 0, 2 tests passed"))
  }

  @Test(
    "captured reports of 2 passing and 2 skipped Swift Testing cases pass, counting only the 2 that ran as passed and naming the skips apart — catches a skipped test counted as a pass"
  )
  func passingReportCountsSkipsApart() throws {
    let report = JUnitReports.combined([
      try Fixture.data("SwiftTest/pass.xml"),
      try Fixture.data("SwiftTest/pass-swift-testing.xml"),
      try Fixture.data("SwiftTest/skip-swift-testing.xml"),
    ])

    let judgement = QACheckJudgement.judge(Self.input(.exited(0), report: report))

    #expect(
      judgement == QACheckJudgement(result: .pass, message: "exit 0, 2 tests passed, 2 skipped"))
  }

  @Test(
    "a report that doesn't parse (a captured stdout handed in as one) shows no test ran: unverified after the merge, red at base — catches an unreadable report read as a pass"
  )
  func unreadableReport() throws {
    let garbage = try Fixture.data("SwiftTest/pass.stdout")

    let after = QACheckJudgement.judge(Self.input(.exited(0), report: garbage))
    let base = QACheckJudgement.judge(Self.input(.exited(0), report: garbage, atBase: true))

    #expect(after.result == .unverified, "\(after)")
    #expect(after.message.contains("report"), "\(after)")
    #expect(base.result == .red, "\(base)")
  }

  @Test(
    "a red check's reason is cut to the limit with an ellipsis, and a path outside its roots reads <path> — catches a machine path or a whole log in the report message"
  )
  func reasonIsScrubbedAndClipped() {
    let long = String(repeating: "x", count: 300)

    let clipped = QACheckJudgement.judge(Self.input(.exited(2), stderr: "\(long)\n"))
    let foreign = QACheckJudgement.judge(
      Self.input(.exited(2), stderr: "missing /Users/someone/app.log and /work/tree/a.txt\n"))

    let reason = String(clipped.message.dropFirst("exit 2: ".count))
    #expect(clipped.message.hasPrefix("exit 2: "))
    #expect(reason.count == QACheckJudgement.maxReasonCharacters, "\(reason.count)")
    #expect(reason.hasSuffix("…"))
    #expect(foreign.message == "exit 2: missing <path> and a.txt", "\(foreign.message)")
  }

  @Test(
    "a red check with nothing on stderr names its last stdout line; with no output at all only its status — catches an empty reason after the colon"
  )
  func fallsBackToStdout() {
    let stdout = QACheckJudgement.judge(Self.input(.exited(1), stdout: "false\n\n"))
    let silent = QACheckJudgement.judge(Self.input(.exited(1)))

    #expect(stdout.message == "exit 1: false")
    #expect(silent.message == "exit 1")
  }
}
