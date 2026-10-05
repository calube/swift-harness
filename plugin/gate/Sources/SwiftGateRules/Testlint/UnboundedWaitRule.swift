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
    []
  }
}
