import Foundation
import SwiftGateDomain

/// Why a span's start or end wasn't recorded.
public enum SpanLogError: Error, Sendable, Equatable, CustomStringConvertible {
  /// No `span.start` with this id is in the store.
  case noStart(spanID: String)
  /// The span already has a `span.end`.
  case alreadyEnded(spanID: String)
  /// The span stream, or its lock, couldn't be read.
  case unreadable(path: String, reason: String)
  case unwritten(HarnessEventWriteError)

  public var description: String { "" }

}

/// The `span.start` and `span.end` events of a checkout's store. Start and end each run holding
/// the lock in ``lockFile``, so 2 ends can't both close 1 span.
public struct SpanLog: Sendable {
  /// Relative to the state root, beside the halt lock.
  public static let lockFile = "\(RunLayout.eventsDirectory)/spans.lock"

  public let root: URL
  private let now: @Sendable () -> Date
  private let newEventID: @Sendable () -> String
  private let newSpanID: @Sendable () -> String

  /// - Parameter root: the checkout whose state root's `events/` holds the span stream.
  public init(
    root: URL,
    now: @escaping @Sendable () -> Date = {
      Date()  // swiftgate:allow det.date-init — stamps the event
    },
    newEventID: @escaping @Sendable () -> String = {
      UUID().uuidString  // swiftgate:allow det.uuid-init — an event id need only be unique
    },
    newSpanID: @escaping @Sendable () -> String = { SpanLog.randomSpanID() }
  ) {
    self.root = root
    self.now = now
    self.newEventID = newEventID
    self.newSpanID = newSpanID
  }

  /// 16 lowercase hex characters from the system's random source.
  public static func randomSpanID() -> String { "" }

  /// Records that `phase` began and returns the `span.start` event, whose payload holds the new
  /// span id.
  public func start(
    phase: SpanPhase, buildRun: String, task: String?, role: AgentRole?, parentSpan: String?
  ) throws(SpanLogError) -> HarnessEvent {
    throw .noStart(spanID: "")
  }

  /// Records the end of `spanID` with `ms` from its start's time to now; writes nothing when no
  /// start has that id or the span already ended.
  public func end(spanID: String, outcome: SpanOutcome) throws(SpanLogError) -> HarnessEvent {
    throw .noStart(spanID: spanID)
  }
}
