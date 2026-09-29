import SwiftGateTestSupport
import Testing

/// The scan that reads rule ids from the gate's source for the rule id index check.
@Suite("rule id source scan")
struct RuleIDSourceScanTests {
  @Test(
    "file names, URLs, anchors, test ids, config keys and prose never count as rule ids — catches a look-alike demanded as an index row"
  )
  func lookAlikesAreNotIds() {
    let source = #"""
      let file = "review-telemetry.json", doc = "standards.md", url = "https://example.com/a.b"
      let anchor = "standards.md#rule-id-index", test = "RuleIndexTests.sourceIdsAreIndexed"
      let changed = "\(target).\(function)", key = "budgets.\(name)", git = "commit.gpgsign"
      let thread = "swiftgate.process", sentence = "denied.", config = "simulator.device"
      // a comment quoting "plan-lint.commented-out"
      let real = Finding(ruleID: "plan-lint.dag-cycle")
      """#

    let scan = RuleIDSourceScan.scan(source: source)

    #expect(scan == RuleIDSourceScan(ids: ["plan-lint.dag-cycle"], families: []))
  }
}
