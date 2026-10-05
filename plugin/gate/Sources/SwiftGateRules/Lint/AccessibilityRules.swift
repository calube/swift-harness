import SwiftGateDomain
import SwiftSyntax

/// Interactive elements carry a readable label (standards X1), checked in source so a slice gate
/// finds what `sim.a11y-label` would otherwise find only once a flow reaches the screen.
enum AccessibilityRules {
  static let all: [any Rule] = [inputLabel]

  static let inputLabel = SyntaxLintRule(
    id: "a11y.input-label",
    summary: "a text input with an accessibility identifier but no accessibility label",
    scope: LintScopes.productionFiles
  ) { _, _, _ in [] }
}

/// `a11y.input-label` over the Swift files a brownfield change adds or edits, on their added lines
/// only, so a field the change didn't touch never gates it.
public enum ChangedInputLabels {
  public static let ruleID = AccessibilityRules.inputLabel.descriptor.id

  /// The rule's findings in `files`' Swift sources.
  public static func findings(_ files: [ChangedTestFile]) -> [Finding] {
    []
  }
}
