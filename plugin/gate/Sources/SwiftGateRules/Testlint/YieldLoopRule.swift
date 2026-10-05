import SwiftGateDomain
import SwiftSyntax

/// A test that waits by yielding a fixed number of times guesses how many scheduler turns another
/// task needs, the way a sleep guesses a duration: it passes or fails with machine load, and it
/// can hide an effect that never started (testing playbook P7). A loop that yields while it checks
/// a condition is a poll, which `test.unbounded-wait` judges instead.
struct YieldLoopRule: FileRule {
  static let id = "test.yield-loop"

  let descriptor = RuleDescriptor(
    id: Self.id, severity: .major,
    summary: "a test waits by yielding a fixed number of times")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    unit.tree.descendants(of: ForStmtSyntax.self).compactMap { loop in
      guard loop.awaitKeyword == nil, loop.pattern.is(WildcardPatternSyntax.self),
        Self.yields(loop.body), !Self.checksCondition(loop.body)
      else { return nil }
      let sequence = loop.sequence.trimmedDescription
      return unit.violation(
        at: loop,
        message:
          "this loop waits by yielding once per element of `\(sequence)`, a guess at how many "
          + "turns another task needs, like a sleep; for an effect on a clock, inject a "
          + "`TestClock` and run the test inside `withMainSerialExecutor` in a `.serialized` "
          + "suite, so `advance` runs the effect without yields, then assert with "
          + "`store.receive`; otherwise await the work itself or poll its condition with a "
          + "deadline",
        failureScenario:
          "under load the other task needs more turns than the count, so the test fails with "
          + "no code change; or the count runs out quietly and hides an effect that never started")
    }
  }

  /// Whether the body awaits `Task.yield()` or `Task.megaYield()` itself, outside any closure.
  private static func yields(_ body: CodeBlockSyntax) -> Bool {
    body.descendants(of: FunctionCallExprSyntax.self).contains { call in
      guard let callee = call.callee, callee.base == "Task",
        callee.name == "yield" || callee.name == "megaYield"
      else { return false }
      return !inNestedClosure(call, below: body)
    }
  }

  /// A branch or an exit in the body makes the loop a poll on a condition, not a fixed count.
  private static func checksCondition(_ body: CodeBlockSyntax) -> Bool {
    let branches: [any SyntaxProtocol] =
      body.descendants(of: IfExprSyntax.self) + body.descendants(of: GuardStmtSyntax.self)
      + body.descendants(of: BreakStmtSyntax.self) + body.descendants(of: ReturnStmtSyntax.self)
      + body.descendants(of: ThrowStmtSyntax.self)
    return branches.contains { !inNestedClosure($0, below: body) }
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
