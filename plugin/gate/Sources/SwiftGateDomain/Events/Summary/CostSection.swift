import Foundation

/// The cost of agents and the judge, by role, agent, model, task, build run and design phase.
/// Every dollar figure carries the count of priced messages behind it; a message the price table
/// couldn't price is counted apart with its tokens, never as $0.
public struct CostSection: EventSummarySection {
  /// Rates for splitting a priced message's cost into cache reads and fresh input.
  public let prices: ModelPriceTable

  public init(prices: ModelPriceTable = .current) {
    self.prices = prices
  }

  public var id: EventSummarySectionID { .cost }

  static let noRole = "no role"
  static let noTask = "no task"
  static let noBuildRun = "no build run"

  /// What a group of `agent.usage` messages used and cost.
  private struct Tally {
    var messages = 0
    var priced = 0
    var usd = 0.0
    var tokens = Tokens()
    var unpriced = 0
    var unpricedTokens = Tokens()
    var unpricedModels: Set<String> = []

    mutating func add(_ usage: AgentUsageEvent) {
      messages += 1
      tokens.add(usage)
      if let cost = usage.costUSD {
        priced += 1
        usd += cost
      } else {
        unpriced += 1
        unpricedTokens.add(usage)
        unpricedModels.insert(usage.model)
      }
    }
  }

  private struct Tokens {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0

    mutating func add(_ usage: AgentUsageEvent) {
      input += usage.inputTokens
      output += usage.outputTokens
      cacheWrite += usage.cacheCreationTokens
      cacheRead += usage.cacheReadTokens
    }

    var rendered: String {
      "tokens in \(input), out \(output), cache write \(cacheWrite), cache read \(cacheRead)"
    }

    func metrics(prefix: String, group: [String], n: Int) -> [EventSummaryMetric] {
      [
        ("input-tokens", input), ("output-tokens", output), ("cache-write-tokens", cacheWrite),
        ("cache-read-tokens", cacheRead),
      ].map {
        EventSummaryMetric(
          name: prefix + $0.0, group: group, value: Double($0.1), unit: .count, n: n)
      }
    }
  }

  private struct JudgeTally {
    var calls = 0
    var costed = 0
    var usd = 0.0
  }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    var usages: [AgentUsageEvent] = []
    var judgeCalls: [JudgeCallEvent] = []
    for stored in input.events {
      switch stored.event.payload {
      case .agentUsage(let usage):
        if let buildRun = input.query.buildRunID, usage.buildRun != buildRun { continue }
        usages.append(usage)
      case .judgeCall(let call): judgeCalls.append(call)
      default: continue
      }
    }
    var lines: [String] = []
    if let buildRun = input.query.buildRunID, !judgeCalls.isEmpty {
      lines.append("judge calls name no build run, so none is counted for build run \(buildRun)")
      judgeCalls = []
    }
    guard !usages.isEmpty || !judgeCalls.isEmpty else { return nil }

    var metrics: [EventSummaryMetric] = []
    if !usages.isEmpty {
      report(usages: usages, files: input.files, lines: &lines, metrics: &metrics)
    }
    report(judgeCalls: judgeCalls, lines: &lines, metrics: &metrics)
    return EventSummarySectionReport(id: id, state: .reported, lines: lines, metrics: metrics)
  }

  private func report(
    usages: [AgentUsageEvent], files: any EventStoreFileReading, lines: inout [String],
    metrics: inout [EventSummaryMetric]
  ) {
    var total = Tally()
    var groups: [[String]: Tally] = [:]
    for usage in usages {
      total.add(usage)
      for group in [
        ["role", usage.role?.rawValue ?? Self.noRole], ["agent", usage.agent.rawValue],
        ["model", usage.model], ["task", usage.task ?? Self.noTask],
        ["build-run", usage.buildRun ?? Self.noBuildRun],
      ] {
        groups[group, default: Tally()].add(usage)
      }
    }

    lines.append(Self.line("total", total))
    metrics += Self.metrics(total, group: ["total"])
    if total.unpriced > 0 {
      let models = total.unpricedModels.sorted().joined(separator: ", ")
      lines.append(
        "unpriced: \(total.unpriced) messages (\(models)); \(total.unpricedTokens.rendered)")
      metrics += total.unpricedTokens.metrics(
        prefix: "unpriced-", group: ["total"], n: total.unpriced)
    }
    shares(usages, lines: &lines, metrics: &metrics)

    for dimension in ["role", "agent", "model", "task", "build-run"] {
      for group in groups.keys.filter({ $0.first == dimension }).sorted(by: { $0[1] < $1[1] }) {
        guard let tally = groups[group] else { continue }
        lines.append(Self.line(group.joined(separator: " "), tally))
        metrics += Self.metrics(tally, group: group)
      }
    }
    phases(usages, files: files, lines: &lines, metrics: &metrics)
  }

  /// Per backend and model: the reported cost over the calls that reported one, every call
  /// counted. A cache hit reports $0 and is still a call; a call that reported nothing isn't $0.
  private func report(
    judgeCalls: [JudgeCallEvent], lines: inout [String], metrics: inout [EventSummaryMetric]
  ) {
    var tallies: [[String]: JudgeTally] = [:]
    for call in judgeCalls {
      let group = ["judge", call.backend.rawValue, call.model]
      var tally = tallies[group, default: JudgeTally()]
      tally.calls += 1
      if let cost = call.costUSD {
        tally.costed += 1
        tally.usd += cost
      }
      tallies[group] = tally
    }
    let ordered = tallies.keys.sorted {
      $0.joined(separator: " ") < $1.joined(separator: " ")
    }
    for group in ordered {
      guard let tally = tallies[group] else { continue }
      var parts: [String] = []
      if tally.costed > 0 { parts.append("\(Self.money(tally.usd)) (n=\(tally.costed))") }
      let without = tally.calls - tally.costed
      if without > 0 { parts.append("no cost reported: \(without) calls") }
      parts.append("\(tally.calls) calls")
      lines.append("\(group.joined(separator: " ")): " + parts.joined(separator: "; "))
      if tally.costed > 0 {
        metrics.append(
          EventSummaryMetric(
            name: "cost-usd", group: group, value: tally.usd, unit: .usd, n: tally.costed))
      }
      metrics.append(
        EventSummaryMetric(
          name: "calls", group: group, value: Double(tally.calls), unit: .count, n: tally.calls))
      if without > 0 {
        metrics.append(
          EventSummaryMetric(
            name: "calls-without-cost", group: group, value: Double(without), unit: .count,
            n: tally.calls))
      }
    }
  }

  /// `<label>: $<usd> (n=<priced>)[; unpriced: <n> messages]; tokens … (n=<messages>)`, with no
  /// dollar figure when nothing in the group was priced.
  private static func line(_ label: String, _ tally: Tally) -> String {
    var parts: [String] = []
    if tally.priced > 0 { parts.append("\(money(tally.usd)) (n=\(tally.priced))") }
    if tally.unpriced > 0 { parts.append("unpriced: \(tally.unpriced) messages") }
    parts.append("\(tally.tokens.rendered) (n=\(tally.messages))")
    return "\(label): " + parts.joined(separator: "; ")
  }

  private static func metrics(_ tally: Tally, group: [String]) -> [EventSummaryMetric] {
    var metrics: [EventSummaryMetric] = []
    if tally.priced > 0 {
      metrics.append(
        EventSummaryMetric(
          name: "cost-usd", group: group, value: tally.usd, unit: .usd, n: tally.priced))
    }
    metrics.append(
      EventSummaryMetric(
        name: "messages", group: group, value: Double(tally.messages), unit: .count,
        n: tally.messages))
    if tally.unpriced > 0 {
      metrics.append(
        EventSummaryMetric(
          name: "unpriced-messages", group: group, value: Double(tally.unpriced), unit: .count,
          n: tally.messages))
    }
    return metrics + tally.tokens.metrics(prefix: "", group: group, n: tally.messages)
  }

  static func money(_ usd: Double) -> String { String(format: "$%.4f", usd) }

  private static func percent(_ share: Double) -> String { String(format: "%.1f%%", share * 100) }

  /// The part of the priced cost that went to cache reads and to fresh input. Only messages
  /// priced at this table's version are split: an older table's rates may not be the ones that
  /// gave their cost.
  private func shares(
    _ usages: [AgentUsageEvent], lines: inout [String], metrics: inout [EventSummaryMetric]
  ) {
    var total = 0.0
    var read = 0.0
    var fresh = 0.0
    var n = 0
    for usage in usages where usage.priceTable == prices.version {
      guard let cost = usage.costUSD, let rates = prices.usdPerMillion[usage.model] else {
        continue
      }
      func usd(_ tokens: Int, _ rate: Decimal?) -> Double? {
        if tokens == 0 { return 0 }
        guard let rate else { return nil }
        return Double(tokens) * NSDecimalNumber(decimal: rate).doubleValue / 1_000_000
      }
      guard let readUSD = usd(usage.cacheReadTokens, rates[.cacheRead]),
        let freshUSD = usd(usage.inputTokens, rates[.input])
      else { continue }
      total += cost
      read += readUSD
      fresh += freshUSD
      n += 1
    }
    guard n > 0, total > 0 else {
      lines.append("cache-read share: no message priced at table \(prices.version)")
      return
    }
    metrics += [
      EventSummaryMetric(
        name: "cache-read-share", group: ["total"], value: read / total, unit: .share, n: n),
      EventSummaryMetric(
        name: "fresh-input-share", group: ["total"], value: fresh / total, unit: .share, n: n),
    ]
    lines.append(
      "cache reads \(Self.percent(read / total)) of priced cost, fresh input "
        + "\(Self.percent(fresh / total)) (n=\(n), table \(prices.version))")
  }

  private func phases(
    _ usages: [AgentUsageEvent], files: any EventStoreFileReading, lines: inout [String],
    metrics: inout [EventSummaryMetric]
  ) {
    let read = PhaseWindows.read(files)
    lines += read.damage.map { "damage: \($0)" }
    guard !read.windows.isEmpty else { return }
    var tallies: [Int: Tally] = [:]
    var outside = 0
    for usage in usages {
      guard let index = PhaseWindows.window(at: usage.messageTime, in: read.windows) else {
        outside += 1
        continue
      }
      tallies[index, default: Tally()].add(usage)
    }
    lines.append(
      "phases run back to back from each run id's start; time between phases isn't recorded")
    for index in tallies.keys.sorted() {
      guard let tally = tallies[index] else { continue }
      let window = read.windows[index]
      let group = ["phase", window.runID, window.phase.rawValue]
      lines.append(Self.line(group.joined(separator: " "), tally))
      metrics += Self.metrics(tally, group: group)
    }
    lines.append("outside every phase window: \(outside) messages (n=\(usages.count))")
    metrics.append(
      EventSummaryMetric(
        name: "outside-phase-windows", group: ["phase"], value: Double(outside), unit: .count,
        n: usages.count))
  }
}

/// When each design and plan phase ran, from the `phases.jsonl` of every design run. A line
/// carries no time, so a run's phases are laid back to back from the start its run id names.
enum PhaseWindows {
  struct Window: Equatable {
    let runID: String
    let phase: DesignPlanPhase
    /// Inclusive.
    let start: Date
    /// Exclusive, so a message on a boundary belongs to the later phase only.
    let end: Date
  }

  static func read(_ files: any EventStoreFileReading) -> (windows: [Window], damage: [String]) {
    var windows: [Window] = []
    var damage: [String] = []
    let runs: [String]
    do {
      runs = try files.list(RunLayout.runsDirectory).filter { $0.hasPrefix("design-") }
    } catch {
      return ([], ["\(error)"])
    }
    for run in runs {
      let path = "\(RunLayout.runsDirectory)/\(run)/phases.jsonl"
      let data: Data
      do {
        guard let read = try files.read(path) else { continue }
        data = read
      } catch {
        damage.append("\(error)")
        continue
      }
      var cursor: [String: Date] = [:]
      let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
      for (index, line) in lines.enumerated() where !line.isEmpty {
        let location = "\(path) line \(index + 1)"
        guard let record = try? JSONDecoder().decode(PhaseRecord.self, from: Data(line)) else {
          damage.append("\(location): not a phases record")
          continue
        }
        guard let start = cursor[record.runId] ?? runStart(record.runId) else {
          damage.append("\(location): run id names no start time")
          continue
        }
        let end = start.addingTimeInterval(Double(record.wallMilliseconds) / 1000)
        cursor[record.runId] = end
        windows.append(Window(runID: record.runId, phase: record.phase, start: start, end: end))
      }
    }
    return (windows, damage)
  }

  /// The window holding `time`; where windows overlap, the one that started last.
  static func window(at time: Date, in windows: [Window]) -> Int? {
    windows.indices.filter { windows[$0].start <= time && time < windows[$0].end }
      .max { windows[$0].start < windows[$1].start }
  }

  /// `<kind>-yyyyMMddTHHmmssZ` to its UTC time.
  static func runStart(_ runID: String) -> Date? {
    guard let dash = runID.firstIndex(of: "-") else { return nil }
    let stamp = Array(runID[runID.index(after: dash)...].utf8)
    guard stamp.count == 16, stamp[8] == UInt8(ascii: "T"), stamp[15] == UInt8(ascii: "Z")
    else { return nil }
    func number(_ range: Range<Int>) -> Int? {
      Int(String(decoding: stamp[range], as: UTF8.self))
    }
    guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
      let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15),
      (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
      (0...59).contains(minute), (0...59).contains(second),
      let utc = TimeZone(identifier: "UTC")
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar.date(
      from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second))
  }
}
