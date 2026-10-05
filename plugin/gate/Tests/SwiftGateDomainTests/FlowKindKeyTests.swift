import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// `qa.flow-kind-key`: a step whose `kind` or `predicate` names 1 input key and whose target sits
/// under another, which the pinned tool runs as another step.
@Suite("flow rules: a step's kind and its input keys")
struct FlowKindKeyTests {
  static func check(_ path: String) throws -> [Finding] {
    FlowRules.check(
      file: path, data: try Fixture.data(path), schemas: try FlowRulesTests.schemas(),
      ids: .undeclarable)
  }

  static func check(json: String) throws -> [Finding] {
    FlowRules.check(
      file: "qa/inline.flow.json", data: Data(json.utf8), schemas: try FlowRulesTests.schemas(),
      ids: .undeclarable)
  }

  @Test(
    "the pairing names every `wait` kind of the pinned schema's `kind` enum, each with a key the schema's `wait` input allows — catches a pairing that drifts from the pinned tool"
  )
  func pairingMatchesThePinnedSchema() throws {
    let folder = Fixture.checkoutRoot.appending(path: "qa", directoryHint: .isDirectory)
    let file = folder.appending(path: "agent-device-schemas-0.21.18.json")
    let root = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let tools = try #require(root["tools"] as? [[String: Any]])
    let wait = try #require(tools.first { $0["name"] as? String == "wait" })
    let schema = try #require(wait["inputSchema"] as? [String: Any])
    let properties = try #require(schema["properties"] as? [String: Any])
    let kinds = try #require((properties["kind"] as? [String: Any])?["enum"] as? [String])
    #expect(Set(FlowRules.waitTargetKeys.keys) == Set(kinds))
    for key in FlowRules.waitTargetKeys.values {
      #expect(properties[key] != nil, "`wait` has no input key \(key)")
    }
  }

  @Test(
    "the trial's launch, retry and detail-chart flows each fail qa.flow-kind-key at their `kind: absent` wait whose target sits under `selector`, naming the step and the step to write, and its chart-failure flow passes — catches the wait that ran as a wait to appear and timed out on a correct app"
  )
  func trialWaitsFail() throws {
    let folder = WaitAbsentRepairTrial.folder
    let expected = [
      ("watchlist-launch.flow.json", 21, "watchlist.loading"),
      ("watchlist-retry.flow.json", 7, "watchlist.error"),
      ("detail-chart.flow.json", 6, "detail.chart.loading"),
    ]
    for (name, step, id) in expected {
      let findings = try Self.check("\(folder)/\(name)")
      #expect(findings.map(\.ruleID) == [FlowRules.kindKeyRuleID], "\(name): \(findings)")
      let message = try #require(findings.first?.message)
      #expect(message.contains("step \(step) `wait`"), "\(message)")
      #expect(message.contains(#""absent":"id=\"\#(id)\"""#), "\(message)")
      #expect(message.contains("`selector`"), "\(message)")
    }
    #expect(try Self.check("\(folder)/detail-chart-failure.flow.json").isEmpty)
  }

  @Test(
    "the captured batch of every wait kind, which the pinned tool ran green, passes, and both captured batches with a `kind: absent` target under `selector` fail qa.flow-kind-key — catches a rule looser or stricter than the tool"
  )
  func capturedBatches() throws {
    let folder = "AgentDevice/wait-kinds"
    #expect(try Fixture.data("\(folder)/kinds.status") == Data("0\n".utf8))
    #expect(try Self.check("\(folder)/kinds.steps.json").isEmpty)
    for name in ["absent-in-selector", "absent-in-selector-while-loading"] {
      #expect(try Fixture.data("\(folder)/\(name).status") == Data("1\n".utf8))
      let rules = try Self.check("\(folder)/\(name).steps.json").map(\.ruleID)
      #expect(rules == [FlowRules.kindKeyRuleID], "\(name): \(rules)")
    }
  }

  @Test(
    "a `wait` with no target key, or with 2, an `is text` with no `value`, and an `is visible` with a `value` it would drop each fail qa.flow-kind-key — catches the other steps whose keys the tool reads by kind"
  )
  func otherShapes() throws {
    let cases = [
      #"[{"command":"wait","input":{"kind":"absent","timeoutMs":5000}}]"#,
      #"[{"command":"wait","input":{"text":"Bitcoin","selector":"id=\"watchlist.row.bitcoin\""}}]"#,
      #"[{"command":"is","input":{"predicate":"text","selector":"id=\"watchlist.row.bitcoin.name\""}}]"#,
      #"[{"command":"is","input":{"predicate":"visible","selector":"id=\"watchlist.row.bitcoin.name\"","value":"Bitcoin"}}]"#,
    ]
    for json in cases {
      let rules = try Self.check(json: json).map(\.ruleID)
      #expect(rules.contains(FlowRules.kindKeyRuleID), "\(json): \(rules)")
    }
    let clean = #"[{"command":"is","input":{"predicate":"text","selector":"id=\"watchlist.row.bitcoin.name\"","value":"Bitcoin"}}]"#
    #expect(try Self.check(json: clean).isEmpty)
  }
}
