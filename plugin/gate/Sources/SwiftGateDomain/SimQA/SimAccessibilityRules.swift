import Foundation

/// Standards §7 on the real tree: every interactive element a step captured carries an
/// identifier and a readable label.
public enum SimAccessibilityRules {
  /// `sim.a11y-identifier` and `sim.a11y-label` findings over `tree`, in element order.
  public static func findings(_ tree: SimTree, step: SimStep) -> [SimEvidenceFinding] {
    tree.elements.filter(\.isInteractive).flatMap { findings($0, step: step) }
  }

  /// The findings `scope` judges over `tree`, and how many it left out: `untargeted` on controls
  /// no selector matches, `navigated` on controls a selector matches only by label, role or text.
  public static func audit(_ tree: SimTree, step: SimStep, scope: SimAuditScope)
    -> (findings: [SimEvidenceFinding], untargeted: Int, navigated: Int)
  {
    var judged: [SimEvidenceFinding] = []
    var untargeted = 0
    var navigated = 0
    for element in tree.elements where element.isInteractive {
      let found = findings(element, step: step)
      switch scope {
      case .everyControl:
        judged += found
      case .targeted(let selectors, _) where selectors.contains { $0.namesIdentifier(element) }:
        judged += found
      case .targeted(let selectors, _) where selectors.contains { $0.matches(element) }:
        navigated += found.count
      case .targeted, .unaudited:
        untargeted += found.count
      }
    }
    return (judged, untargeted, navigated)
  }

  /// The distinct controls `scope` left out of `tree` with a finding, and the pressed controls
  /// drawn under ``SimAuditScope/minimumTapTarget`` on a side, so a run counts each control once
  /// however many steps show it.
  public static func controls(_ tree: SimTree, step: SimStep, scope: SimAuditScope)
    -> SimAuditControls
  {
    SimAuditControls()
  }

  private static func findings(_ element: SimElement, step: SimStep) -> [SimEvidenceFinding] {
    let name = "step \(SimStep.stem(step.n)) \"\(step.label)\""
    var findings: [SimEvidenceFinding] = []
    let role = element.role.rawValue
    if element.identifier == nil {
      let label = element.label.map { "\"\($0)\"" } ?? "with no label"
      findings.append(
        SimEvidenceFinding(
          rule: .a11yIdentifier, step: step.n, path: step.tree,
          message: "\(name): \(role) \(label) has no accessibility identifier"))
    }
    if !hasReadableLabel(element) {
      let identifier = element.identifier ?? "with no identifier"
      findings.append(
        SimEvidenceFinding(
          rule: .a11yLabel, step: step.n, path: step.tree,
          message: "\(name): \(role) \(identifier) has no readable label"))
    }
    return findings
  }

  /// Non-empty after trimming, and not the identifier read back as a label.
  static func hasReadableLabel(_ element: SimElement) -> Bool {
    guard let label = element.label else { return false }
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed != element.identifier
  }
}

/// 1 control as the audit counts it: the same role, identifier and label in any step is 1 control,
/// wherever a scroll or a removed row moved it.
public struct SimControl: Sendable, Hashable {
  public let role: SimElementRole
  public let identifier: String?
  public let label: String?

  public init(_ element: SimElement) {
    role = element.role
    identifier = element.identifier
    label = element.label
  }

  /// How a note names it: its identifier, else its label, after its role.
  public var name: String {
    "\(role.rawValue) " + (identifier ?? label.map { "\"\($0)\"" } ?? "with no identifier or label")
  }
}

/// What an audit counts across a run's steps, each control once.
public struct SimAuditControls: Sendable, Equatable {
  /// Controls with a finding that no selector matches.
  public var untargeted: Set<SimControl> = []
  /// Controls with a finding that a selector matches only by label, role or text.
  public var navigated: Set<SimControl> = []
  /// Pressed controls drawn under the minimum tap target, with the frame first seen.
  public var smallTargets: [SimControl: SimFrame] = [:]

  public init() {}

  /// Adds `other`'s controls, keeping the frame first seen for a small target.
  public mutating func merge(_ other: SimAuditControls) {
    untargeted.formUnion(other.untargeted)
    navigated.formUnion(other.navigated)
    smallTargets.merge(other.smallTargets) { first, _ in first }
  }
}
