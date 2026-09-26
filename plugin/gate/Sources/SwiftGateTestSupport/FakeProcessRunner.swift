import SwiftGateAdapters
import Synchronization

/// A scripted `ProcessRunner` for adapter tests: answers each invocation with `handler` and
/// records every invocation so tests can assert the exact argv an adapter built.
public final class FakeProcessRunner: ProcessRunner {
  public typealias Handler =
    @Sendable (ProcessInvocation) throws(ProcessRunnerError) ->
    ProcessOutput

  private let handler: Handler
  private let recorded = Mutex<[ProcessInvocation]>([])

  public init(handler: @escaping Handler) {
    self.handler = handler
  }

  public var invocations: [ProcessInvocation] { recorded.withLock { $0 } }

  public func run(_ invocation: ProcessInvocation) async throws(ProcessRunnerError)
    -> ProcessOutput
  {
    recorded.withLock { $0.append(invocation) }
    return try handler(invocation)
  }
}
