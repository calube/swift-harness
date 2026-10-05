import SwiftGateDomain
import SwiftSyntax

/// Interactive elements carry a readable label (standards X1), checked in source so a slice gate
/// finds what `sim.a11y-label` would otherwise find only once a flow reaches the screen.
enum AccessibilityRules {
  static let all: [any Rule] = [inputLabel]

  /// A text input's title is its placeholder: the accessibility tree shows it as one and gives
  /// the field no label.
  private static let inputs: Set<String> = ["TextField", "SecureField", "TextEditor"]

  static let inputLabel = SyntaxLintRule(
    id: "a11y.input-label",
    summary: "a text input with an accessibility identifier but no accessibility label",
    scope: LintScopes.productionFiles
  ) { unit, index, _ in
    index.calls.compactMap { call -> RuleViolation? in
      guard let name = call.calledName, inputs.contains(name), call.calledMember == nil,
        !call.argumentLabels.contains("prompt")
      else { return nil }
      let (outermost, modifiers) = chain(from: call)
      guard modifiers.contains("accessibilityIdentifier"),
        !modifiers.contains("accessibilityLabel"), !isInsideLabeledView(outermost)
      else { return nil }
      let start = unit.line(of: call.positionAfterSkippingLeadingTrivia)
      return RuleViolation(
        path: unit.path, lines: start...unit.lines(of: outermost).upperBound,
        message:
          "`\(name)` has an accessibility identifier but no label, and its title is only a "
          + "placeholder; add `.accessibilityLabel(\"…\")`, or "
          + "`// swiftgate:allow a11y.input-label — <where its label comes from>` on this line",
        failureScenario:
          "the simulator audit's `sim.a11y-label` fails every flow row that reaches the screen")
    }
  }

  /// The view modifiers applied to `call`, outward, and the last call of that chain.
  private static func chain(from call: FunctionCallExprSyntax)
    -> (FunctionCallExprSyntax, [String])
  {
    var current = call
    var names: [String] = []
    while let member = current.parent?.as(MemberAccessExprSyntax.self),
      member.base?.id == current.id,
      let next = member.parent?.as(FunctionCallExprSyntax.self),
      next.calledExpression.id == member.id
    {
      names.append(member.declName.baseName.text)
      current = next
    }
    return (current, names)
  }

  /// Inside a `LabeledContent`, or inside a view whose own chain carries a label.
  private static func isInsideLabeledView(_ node: FunctionCallExprSyntax) -> Bool {
    var child = Syntax(node)
    var ancestor = node.parent
    while let current = ancestor {
      if let call = current.as(FunctionCallExprSyntax.self) {
        if call.calledExpression.id == child.id {
          if call.calledName == "accessibilityLabel" { return true }
        } else if call.calledName == "LabeledContent" {
          return true
        }
      }
      child = current
      ancestor = current.parent
    }
    return false
  }
}

/// `a11y.input-label` over the Swift files a brownfield change adds or edits, on their added lines
/// only, so a field the change didn't touch never gates it.
public enum ChangedInputLabels {
  public static let ruleID = AccessibilityRules.inputLabel.descriptor.id

  /// The rule's findings in `files`' Swift sources.
  public static func findings(_ files: [ChangedTestFile]) -> [Finding] {
    let swift = files.filter { $0.path.hasSuffix(".swift") }
    guard !swift.isEmpty else { return [] }
    let engine = RuleEngine(rules: [AccessibilityRules.inputLabel])
    let result = try? engine.run(
      swift.map { SourceInput(path: $0.path, text: $0.content) },
      context: RuleContext(scopes: StaticModuleScopes()), restrictTo: swift.map(\.added))
    return result?.findings ?? []
  }
}
