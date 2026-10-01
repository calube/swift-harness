import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// Keeps every event it's handed, or refuses each with `failure`.
public final class MemoryEventLog: HarnessEventWriting {
  private let stored = Mutex<[HarnessEvent]>([])
  private let failure: HarnessEventWriteError?

  public init(failing failure: HarnessEventWriteError? = nil) {
    self.failure = failure
  }

  public var events: [HarnessEvent] { stored.withLock { $0 } }

  public var decisions: [JudgeDecisionEvent] {
    events.compactMap {
      guard case .judgeDecision(let decision) = $0.payload else { return nil }
      return decision
    }
  }

  public var calls: [JudgeCallEvent] {
    events.compactMap {
      guard case .judgeCall(let call) = $0.payload else { return nil }
      return call
    }
  }

  public func append(_ event: HarnessEvent) throws(HarnessEventWriteError) {
    if let failure { throw failure }
    stored.withLock { $0.append(event) }
  }
}

extension JudgeEventScope {
  /// A scope over `log` at a fixed time, with ids `event-1`, `event-2`, … in the order asked.
  public static func testing(
    _ log: any HarnessEventWriting, source: HarnessEventSource = HarnessEventSource(route: nil),
    time: Date = Date(timeIntervalSince1970: 1_790_000_000), secrets: [String] = []
  ) -> JudgeEventScope {
    let counter = Mutex(0)
    return JudgeEventScope(
      log: log, now: { time },
      newID: {
        counter.withLock {
          $0 += 1
          return "event-\($0)"
        }
      }, source: source, secrets: secrets)
  }
}
