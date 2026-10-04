import SwiftGateAdapters
import Synchronization

/// A scripted `ProcessRunner` for adapter tests: answers each invocation with `handler` and
/// records every invocation so tests can assert the exact argv an adapter built.
public final class FakeProcessRunner: ProcessRunner {
  public typealias Handler =
    @Sendable (ProcessInvocation) throws(ProcessRunnerError) ->
    ProcessOutput
  /// For a script that itself runs real processes, which it must await rather than block on.
  public typealias AsyncHandler =
    @Sendable (ProcessInvocation) async throws(ProcessRunnerError) -> ProcessOutput

  private let handler: AsyncHandler
  private let recorded = Mutex<[ProcessInvocation]>([])

  public init(handler: @escaping Handler) {
    self.handler = { invocation throws(ProcessRunnerError) in try handler(invocation) }
  }

  public init(asyncHandler: @escaping AsyncHandler) {
    self.handler = asyncHandler
  }

  public var invocations: [ProcessInvocation] { recorded.withLock { $0 } }

  public func run(_ invocation: ProcessInvocation) async throws(ProcessRunnerError)
    -> ProcessOutput
  {
    recorded.withLock { $0.append(invocation) }
    return try await handler(invocation)
  }
}
