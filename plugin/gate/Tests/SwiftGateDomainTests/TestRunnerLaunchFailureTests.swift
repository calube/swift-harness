import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("a test runner the simulator failed to launch")
struct TestRunnerLaunchFailureTests {
  /// The end of a captured `xcodebuild test` run's saved output, stdout then stderr.
  static func tail(_ name: String) throws -> String {
    try Fixture.text("QA/runner-launch/\(name).tail.txt")
  }

  @Test(
    "both captured runs the busy shared simulator refused to launch the runner on read as a launch failure naming the busy device — catches an infrastructure failure read as a red test",
    arguments: ["busy-1", "busy-2"])
  func busyRunnerIsALaunchFailure(_ name: String) throws {
    let reason = try #require(TestRunnerLaunchFailure.reason(in: try Self.tail(name)))

    #expect(reason.contains("test runner"), "\(reason)")
    #expect(reason.contains("busy"), "\(reason)")
  }

  @Test(
    "a captured passing UI test run and a captured test-target compile failure show no launch failure — catches a real failure retried and excused as the machine's"
  )
  func otherRunsAreNot() throws {
    #expect(TestRunnerLaunchFailure.reason(in: try Self.tail("passed")) == nil)
    #expect(
      TestRunnerLaunchFailure.reason(
        in: try Fixture.text("BrownfieldTrial/aidoku-validation-3-test-compile.tail.txt")) == nil)
    #expect(TestRunnerLaunchFailure.reason(in: try Self.tail("busy-1")) != nil)
  }

  static func judge(
    _ name: String, bundle scenario: String, atBase: Bool = false
  ) throws -> QACheckJudgement {
    let text = try tail(name)
    let split = try #require(text.range(of: "--- stderr ---\n"))
    return QACheckJudgement.judge(
      QACheckJudgement.Input(
        end: .exited(65), stdout: String(text[..<split.lowerBound]),
        stderr: String(text[split.upperBound...]), report: nil,
        resultBundle: .tests(try Fixture.data("Xcresult/\(scenario).tests.json")),
        reference: "AppUITests/MainFlowUITests", atBase: atBase, roots: ["/TRIAL/repo-spec"]))
  }

  @Test(
    "the captured busy run, exit 65 with a bundle whose only failure is the runner's launch, is unverified naming the launch failure after the merge and at the merge base — catches a launch failure read as a red row, or as the red-first proof"
  )
  func launchFailureIsUnverified() throws {
    for atBase in [false, true] {
      let judgement = try Self.judge("busy-1", bundle: "runner-busy", atBase: atBase)

      #expect(judgement.result == .unverified, "\(judgement.message)")
      #expect(judgement.message.contains("test runner"), "\(judgement.message)")
    }
  }

  @Test(
    "the same launch-failure output beside a bundle with a real failing test stays red, naming that test's failure — catches a real red row hidden as the machine's problem"
  )
  func realFailureStaysRed() throws {
    let judgement = try Self.judge("busy-1", bundle: "fail")

    #expect(judgement.result == .red)
    #expect(judgement.message.contains("2 + 2 should be 5"), "\(judgement.message)")
    #expect(try Self.judge("busy-1", bundle: "runner-busy").result != .red)
  }
}
