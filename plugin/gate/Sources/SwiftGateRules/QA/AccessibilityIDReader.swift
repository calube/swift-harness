import SwiftGateDomain

/// Reads the identifiers an app declares in its typed accessibility-id module: the raw values of
/// its 1 `enum AccessibilityID: String` (simulator QA amendment decision 17).
public enum AccessibilityIDReader {
  public static let enumName = "AccessibilityID"

  /// - Parameter path: the file's repo-relative path, which errors name.
  /// - Throws: when the source doesn't parse, declares no such enum or more than 1, or holds a
  ///   case whose raw value isn't a plain string literal.
  public static func read(source: String, path: String) throws(AccessibilityIDReaderError)
    -> Set<String>
  {
    []
  }
}

/// Why the identifiers couldn't be read, naming the file.
public struct AccessibilityIDReaderError: Error, Sendable, Equatable, CustomStringConvertible {
  public let path: String
  public let reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }

  public var description: String { "" }
}
