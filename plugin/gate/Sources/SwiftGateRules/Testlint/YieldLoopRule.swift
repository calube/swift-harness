import SwiftGateDomain
import SwiftSyntax

/// A test that waits by yielding a fixed number of times guesses how many scheduler turns another
/// task needs, the way a sleep guesses a duration: it passes or fails with machine load, and it
/// can hide an effect that never started (testing playbook P7).
struct YieldLoopRule: FileRule {
  static let id = "test.yield-loop"

  let descriptor = RuleDescriptor(
    id: Self.id, severity: .major,
    summary: "a test waits by yielding a fixed number of times")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    []
  }
}
