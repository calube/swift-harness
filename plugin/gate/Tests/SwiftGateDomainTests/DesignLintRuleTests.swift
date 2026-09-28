import Foundation
import SwiftGateDomain
import Testing

@Suite("Design lint — rule ids")
struct DesignLintRuleTests {
  @Test(
    "every section finding design-lint reports carries a DesignLintRule id — catches a finding whose id the rule id index can't enumerate"
  )
  func sectionFindingsUseTheClosedRuleSet() throws {
    var findings: [Finding] = []
    for name in ["missing-risks.md", "out-of-order.md"] {
      findings += try DesignLintSections.check(
        document: DesignLintSectionsTests.fixture(name), docPath: "docs/designs/x.md",
        otherDesignIds: [])
    }
    let known = Set(DesignLintRule.allCases.map(\.rawValue))

    #expect(Set(findings.map(\.ruleID)).isSuperset(of: ["design-lint.section-missing"]))
    #expect(findings.filter { !known.contains($0.ruleID) }.map(\.ruleID) == [])
  }
}
