import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("FakeProcessRunner")
struct FakeProcessRunnerTests {
  @Test("records each invocation in order — catches adapter tests unable to assert the argv built")
  func recordsInvocations() async throws {
    let fake = FakeProcessRunner { invocation in
      ProcessOutput(status: .exited(0), stdout: invocation.arguments.joined(separator: ","))
    }
    let first = ProcessInvocation(executable: "git", arguments: ["status"], timeout: .seconds(1))
    let second = ProcessInvocation(
      executable: "swift", arguments: ["test", "--parallel"], timeout: .seconds(1))

    let output = try await fake.run(first)
    _ = try await fake.run(second)

    #expect(output.stdout.text == "status")
    #expect(fake.invocations == [first, second])
  }

  @Test("scripted errors propagate typed — catches adapters mishandling timeouts they never saw")
  func propagatesScriptedError() async {
    let fake = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      throw .launchFailed(executable: invocation.executable, reason: "scripted")
    }
    await #expect(throws: ProcessRunnerError.launchFailed(executable: "xcrun", reason: "scripted"))
    {
      _ = try await fake.run(ProcessInvocation(executable: "xcrun", timeout: .seconds(1)))
    }
  }
}
