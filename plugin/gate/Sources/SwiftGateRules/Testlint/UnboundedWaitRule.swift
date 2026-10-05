import SwiftGateDomain
import SwiftSyntax

/// A test that polls a flag in a loop with no bound of its own spins forever when the flag never
/// flips, as it doesn't with the change under test reverted: the gate that runs it then waits on
/// its deadline instead of failing (testing playbook P12).
struct UnboundedWaitRule: FileRule {
  static let id = "test.unbounded-wait"

  let descriptor = RuleDescriptor(
    id: Self.id, severity: .major,
    summary: "a test polls in a loop that only awaits, with no deadline or attempt cap")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    let whiles = unit.tree.descendants(of: WhileStmtSyntax.self).map {
      (Syntax($0), $0.conditions.trimmedDescription, $0.body)
    }
    let repeats = unit.tree.descendants(of: RepeatStmtSyntax.self).map {
      (Syntax($0), $0.condition.trimmedDescription, $0.body)
    }
    return (whiles + repeats).compactMap { loop, condition, body in
      guard Self.awaits(body), !Self.isBounded(condition), !Self.leaves(body, loop: loop) else {
        return nil
      }
      return unit.violation(
        at: loop,
        message:
          "this loop waits on `\(condition)` by awaiting, with no deadline or attempt cap in its "
          + "condition and no break, return or throw in its body; bound it (a clock deadline, a "
          + "turn count) and record an issue when the bound passes",
        failureScenario:
          "the condition never holds with the change reverted, so the test spins until the gate's "
          + "own deadline kills it instead of failing")
    }
  }

  private static func awaits(_ body: CodeBlockSyntax) -> Bool {
    body.descendants(of: AwaitExprSyntax.self).contains { !inNestedClosure($0, below: body) }
  }

  /// A comparison or a name that reads as a bound.
  private static func isBounded(_ condition: String) -> Bool {
    let bounds: [Regex<Substring>] = [
      /[<>]=?/, /deadline|timeout|attempt|tries|retries|remaining|elapsed|turns/.ignoresCase(),
      /\bDate\b/, /\bclock\b/.ignoresCase(),
    ]
    return bounds.contains { condition.contains($0) }
  }

  /// A `break` aimed at this loop, or a `return` or `throw` outside any closure in it.
  private static func leaves(_ body: CodeBlockSyntax, loop: Syntax) -> Bool {
    let breaks = body.descendants(of: BreakStmtSyntax.self).contains { statement in
      statement.label != nil || nearestBreakTarget(of: Syntax(statement)) == loop
    }
    let exits =
      body.descendants(of: ReturnStmtSyntax.self).contains { !inNestedClosure($0, below: body) }
      || body.descendants(of: ThrowStmtSyntax.self).contains { !inNestedClosure($0, below: body) }
    return breaks || exits
  }

  private static func nearestBreakTarget(of node: Syntax) -> Syntax? {
    var current = node.parent
    while let next = current {
      if next.is(WhileStmtSyntax.self) || next.is(RepeatStmtSyntax.self)
        || next.is(ForStmtSyntax.self) || next.is(SwitchExprSyntax.self)
      {
        return next
      }
      current = next.parent
    }
    return nil
  }

  private static func inNestedClosure(_ node: some SyntaxProtocol, below body: CodeBlockSyntax)
    -> Bool
  {
    var current = node.parent
    while let next = current, next.id != body.id {
      if next.is(ClosureExprSyntax.self) || next.is(FunctionDeclSyntax.self) { return true }
      current = next.parent
    }
    return false
  }
}
