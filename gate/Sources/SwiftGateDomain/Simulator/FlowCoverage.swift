/// Spec §7.3: T3 is a closed list. Judged from the UI test cases a T3 run actually executed.
///
/// - Every UI test maps to a `[[flows]]` entry: its method name after `test`, or its class name,
///   starts with the flow's name (case- and punctuation-insensitive), the same mapping testlint
///   applies statically.
/// - At most `pyramid.max_flows` UI tests run. The config already caps the flow list; this caps
///   the tests, so one flow cannot quietly grow into a suite.
/// - Every declared flow has a test: a critical flow without one is a gap, not a pass.
public enum FlowCoverage {
  public static let unmappedRuleID = "t3.unmapped-flow"
  public static let maxFlowsRuleID = "t3.max-flows"
  public static let untestedFlowRuleID = "t3.flow-untested"

  /// `identifier` is `<Class>/<method>()` as the result bundle names it.
  public static func flow(forTest identifier: String, flows: [Flow]) -> Flow? {
    let parts = identifier.split(separator: "/", maxSplits: 1)
    let type = normalized(parts.first.map(String.init) ?? "")
    var method = parts.count > 1 ? String(parts[1]) : ""
    if method.hasSuffix("()") { method.removeLast(2) }
    if method.hasPrefix("test") { method.removeFirst("test".count) }
    let key = normalized(method)
    return flows.first { flow in
      let name = normalized(flow.name)
      return !name.isEmpty && (key.hasPrefix(name) || type.hasPrefix(name))
    }
  }

  /// - Parameter file: where findings point, normally the app container.
  public static func findings(uiTests: [String], flows: [Flow], maxFlows: Int, file: String)
    -> [Finding]
  {
    var findings: [(rule: String, message: String)] = []
    var tested = Set<String>()
    for test in uiTests {
      if let flow = flow(forTest: test, flows: flows) {
        tested.insert(flow.name)
      } else {
        findings.append(
          (
            unmappedRuleID,
            "UI test \(test) maps to no [[flows]] entry "
              + "(\(flows.map(\.name).joined(separator: ", "))); cover it at T1/T2 or declare "
              + "the flow with a reason"
          ))
      }
    }
    for flow in flows where !tested.contains(flow.name) {
      findings.append(
        (
          untestedFlowRuleID,
          "flow \"\(flow.name)\" has no UI test that ran; add its test or remove the flow"
        ))
    }
    if uiTests.count > maxFlows {
      findings.append(
        (
          maxFlowsRuleID,
          "\(uiTests.count) UI tests ran; pyramid.max_flows allows \(maxFlows). "
            + "Move the extra coverage down to T1/T2"
        ))
    }
    // Rule ids and messages are never empty, so the report contract cannot reject these.
    return findings.compactMap { rule, message in
      try? Finding(
        ruleID: rule, severity: .major, file: file.isEmpty ? "." : file, line: nil,
        message: message, failureScenario: nil)
    }
  }

  static func normalized(_ text: String) -> String {
    String(text.lowercased().filter { $0.isLetter || $0.isNumber })
  }
}
