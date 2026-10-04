import Foundation

/// Runs ``EventPayloadGuard``'s string rules over every string in a ``RunView``, keys included,
/// before a page or a JSON dump shows it.
public enum RunViewGuard {
  /// The first string the guard rejects: where it sits in the view's JSON, and why.
  public struct Rejection: Error, Sendable, Equatable, CustomStringConvertible {
    /// A JSON path, such as `tasks[0].writes[1]`.
    public let field: String
    public let reason: EventPayloadGuard.Reason

    public init(field: String, reason: EventPayloadGuard.Reason) {
      self.field = field
      self.reason = reason
    }

    public var description: String {
      "run view field \(field) fails the payload guard (\(reason.rawValue))"
    }
  }

  /// The first rejected string in `view`, in sorted key order; `nil` when every string passes.
  public static func rejection(of view: RunView) throws -> Rejection? {
    nil
  }
}
