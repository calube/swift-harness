import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("Mermaid validation")
struct MermaidValidationTests {
  static let fences: [(heading: String, index: Int, source: String)] = [
    (heading: "Architecture", index: 1, source: "flowchart LR\n  A --> B\n"),
    (heading: "Architecture", index: 2, source: "flowchart LR\n  A -->\n"),
  ]

  /// Fails any fence whose input file holds `A -->` with no target, the way `mmdc` rejects it.
  static func mmdc(_ invocation: ProcessInvocation) throws(ProcessRunnerError) -> ProcessOutput {
    guard
      let input = invocation.arguments.firstIndex(of: "-i").map({ invocation.arguments[$0 + 1] })
    else { return ProcessOutput(status: .exited(0), stdout: "11.4.0\n") }
    let source = (try? String(contentsOfFile: input, encoding: .utf8)) ?? ""
    return source.hasSuffix("-->\n")
      ? ProcessOutput(status: .exited(1), stderr: "Parse error on line 2\n")
      : ProcessOutput(status: .exited(0))
  }

  @Test(
    "each fence is validated and only the failing one is reported with its heading and index — catches a broken diagram passing design-lint wherever mmdc is installed"
  )
  func failingFenceIsReported() async {
    let runner = FakeProcessRunner(handler: Self.mmdc)

    let outcome = await MermaidValidation.validate(fences: Self.fences, runner: runner)

    #expect(
      outcome
        == .validated([
          .init(heading: "Architecture", index: 2, diagnostic: "Parse error on line 2")
        ]))
    #expect(runner.invocations.map(\.executable) == ["mmdc", "mmdc", "mmdc"])
  }

  @Test(
    "a failure with empty stderr still names the exit status — catches a failing fence reported with a blank diagnostic"
  )
  func silentFailureNamesStatus() async {
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      invocation.arguments == ["--version"]
        ? ProcessOutput(status: .exited(0)) : ProcessOutput(status: .signaled(9))
    }

    let outcome = await MermaidValidation.validate(
      fences: [Self.fences[0]], runner: runner)

    #expect(
      outcome
        == .validated([.init(heading: "Architecture", index: 1, diagnostic: "mmdc exited signal 9")]
        ))
  }

  @Test(
    "an mmdc that can't launch means not on PATH and validates nothing — catches design-lint blocking where mmdc is absent"
  )
  func launchFailureIsNotOnPath() async {
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      throw .launchFailed(executable: invocation.executable, reason: "not found")
    }

    let outcome = await MermaidValidation.validate(fences: Self.fences, runner: runner)

    #expect(outcome == .notOnPath)
    #expect(runner.invocations.count == 1)
  }
}
