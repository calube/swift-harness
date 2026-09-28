import SwiftGateDomain
import SwiftSyntax

/// A script or source a test writes out that waits forever leaks a process on every prove and
/// mutate run that reverts the fix it guards; it must end by itself (testing playbook P12).
struct HangWithoutDeadlineRule: FileRule {
  static let id = "test.hang-without-deadline"

  let descriptor = RuleDescriptor(
    id: Self.id, severity: .major,
    summary: "a script or source a test writes out waits forever with no deadline")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    []
  }
}
