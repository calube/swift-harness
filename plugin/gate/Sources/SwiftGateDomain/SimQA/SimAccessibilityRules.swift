import Foundation

/// Standards §7 on the real tree: every interactive element a step captured carries an
/// identifier and a readable label.
public enum SimAccessibilityRules {
  /// `sim.a11y-identifier` and `sim.a11y-label` findings over `tree`, in element order.
  public static func findings(_ tree: SimTree, step: SimStep) -> [SimEvidenceFinding] {
    let name = "step \(SimStep.stem(step.n)) \"\(step.label)\""
    var findings: [SimEvidenceFinding] = []
    for element in tree.elements where element.isInteractive {
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
    }
    return findings
  }

  /// The findings `scope` judges over `tree`, and how many findings it left out.
  public static func audit(_ tree: SimTree, step: SimStep, scope: SimAuditScope)
    -> (findings: [SimEvidenceFinding], untargeted: Int)
  {
    (findings(tree, step: step), 0)
  }

  /// Non-empty after trimming, and not the identifier read back as a label.
  static func hasReadableLabel(_ element: SimElement) -> Bool {
    guard let label = element.label else { return false }
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed != element.identifier
  }
}
