/// Severity of a finding, shared by lint rules and reviewers so their findings merge.
///
/// `blocker` and `major` fail the gate (lint level `error`); `minor` and `nit` are advisory
/// (lint level `warning`).
public enum Severity: String, Sendable, Codable, CaseIterable {
  case blocker
  case major
  case minor
  case nit

  public var lintLevel: LintLevel {
    switch self {
    case .blocker, .major: .error
    case .minor, .nit: .warning
    }
  }

  public var failsGate: Bool { lintLevel == .error }

  /// Imports a tool's lint level. An `error` maps to `major`, not `blocker`: `blocker` is reserved
  /// for findings a rule or reviewer explicitly classifies as blocking.
  public init(lintLevel: LintLevel) {
    switch lintLevel {
    case .error: self = .major
    case .warning: self = .minor
    }
  }
}

public enum LintLevel: String, Sendable, Codable, CaseIterable {
  case error
  case warning
}
