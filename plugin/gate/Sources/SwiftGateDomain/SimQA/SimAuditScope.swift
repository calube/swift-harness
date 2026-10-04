import Foundation

/// Which interactive elements `sim.a11y-identifier` and `sim.a11y-label` judge.
///
/// An owned repository holds every control on every screen to standards §7. A brownfield clone
/// inherits controls the change never touched, so there the rules judge only what a flow's steps
/// select, and the rest becomes 1 `sim.a11y-untargeted` nit.
public enum SimAuditScope: Sendable, Equatable {
  /// Every interactive element in each step's tree.
  case everyControl
  /// Only the interactive elements one of these selectors matches.
  case targeted([SimSelector])
  /// No element, with why.
  case unaudited(reason: String)

  /// The nit that counts what a narrowed audit left out. It never gates.
  public static let untargetedRuleID = "sim.a11y-untargeted"

  /// Why a brownfield clone's `sim verify` with no flow judges no control.
  public static let noFlowReason =
    "a brownfield clone's run with no flow names no control the change touches; qa run judges "
    + "the controls its flow's steps select"

  /// The scope for a run in a repository of `profile`. `flowSteps` is the flow the run drove, or
  /// `nil` for a run with none.
  public static func scope(profile: RepositoryProfile, flowSteps: [FlowStep]?) -> SimAuditScope {
    .everyControl
  }
}

/// One `agent-device` selector, as a flow step writes it: whitespace-separated `key=value` terms,
/// each value bare or double-quoted, with `||` between alternatives.
public struct SimSelector: Sendable, Equatable {
  /// 1 alternative's terms that a tree can show: `id`, `role`, `label`, `value` and `text`.
  public struct Term: Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
      self.key = key
      self.value = value
    }
  }

  /// The text as the step wrote it.
  public let raw: String
  /// Each alternative's terms. An element matches when every term of some alternative does.
  public let alternatives: [[Term]]

  public init(raw: String, alternatives: [[Term]]) {
    self.raw = raw
    self.alternatives = alternatives
  }

  /// `nil` when `text` isn't a selector: no `key=value` term, or a key the pin doesn't know.
  public static func parse(_ text: String) -> SimSelector? {
    nil
  }

  /// Every selector in `steps`' inputs, in step order, skipping what a step types or compares.
  public static func all(in steps: [FlowStep]) -> [SimSelector] {
    []
  }

  /// Whether `element` satisfies every term of some alternative, compared as the pin compares:
  /// trimmed, case-folded, runs of whitespace as 1 space.
  public func matches(_ element: SimElement) -> Bool {
    false
  }
}

/// A finding that never gates, with the rule that names it.
public struct SimVerifyNote: Sendable, Equatable {
  public var rule: String
  public var message: String

  public init(rule: String, message: String) {
    self.rule = rule
    self.message = message
  }
}
