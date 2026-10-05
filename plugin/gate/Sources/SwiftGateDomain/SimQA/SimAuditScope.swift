import Foundation

/// Which interactive elements `sim.a11y-identifier` and `sim.a11y-label` judge.
///
/// An owned repository holds every control on every screen to standards §7. A brownfield clone
/// inherits controls the change never touched, so there the rules judge only what a flow's steps
/// select by `id=`, the identifiers the change's contract names. Controls a step reaches by label,
/// role or text are existing UI the flow navigates through; their findings and the rest's become
/// 1 `sim.a11y-untargeted` nit.
public enum SimAuditScope: Sendable, Equatable {
  /// Every interactive element in each step's tree.
  case everyControl
  /// Only the interactive elements one of these selectors names by identifier; `pressed` are the
  /// selectors the flow presses, whose controls' tap targets are measured.
  case targeted([SimSelector], pressed: [SimSelector] = [])
  /// No element, with why.
  case unaudited(reason: String)

  /// The nit that counts what a narrowed audit left out. It never gates.
  public static let untargetedRuleID = "sim.a11y-untargeted"

  /// The nit naming each pressed control drawn smaller than ``minimumTapTarget`` on a side. It
  /// never gates.
  public static let tapTargetRuleID = "sim.tap-target"

  /// The smallest tap target the Human Interface Guidelines allow, in points, on either side.
  public static let minimumTapTarget = 44.0

  /// Why a brownfield clone's `sim verify` with no flow judges no control.
  public static let noFlowReason =
    "a brownfield clone's run with no flow names no control the change touches; qa run judges "
    + "the controls its flow's steps select"

  /// The scope for a run in a repository of `profile`. `flowSteps` is the flow the run drove, or
  /// `nil` for a run with none.
  public static func scope(profile: RepositoryProfile, flowSteps: [FlowStep]?) -> SimAuditScope {
    switch (profile, flowSteps) {
    case (.owned, _): .everyControl
    case (.brownfield, nil): .unaudited(reason: noFlowReason)
    case (.brownfield, let steps?):
      .targeted(SimSelector.all(in: steps), pressed: SimSelector.pressed(in: steps))
    }
  }

  /// The 1 note for the controls this scope left out with a finding: `count` controls no step
  /// selects, and `navigated` controls steps select only to move through the app, each counted
  /// once however many steps show it. `nil` when it judged every control or left nothing out.
  func note(untargeted count: Int, navigated: Int) -> SimVerifyNote? {
    let total = count + navigated
    let controls = total == 1 ? "1 control" : "\(total) controls"
    switch self {
    case .everyControl:
      return nil
    case .targeted where total == 0:
      return nil
    case .targeted:
      let through = navigated == 0 ? "" : " (\(navigated) the flow only navigates through)"
      return SimVerifyNote(
        rule: Self.untargetedRuleID,
        message: "\(controls) no flow step selects by id\(through) lack an accessibility "
          + "identifier or a readable label: a brownfield clone judges only the controls its "
          + "flow's id= selectors name")
    case .unaudited(let reason):
      return SimVerifyNote(
        rule: Self.untargetedRuleID,
        message: "accessibility not judged (\(controls) missing an identifier or a readable "
          + "label): \(reason)")
    }
  }

  /// The 1 note naming each pressed control drawn under ``minimumTapTarget`` on a side, with
  /// its size in points; `nil` when none is.
  static func tapTargetNote(_ small: [SimControl: SimFrame]) -> SimVerifyNote? {
    guard !small.isEmpty else { return nil }
    let named = small.map { control, frame in
      "\(control.name) \(Int(frame.width.rounded()))×\(Int(frame.height.rounded())) pt"
    }.sorted()
    let side = Int(minimumTapTarget)
    let count = small.count == 1 ? "1 pressed control is" : "\(small.count) pressed controls are"
    return SimVerifyNote(
      rule: tapTargetRuleID,
      message: "\(count) under \(side)×\(side) pt, too small to hit reliably: "
        + named.joined(separator: ", ") + "; give each a frame or `.contentShape` of at least "
        + "\(side)×\(side) pt")
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
    guard let tokens = tokens(text) else { return nil }
    var alternatives: [[Term]] = []
    var current: [Term] = []
    for token in tokens + ["||"] {
      if token == "||" {
        if !current.isEmpty { alternatives.append(current) }
        current = []
        continue
      }
      guard let equals = token.firstIndex(of: "=") else {
        guard ignoredKeys.contains(token.lowercased()) else { return nil }
        continue
      }
      let key = token[..<equals].lowercased()
      guard let value = unquoted(token[token.index(after: equals)...]) else { return nil }
      if treeKeys.contains(key) {
        current.append(Term(key: key, value: value))
      } else if !ignoredKeys.contains(key) {
        return nil
      }
    }
    return alternatives.isEmpty ? nil : SimSelector(raw: text, alternatives: alternatives)
  }

  /// Every selector in `steps`' inputs, in step order and once each, skipping what a step types
  /// or compares.
  public static func all(in steps: [FlowStep]) -> [SimSelector] {
    var found: [SimSelector] = []
    func visit(_ value: FlowJSON, key: String?) {
      switch value {
      case .object(let fields):
        for name in fields.keys.sorted() { fields[name].map { visit($0, key: name) } }
      case .array(let values):
        for item in values { visit(item, key: key) }
      case .string(let text):
        guard !FlowRules.contentKeys.contains(key ?? ""), let selector = parse(text),
          !found.contains(where: { $0.raw == selector.raw })
        else { return }
        found.append(selector)
      default:
        return
      }
    }
    for step in steps { visit(.object(step.input), key: nil) }
    return found
  }

  /// The selector each `press` step of `steps` presses, in step order and once each.
  public static func pressed(in steps: [FlowStep]) -> [SimSelector] {
    var found: [SimSelector] = []
    for selector in steps.filter({ $0.command == "press" }).flatMap({ all(in: [$0]) })
    where !found.contains(where: { $0.raw == selector.raw }) {
      found.append(selector)
    }
    return found
  }

  /// Whether `element` satisfies every term of an alternative holding an `id` term: the selector
  /// names it by the identifier the change's contract gives it, not by text or role it inherits.
  public func namesIdentifier(_ element: SimElement) -> Bool {
    alternatives.contains { terms in
      terms.contains { $0.key == "id" } && Self.matches(terms, element)
    }
  }

  /// Whether `element` satisfies every term of some alternative, compared as the pin compares:
  /// trimmed, case-folded, runs of whitespace as 1 space.
  public func matches(_ element: SimElement) -> Bool {
    alternatives.contains { Self.matches($0, element) }
  }

  private static func matches(_ terms: [Term], _ element: SimElement) -> Bool {
    terms.allSatisfy { term in
      let actual: String? =
        switch term.key {
        case "id": element.identifier
        case "role": element.role.rawValue
        case "label": element.label
        case "value": element.value
        default:
          [element.label, element.value, element.identifier].lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        }
      return folded(actual ?? "") == folded(term.value)
    }
  }

  /// Keys whose value a snapshot node carries.
  static let treeKeys: Set<String> = ["id", "role", "label", "value", "text"]
  /// Keys the pin accepts that say nothing about which control: state flags, and the app or
  /// window a match lies in.
  static let ignoredKeys: Set<String> = [
    "visible", "hidden", "editable", "selected", "focused", "enabled", "hittable", "appname",
    "windowtitle",
  ]

  /// `text` split at whitespace outside double quotes; `nil` when a quote is left open.
  private static func tokens(_ text: String) -> [String]? {
    var tokens: [String] = []
    var current = ""
    var quoted = false
    var escaped = false
    for character in text {
      if escaped {
        current.append(character)
        escaped = false
      } else if character == "\\" && quoted {
        current.append(character)
        escaped = true
      } else if character == "\"" {
        current.append(character)
        quoted.toggle()
      } else if character.isWhitespace && !quoted {
        if !current.isEmpty { tokens.append(current) }
        current = ""
      } else {
        current.append(character)
      }
    }
    guard !quoted else { return nil }
    if !current.isEmpty { tokens.append(current) }
    return tokens
  }

  /// A term's value without its quotes; `nil` when empty or quoted only in part.
  private static func unquoted(_ value: Substring) -> String? {
    guard value.first == "\"" else {
      return value.isEmpty || value.contains("\"") ? nil : String(value)
    }
    guard value.count >= 2, value.last == "\"" else { return nil }
    let inner = value.dropFirst().dropLast()
      .replacing("\\\"", with: "\"").replacing("\\\\", with: "\\")
    return inner.isEmpty ? nil : String(inner)
  }

  private static func folded(_ text: String) -> String {
    text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
