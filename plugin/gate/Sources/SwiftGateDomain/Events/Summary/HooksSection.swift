import Foundation

/// Hook latency per event, blocks per rule, and bypassed blocks.
public struct HooksSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .hooks }

  /// A PostToolUse for the same input this long after a PreToolUse block means the call ran anyway.
  static let bypassWindow: TimeInterval = 10 * 60
  /// The group a block that names no rule id is counted under.
  static let noRule = "no rule"

  private struct Call {
    let time: Date
    let decision: HookDecisionEvent
  }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    var calls: [Call] = []
    for stored in input.events {
      guard case .hookDecision(let decision) = stored.event.payload else { continue }
      calls.append(Call(time: stored.event.time, decision: decision))
    }
    guard !calls.isEmpty else { return nil }

    var lines: [String] = []
    var metrics: [EventSummaryMetric] = []
    latency(calls, lines: &lines, metrics: &metrics)
    blocksPerRule(calls, lines: &lines, metrics: &metrics)
    bypasses(calls, lines: &lines, metrics: &metrics)
    return EventSummarySectionReport(id: id, state: .reported, lines: lines, metrics: metrics)
  }

  private func latency(
    _ calls: [Call], lines: inout [String], metrics: inout [EventSummaryMetric]
  ) {
    for event in HookEvent.allCases {
      let ofEvent = calls.filter { $0.decision.event == event }
      guard let stats = TimingStats(milliseconds: ofEvent.map(\.decision.milliseconds)) else {
        continue
      }
      let group = ["latency", event.rawValue]
      metrics += [
        EventSummaryMetric(
          name: "p50", group: group, value: Double(stats.p50), unit: .milliseconds, n: stats.n),
        EventSummaryMetric(
          name: "p95", group: group, value: Double(stats.p95), unit: .milliseconds, n: stats.n),
        EventSummaryMetric(
          name: "sd", group: group, value: stats.standardDeviation, unit: .milliseconds,
          n: stats.n),
      ]
      lines.append("\(event.rawValue): \(stats.rendered)")
      var counts: [String] = []
      for decision in HookDecision.allCases {
        let count = ofEvent.count { $0.decision.decision == decision }
        guard count > 0 else { continue }
        metrics.append(
          EventSummaryMetric(
            name: "decisions", group: ["decision", event.rawValue, decision.rawValue],
            value: Double(count), unit: .count, n: ofEvent.count))
        counts.append("\(decision.rawValue) \(count)")
      }
      lines.append("  decisions: \(counts.joined(separator: ", ")) (n=\(ofEvent.count))")
    }
  }

  private func blocksPerRule(
    _ calls: [Call], lines: inout [String], metrics: inout [EventSummaryMetric]
  ) {
    let blocks = calls.filter { $0.decision.decision == .block }
    guard !blocks.isEmpty else {
      lines.append("blocks per rule: no blocks (n=0)")
      return
    }
    let perRule = Self.perRule(blocks)
    lines.append("blocks per rule (n=\(blocks.count) blocks):")
    for (rule, count) in perRule {
      metrics.append(
        EventSummaryMetric(
          name: "blocks", group: ["rule", rule], value: Double(count), unit: .count,
          n: blocks.count))
      lines.append("  \(rule): \(count)")
    }
  }

  /// Each rule with how many of `blocks` name it, most first; a block naming none counts once
  /// under ``noRule``.
  private static func perRule(_ blocks: [Call]) -> [(rule: String, count: Int)] {
    var counts: [String: Int] = [:]
    for block in blocks {
      let rules = block.decision.ruleIDs.isEmpty ? [noRule] : Set(block.decision.ruleIDs).sorted()
      for rule in rules { counts[rule, default: 0] += 1 }
    }
    return counts.map { (rule: $0.key, count: $0.value) }
      .sorted { ($1.count, $0.rule) < ($0.count, $1.rule) }
  }

  /// A PreToolUse block followed, in the same session and within ``bypassWindow``, by a
  /// PostToolUse for a call with the same input hash: the call ran despite the block.
  private func bypasses(
    _ calls: [Call], lines: inout [String], metrics: inout [EventSummaryMetric]
  ) {
    let blocks = calls.filter { $0.decision.event == .preToolUse && $0.decision.decision == .block }
    let matchable = blocks.filter { $0.decision.sessionID != nil && $0.decision.inputHash != nil }
    let posts = calls.filter { $0.decision.event == .postToolUse }
    let bypassed = matchable.filter { block in
      posts.contains { post in
        post.decision.sessionID == block.decision.sessionID
          && post.decision.inputHash == block.decision.inputHash
          && post.time >= block.time
          && post.time.timeIntervalSince(block.time) <= Self.bypassWindow
      }
    }
    metrics.append(
      EventSummaryMetric(
        name: "bypassed", group: ["bypassed"], value: Double(bypassed.count), unit: .count,
        n: matchable.count))
    lines.append(
      "bypassed blocks: \(bypassed.count) of \(matchable.count) PreToolUse blocks "
        + "(n=\(matchable.count))")
    for (rule, count) in Self.perRule(bypassed) {
      metrics.append(
        EventSummaryMetric(
          name: "bypassed", group: ["bypassed", rule], value: Double(count), unit: .count,
          n: matchable.count))
      lines.append("  \(rule): \(count)")
    }
    let unmatchable = blocks.count - matchable.count
    if unmatchable > 0 {
      metrics.append(
        EventSummaryMetric(
          name: "unmatchable-blocks", group: ["bypassed"], value: Double(unmatchable),
          unit: .count, n: blocks.count))
      lines.append(
        "  \(unmatchable) PreToolUse blocks carry no session id or input hash, "
          + "so they can't be matched")
    }
  }
}
