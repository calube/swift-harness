/// The judge's decisions, escalation share and agreement per question and backend, and its calls
/// per backend: the summary view of the judge audit log. The numbers come from
/// ``JudgeEventSummary``, the same summary `judge events` prints.
public struct JudgeSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .judge }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    // The reader already applied `--since` and `--run`, so the filter keeps everything.
    let events = input.events.map(\.event).filter { $0.kind.stream == .judge }
    let summary = JudgeEventSummary.make(
      HarnessEventJSON.Read(events: events, tornLastLine: false), filter: JudgeEventFilter())
    guard summary.events > 0 else { return nil }
    let lines =
      ["judge events: \(summary.events) (n=\(summary.events))"]
      + summary.bodyLines(listBlocks: false).filter { !$0.isEmpty }
    return EventSummarySectionReport(
      id: id, state: .reported, lines: lines, metrics: Self.metrics(summary))
  }

  static func metrics(_ summary: JudgeEventSummary) -> [EventSummaryMetric] {
    var metrics: [EventSummaryMetric] = []
    func add(
      _ name: String, _ group: [String], _ value: Double, _ unit: EventSummaryMetric.Unit, n: Int
    ) {
      metrics.append(EventSummaryMetric(name: name, group: group, value: value, unit: unit, n: n))
    }
    for row in summary.questions {
      let group = [row.question, row.backend.rawValue]
      let kinds: [(JudgeDecision, Int)] = [
        (.block, row.block), (.advisory, row.advisory), (.pass, row.pass), (.error, row.error),
      ]
      for (kind, count) in kinds where count > 0 {
        add("decisions", group + [kind.rawValue], Double(count), .count, n: row.judgements)
      }
      add(
        "escalation-share", group, Double(row.escalated) / Double(row.judgements), .share,
        n: row.judgements)
      for reason in row.blockReasons {
        add("blocks", group + [reason.key.rawValue], Double(reason.count), .count, n: row.block)
      }
      if row.escalationsCompared > 0 {
        add(
          "agreement", group,
          Double(row.escalationsAgreed) / Double(row.escalationsCompared), .share,
          n: row.escalationsCompared)
      }
    }
    if let share = summary.escalationShare {
      add("escalation-share", [], share, .share, n: summary.jevDecisions)
    }
    if let agreement = summary.agreement {
      add("agreement", [], agreement, .share, n: summary.escalationsCompared)
    }
    for row in summary.backends {
      let group = [row.backend.rawValue]
      if let p50 = row.latencyP50Ms, let p95 = row.latencyP95Ms {
        add("latency-p50", group, Double(p50), .milliseconds, n: row.reachedCalls)
        add("latency-p95", group, Double(p95), .milliseconds, n: row.reachedCalls)
      }
      add("cache-hits", group, Double(row.cacheHits), .count, n: row.calls)
      add("call-errors", group, Double(row.errors), .count, n: row.calls)
      add("cost-usd", group, row.costUSD, .usd, n: row.calls - row.callsWithoutCost)
      add("calls-without-cost", group, Double(row.callsWithoutCost), .count, n: row.calls)
    }
    return metrics
  }
}
