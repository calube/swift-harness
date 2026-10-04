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

  /// The judge's stream is exempt: its decisions can block a merge, and their reasons and
  /// rationales are long, multi-line model text the audit trail must keep whole.
  public static func policy(for stream: HarnessEventStream) -> Policy {
    switch stream {
    case .judge: .exempt
    case .gate: .enforced
    case .hook: .enforced
    case .test: .enforced
    case .cache: .enforced
    case .usage: .enforced
    case .build: .enforced
    case .brownfield: .enforced
    case .span: .enforced
    case .qa: .enforced
    }
  }

  /// The first rule `event`'s payload breaks, or `nil` when it passes.
  public static func rejection(of event: HarnessEvent) throws -> Reason? {
    let object = try JSONSerialization.jsonObject(with: try HarnessEventJSON.encodeLine(event))
    return rejection(inJSON: (object as? [String: Any])?["payload"] as Any)
  }

  /// The first rule a string in `value`, a `JSONSerialization` object, breaks. Object keys are
  /// checked as well as values.
  public static func rejection(inJSON value: Any) -> Reason? {
    if let text = value as? String { return rejection(of: text) }
    if let object = value as? [String: Any] {
      for key in object.keys.sorted() {
        if let found = rejection(of: key) ?? rejection(inJSON: object[key] as Any) {
          return found
        }
      }
    } else if let array = value as? [Any] {
      for element in array {
        if let found = rejection(inJSON: element) { return found }
      }
    }
    return nil
  }

  private static func rejection(of text: String) -> Reason? {
    if text.hasPrefix("/") { return .absolutePath }
    if text.hasPrefix("~") { return .homePath }
    if text.contains(where: \.isNewline) { return .newline }
    if text.utf8.count >= maxStringBytes { return .tooLong }
    return nil
  }
}

/// `.harness/events/dropped.json`: how many events the guard dropped, by kind and reason.
public struct EventDropCounts: Sendable, Equatable, Codable {
  public static let schemaVersion = 1

  public let schemaVersion: Int
  public private(set) var dropped: [HarnessEventKind: [EventPayloadGuard.Reason: Int]]

  public init(dropped: [HarnessEventKind: [EventPayloadGuard.Reason: Int]] = [:]) {
    self.schemaVersion = Self.schemaVersion
    self.dropped = dropped
  }

  public mutating func count(_ kind: HarnessEventKind, _ reason: EventPayloadGuard.Reason) {
    dropped[kind, default: [:]][reason, default: 0] += 1
  }
}

extension HarnessEventKind: CodingKeyRepresentable {}
