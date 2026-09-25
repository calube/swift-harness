import Foundation
import SwiftGateDomain

/// Turns config file text into a validated ``Config``. The file format is an adapter detail; the
/// schema rules live in ``ConfigSchema``.
public protocol ConfigDecoding: Sendable {
  func decode(_ text: String) throws(ConfigLoadError) -> Config
}

public enum ConfigLoadError: Error, Sendable, Equatable, CustomStringConvertible {
  case syntax(line: Int, column: Int, message: String)
  case invalid(ConfigValidationError)
  case unreadable(path: String, reason: String)

  /// A malformed or invalid config is a repository change to fix (`red`); an unreadable file is
  /// an environment problem (`blocked`).
  public var verdict: Verdict {
    switch self {
    case .syntax, .invalid: .red
    case .unreadable: .blocked
    }
  }

  public var description: String {
    switch self {
    case .syntax(let line, let column, let message):
      "\(ConfigLoader.fileName):\(line):\(column): \(message)"
    case .invalid(let error):
      error.issues.map { "\(ConfigLoader.fileName): \($0)" }.joined(separator: "\n")
    case .unreadable(let path, let reason):
      "\(path): cannot read (\(reason))"
    }
  }
}
