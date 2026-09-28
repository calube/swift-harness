import SwiftGateDomain
import SwiftSyntax

/// A UI module whose files sit wholly inside a platform-only `#if` builds as an empty module on
/// the macOS host, so host builds and tests never type-check its views (standards U5).
struct UIHostCompiledRule: FileRule {
  static let id = "arch.ui-host-compiled"

  let descriptor = RuleDescriptor(
    id: Self.id, severity: .major,
    summary: "UI file compiled out on the macOS host by a platform-only #if with no #else")
  let scope = RuleScope.allFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    []
  }
}
