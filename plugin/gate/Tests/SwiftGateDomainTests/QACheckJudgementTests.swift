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

  @Test(
    "the captured passing swift test report, which ran 2 tests, passes on exit 0 — catches a count read from the wrong element"
  )
  func passingReportPasses() throws {
    let judgement = QACheckJudgement.judge(Self.input(.exited(0), report: try Self.report("pass")))

    #expect(judgement == QACheckJudgement(result: .pass, message: "exit 0"))
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
