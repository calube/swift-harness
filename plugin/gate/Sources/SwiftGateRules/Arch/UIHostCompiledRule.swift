import SwiftGateDomain
import SwiftSyntax

/// A UI module whose files sit wholly inside a platform-only `#if` builds as an empty module on
/// the macOS host, so host builds and tests never type-check its views (standards U5).
struct UIHostCompiledRule: FileRule {
  static let id = "arch.ui-host-compiled"

  let descriptor = RuleDescriptor(
    id: Self.id, severity: .major,
    summary: "UI file compiled out on the macOS host by a platform-only #if")
  let scope = RuleScope { unit in unit.scope?.role == .ui && !unit.isTestFile }

  /// `os(...)` platforms the macOS host never is. Anything else (`macOS`, `Linux`, a custom flag)
  /// is treated as possibly true, so the rule only fires on conditions it can decide.
  private static let hostlessPlatforms: Set<String> = ["iOS", "tvOS", "watchOS", "visionOS"]

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    var tally = Tally()
    tally.walk(unit.tree.statements, excludedBy: nil)
    guard tally.hostDeclarations == 0, let guardingIf = tally.firstExcludingIf else { return [] }
    let condition =
      guardingIf.clauses.first?.condition?.trimmedDescription ?? "a platform-only condition"
    return [
      unit.violation(
        atStartOf: guardingIf,
        message:
          "\(unit.path) compiles to nothing on the macOS host: every declaration sits under "
          + "`#if \(condition)`, which the host never meets; guard only the iOS-only modifiers or types so "
          + "host builds type-check the rest",
        failureScenario:
          "a broken view first fails in the app build or the final ready gate, not in host builds"
      )
    ]
  }

  /// Top-level declarations, imports aside, split by whether some enclosing `#if` clause keeps
  /// them off the host. A `#else` branch has no condition, so its declarations count as host
  /// ones, and an empty `#else` leaves the file as empty on the host as no `#else` at all.
  private struct Tally {
    var hostDeclarations = 0
    var firstExcludingIf: IfConfigDeclSyntax?

    mutating func walk(_ items: CodeBlockItemListSyntax, excludedBy: IfConfigDeclSyntax?) {
      for item in items {
        if let ifConfig = item.item.as(IfConfigDeclSyntax.self) {
          visit(ifConfig, excludedBy: excludedBy)
        } else if item.item.is(ImportDeclSyntax.self) {
          continue
        } else if let excludedBy {
          if firstExcludingIf == nil { firstExcludingIf = excludedBy }
        } else {
          hostDeclarations += 1
        }
      }
    }

    private mutating func visit(_ ifConfig: IfConfigDeclSyntax, excludedBy: IfConfigDeclSyntax?) {
      for clause in ifConfig.clauses {
        guard case .statements(let items) = clause.elements else { continue }
        let excludes = clause.condition.map(UIHostCompiledRule.neverOnHost) == true
        walk(items, excludedBy: excludedBy ?? (excludes ? ifConfig : nil))
      }
    }
  }

  /// Whether a compilation condition is false on the macOS host: a hostless `os(...)`,
  /// `canImport(UIKit)`, or `&&`/`||` of those.
  static func neverOnHost(_ condition: ExprSyntax) -> Bool {
    if let tuple = condition.as(TupleExprSyntax.self), tuple.elements.count == 1,
      let only = tuple.elements.first
    {
      return neverOnHost(only.expression)
    }
    if let call = condition.as(FunctionCallExprSyntax.self),
      let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
      call.arguments.count == 1, let argument = call.arguments.first?.expression.trimmedDescription
    {
      switch name {
      case "os": return hostlessPlatforms.contains(argument)
      case "canImport": return argument == "UIKit"
      default: return false
      }
    }
    if let infix = condition.as(InfixOperatorExprSyntax.self),
      let op = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text
    {
      return combine(op, neverOnHost(infix.leftOperand), neverOnHost(infix.rightOperand)) ?? false
    }
    if let sequence = condition.as(SequenceExprSyntax.self) {
      return sequenceNeverOnHost(Array(sequence.elements))
    }
    return false
  }

  private static func combine(_ op: String, _ left: Bool, _ right: Bool) -> Bool? {
    switch op {
    case "&&": return left || right
    case "||": return left && right
    default: return nil
    }
  }

  /// An unfolded `a && b || c` chain: `&&` binds tighter, so it is false when every `||` group
  /// has a false operand.
  private static func sequenceNeverOnHost(_ elements: [ExprSyntax]) -> Bool {
    var groups: [[ExprSyntax]] = [[]]
    for (index, element) in elements.enumerated() {
      guard index % 2 == 1 else {
        groups[groups.count - 1].append(element)
        continue
      }
      switch element.as(BinaryOperatorExprSyntax.self)?.operator.text {
      case "||": groups.append([])
      case "&&": continue
      default: return false
      }
    }
    return groups.allSatisfy { group in group.contains(where: neverOnHost) }
  }
}
