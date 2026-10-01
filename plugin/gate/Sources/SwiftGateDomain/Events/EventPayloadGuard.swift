import Foundation

/// Keeps free text, paths and multi-line values out of a stored payload. Every string in a
/// payload, at any depth, must be under ``maxStringBytes`` UTF-8 bytes, must not start with `/` or
/// `~`, and must not hold a newline.
public enum EventPayloadGuard {
  public static let maxStringBytes = 512

  /// Why a payload was rejected; the key `dropped.json` counts it under.
  public enum Reason: String, Sendable, Codable, CaseIterable, CodingKeyRepresentable {
    case absolutePath = "absolute-path"
    case homePath = "home-path"
    case newline
    case tooLong = "too-long"
  }

  /// Whether a stream's payloads are checked.
  public enum Policy: Sendable, Equatable {
    case enforced
    /// The stream is an audit trail: dropping or cutting an event would lose the record, so its
    /// payloads go through whole.
    case exempt
  }

  public static func policy(for stream: HarnessEventStream) -> Policy {
    .enforced
  }

  /// The first rule `event`'s payload breaks, or `nil` when it passes.
  public static func rejection(of event: HarnessEvent) throws -> Reason? {
    nil
  }

  /// The first rule a string in `value`, a `JSONSerialization` object, breaks.
  public static func rejection(inJSON value: Any) -> Reason? {
    nil
  }
}

/// `.harness/events/dropped.json`: how many events the guard dropped, by kind and reason.
public struct EventDropCounts: Sendable, Equatable, Codable {
  public static let schemaVersion = 1

  public let schemaVersion: Int
  public private(set) var dropped: [HarnessEventKind: [EventPayloadGuard.Reason: Int]]

  public init(dropped: [HarnessEventKind: [EventPayloadGuard.Reason: Int]] = [:]) {
    self.schemaVersion = 0
    self.dropped = dropped
  }

  public mutating func count(_ kind: HarnessEventKind, _ reason: EventPayloadGuard.Reason) {
  }
}

extension HarnessEventKind: CodingKeyRepresentable {}
