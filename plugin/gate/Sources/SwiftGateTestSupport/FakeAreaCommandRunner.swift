import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// A scripted `AreaCommandRunning`: answers each request with `handler` and records every
/// request, so a test can assert which commands a tier ran and in what order.
public final class FakeAreaCommandRunner: AreaCommandRunning {
  public typealias Handler = @Sendable (AreaCommandRequest) -> AreaCommandOutcome

  private let handler: Handler
  private let recorded = Mutex<[AreaCommandRequest]>([])

  public init(handler: @escaping Handler) {
    self.handler = handler
  }

  public var requests: [AreaCommandRequest] { recorded.withLock { $0 } }

  public func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    recorded.withLock { $0.append(request) }
    return handler(request)
  }
}
