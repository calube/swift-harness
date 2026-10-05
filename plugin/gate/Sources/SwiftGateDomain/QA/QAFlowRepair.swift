import Foundation

/// A flow row rewritten after its flow, not the app, kept it red: a step the pinned tool can't
/// drive as written, such as a `scroll` where a pull to refresh needs a `gesture` drag. A
/// validation worker in repair mode rewrites only that requirement's checks and proves them red at
/// the merge base again; `qa adopt --repair` takes them into plan state only when these rules
/// pass, so a repair can't weaken a check into one that passes whatever the app shows.
public enum QAFlowRepair {
  /// Plan state's record of every repair, beside the adopted checks in `qa/`.
  public static let fileName = "repairs.json"

  public static let capRuleID = "qa.repair-cap"
  public static let outsideRowRuleID = "qa.repair-outside-row"
  public static let weakensRuleID = "qa.repair-weakens-check"
  public static let unchangedRuleID = "qa.repair-unchanged"
  public static let notRedRuleID = "qa.repair-not-red"
  public static let wrongRedRuleID = "qa.repair-wrong-red"
  public static let redRunsRuleID = "qa.repair-red-runs"

  /// The repairs 1 requirement may take in 1 build run. The second is taken only while the run's
  /// box still starts new work, before its `noNewStartsAt`.
  public static let repairsPerRun = 2

  /// Why the orchestrator sent the row to repair.
  public enum Cause: String, Sendable, Equatable, Codable, CaseIterable {
    /// The fixer judged the failing step the flow's fault.
    case flowSide = "flow-side"
    /// The row stayed red after a fixer's change to the app.
    case stillRed = "still-red"
  }

  /// 1 `qa run` that read the row red before the repair, with the requirement's flow row as that
  /// run's report holds it; `nil` when the report doesn't read or holds no such row.
  public struct RedRun: Sendable, Equatable {
    public let runID: String
    public let row: QARow?

    public init(runID: String, row: QARow?) {
      self.runID = runID
      self.row = row
    }
  }

  /// Everything the rules read for 1 repair.
  public struct Input: Sendable, Equatable {
    public let requirement: String
    /// The requirement's rows in `validation.json`, with their 1-based row numbers.
    public let rows: [(row: Int, validation: ValidationRow)]
    /// Each row's check file as plan state holds it, by check (`qa/<name>`).
    public let adopted: [String: Data]
    /// Each check file the prepared folder holds, by check (`qa/<name>`).
    public let repaired: [String: Data]
    /// The names of every file directly in the prepared folder.
    public let preparedFiles: [String]
    /// Plan state's `at-base-run.json`; `nil` when it doesn't read.
    public let adoptedRecord: QAAtBaseRun?
    /// The prepared folder's `at-base-run.json`; `nil` when it doesn't read.
    public let preparedRecord: QAAtBaseRun?
    public let redRuns: [RedRun]
    public let earlier: [QAFlowRepairRecord]
    public let buildRun: String
    /// When the adopt runs; `nil` when it isn't known, which allows no second repair.
    public let now: Date?
    /// The build run's `noNewStartsAt`; `nil` for a run with no box, which allows no second
    /// repair.
    public let noNewStartsAt: Date?

    public init(
      requirement: String, rows: [(row: Int, validation: ValidationRow)], adopted: [String: Data],
      repaired: [String: Data], preparedFiles: [String], adoptedRecord: QAAtBaseRun?,
      preparedRecord: QAAtBaseRun?, redRuns: [RedRun], earlier: [QAFlowRepairRecord],
      buildRun: String, now: Date? = nil, noNewStartsAt: Date? = nil
    ) {
      self.requirement = requirement
      self.rows = rows
      self.adopted = adopted
      self.repaired = repaired
      self.preparedFiles = preparedFiles
      self.adoptedRecord = adoptedRecord
      self.preparedRecord = preparedRecord
      self.redRuns = redRuns
      self.earlier = earlier
      self.buildRun = buildRun
      self.now = now
      self.noNewStartsAt = noNewStartsAt
    }

    public static func == (lhs: Input, rhs: Input) -> Bool {
      lhs.requirement == rhs.requirement
        && lhs.rows.map(\.row) == rhs.rows.map(\.row)
        && lhs.rows.map(\.validation) == rhs.rows.map(\.validation)
        && lhs.adopted == rhs.adopted && lhs.repaired == rhs.repaired
        && lhs.preparedFiles == rhs.preparedFiles && lhs.adoptedRecord == rhs.adoptedRecord
        && lhs.preparedRecord == rhs.preparedRecord && lhs.redRuns == rhs.redRuns
        && lhs.earlier == rhs.earlier && lhs.buildRun == rhs.buildRun && lhs.now == rhs.now
        && lhs.noNewStartsAt == rhs.noNewStartsAt
    }
  }

  /// Each rule the repair breaks; empty when plan state may take it.
  public static func findings(_ input: Input) -> [Finding] {
    var findings: [Finding?] = []
    let requirement = input.requirement
    let file = "\(QAReport.directory)/\(requirement)"
    func add(_ rule: String, _ message: String) {
      findings.append(
        try? Finding(
          ruleID: rule, severity: .major, file: file, line: nil, message: message,
          failureScenario: nil))
    }
    let checks = input.rows.map(\.validation.check)

    if input.earlier.contains(where: {
      $0.requirement == requirement && $0.buildRun == input.buildRun
    }) {
      add(
        capRuleID,
        "\(requirement) was already repaired in build run \(input.buildRun); a row gets 1 "
          + "repair per run, so a row still red goes to the user")
    }

    let allowed = Set(checks.compactMap(preparedName) + [QAAtBaseRun.fileName])
    let outside = input.preparedFiles.filter { !allowed.contains($0) }.sorted()
    if !outside.isEmpty {
      add(
        outsideRowRuleID,
        "the prepared folder holds " + outside.joined(separator: ", ")
          + ", which no row of \(requirement) checks; a repair changes only its own row's files")
    }

    if input.redRuns.isEmpty {
      add(redRunsRuleID, "no qa run is named that read \(requirement) red before the repair")
    }
    for run in input.redRuns where run.row?.result != .red {
      add(
        redRunsRuleID,
        "qa run \(run.runID) "
          + (run.row.map { "read \(requirement) \($0.result.rawValue), not red" }
            ?? "holds no row of \(requirement) in a report that reads")
          + "; a repair answers a row that stayed red")
    }

    if !checks.isEmpty, checks.allSatisfy({ input.repaired[$0] == input.adopted[$0] }) {
      add(
        unchangedRuleID,
        "every check of \(requirement) is byte-identical to the adopted one, so nothing was "
          + "repaired")
    }

    for (number, row) in input.rows {
      let check = row.check
      guard let repaired = input.repaired[check] else {
        add(
          notRedRuleID,
          "row \(number)'s \(check) is missing from the prepared folder, so no red run of it "
            + "stands behind the repair")
        continue
      }
      let digest = QAAtBaseRun.digest(layer: row.layer, check: check, file: repaired)
      let recorded = input.preparedRecord?.rows.first {
        $0.requirement == requirement && $0.layer == row.layer && $0.check == check
      }
      guard let recorded else {
        add(
          notRedRuleID,
          "the prepared \(QAAtBaseRun.fileName) holds no run of row \(number)'s \(check); run "
            + "`qa run --at-base --prepared-by \(row.writer) --requirement \(requirement)` after "
            + "the last edit")
        continue
      }
      guard recorded.digest == digest else {
        add(
          notRedRuleID,
          "row \(number)'s \(check) changed after the prepared run "
            + "\(input.preparedRecord?.runID ?? "") proved it; run it again after the last edit")
        continue
      }
      guard recorded.result == .red else {
        add(
          notRedRuleID,
          "row \(number)'s \(check) read \(recorded.result.rawValue) at the merge base: "
            + "\(recorded.message); a repaired check must still fail there, or it can't tell the "
            + "change from its absence")
        continue
      }
      guard row.layer == .flow else { continue }
      flowRules(
        input, number: number, check: check, repaired: repaired, recorded: recorded, add: add)
    }
    return findings.compactMap { $0 }
  }

  /// The assertion and red-reason rules for 1 repaired flow row.
  private static func flowRules(
    _ input: Input, number: Int, check: String, repaired: Data, recorded: QAAtBaseRun.Row,
    add: (String, String) -> Void
  ) {
    let newSteps: [FlowStep]
    do {
      newSteps = try FlowSteps.parse(repaired)
    } catch {
      add(weakensRuleID, "row \(number)'s \(check) is no list of steps: \(error.reason)")
      return
    }
    let oldSteps = input.adopted[check].flatMap { try? FlowSteps.parse($0) } ?? []
    var remaining = newSteps[...]
    for old in oldSteps where FlowRules.asserts(old) {
      guard let at = remaining.firstIndex(where: { keeps(old, in: $0) }) else {
        add(
          weakensRuleID,
          "row \(number)'s \(check) no longer checks step \(old.number) of the adopted flow, "
            + "\(rendered(old)), in its place or later with at least its timeout; a repair keeps "
            + "every `wait` and `is` step")
        continue
      }
      remaining = newSteps[newSteps.index(after: at)...]
    }

    guard let failing = failingStep(in: recorded.message),
      failing.number >= 1, failing.number <= newSteps.count,
      newSteps[failing.number - 1].command == failing.command
    else {
      add(
        wrongRedRuleID,
        "row \(number)'s \(check) read red at the merge base without failing a step of the "
          + "repaired flow: \(recorded.message)")
      return
    }
    let step = newSteps[failing.number - 1]
    let adoptedFailing = input.adoptedRecord?.rows.first {
      $0.requirement == input.requirement && $0.layer == .flow && $0.check == check
    }.flatMap { failingStep(in: $0.message) }.flatMap { found in
      oldSteps.first { $0.number == found.number && $0.command == found.command }
    }
    let onAdoptedAssertion = oldSteps.contains { FlowRules.asserts($0) && keeps($0, in: step) }
    let onAdoptedFailure = adoptedFailing.map { keeps($0, in: step) } ?? false
    if !onAdoptedAssertion, !onAdoptedFailure {
      add(
        wrongRedRuleID,
        "row \(number)'s \(check) read red at the merge base on step \(step.number), "
          + "\(rendered(step)), which is neither a `wait` or `is` step of the adopted flow nor "
          + "the step it failed at there; the red must come from what the requirement checks")
    }
  }

  /// Whether `new` keeps what `old` checks: the same step, with a timeout no shorter.
  static func keeps(_ old: FlowStep, in new: FlowStep) -> Bool {
    guard old.command == new.command else { return false }
    var oldInput = old.input
    var newInput = new.input
    let oldTimeout = oldInput.removeValue(forKey: "timeoutMs")?.numeric
    let newTimeout = newInput.removeValue(forKey: "timeoutMs")?.numeric
    guard FlowJSON.object(oldInput).sameValue(as: .object(newInput)) else { return false }
    switch (oldTimeout, newTimeout) {
    case (nil, nil): return true
    case (let old?, let new?): return new >= old
    case (nil, _?), (_?, nil): return false
    }
  }

  private static func rendered(_ step: FlowStep) -> String {
    "`\(step.command)` \(FlowJSON.object(step.input).rendered)"
  }

  /// The name a `qa/<name>` check has in the prepared folder; `nil` for a check that names none.
  public static func preparedName(_ check: String) -> String? {
    let prefix = "\(QAReport.directory)/"
    guard check.hasPrefix(prefix) else { return nil }
    return String(check.dropFirst(prefix.count))
  }

  /// The step a red flow row's message names, as `step <n> \`<command>\` failed: …` writes it;
  /// `nil` for any other message.
  public static func failingStep(in message: String) -> (number: Int, command: String)? {
    guard message.hasPrefix("step ") else { return nil }
    let rest = message.dropFirst("step ".count)
    let digits = rest.prefix { $0.isNumber }
    guard let number = Int(digits) else { return nil }
    let afterNumber = rest.dropFirst(digits.count)
    guard afterNumber.hasPrefix(" `") else { return nil }
    let command = afterNumber.dropFirst(2).prefix { $0 != "`" }
    guard !command.isEmpty,
      afterNumber.dropFirst(2 + command.count).hasPrefix("` failed")
    else { return nil }
    return (number, String(command))
  }

  /// The commands of the steps the repair took out of the adopted flow and put in, by count, in
  /// the order each flow holds them.
  public static func changedCommands(adopted: Data, repaired: Data) -> (
    removed: [String], added: [String]
  ) {
    let old = (try? FlowSteps.parse(adopted)) ?? []
    let new = (try? FlowSteps.parse(repaired)) ?? []
    let difference = new.map(Kept.init).difference(from: old.map(Kept.init))
    var removed: [String] = []
    var added: [String] = []
    for change in difference {
      switch change {
      case .remove(_, let step, _): removed.append(step.command)
      case .insert(_, let step, _): added.append(step.command)
      }
    }
    return (removed, added)
  }

  /// A step compared by its whole JSON, for the difference of 2 flows.
  private struct Kept: Equatable {
    let command: String
    let fields: FlowJSON

    init(_ step: FlowStep) {
      command = step.command
      fields = .object(step.fields)
    }

    static func == (lhs: Kept, rhs: Kept) -> Bool { lhs.fields.sameValue(as: rhs.fields) }
  }
}

/// 1 repair plan state took.
public struct QAFlowRepairRecord: Sendable, Equatable, Codable {
  public let requirement: String
  /// The 1-based rows of `validation.json` whose checks it replaced.
  public let rows: [Int]
  public let checks: [String]
  /// The build run it counts against: 1 repair per requirement per build run.
  public let buildRun: String
  public let cause: QAFlowRepair.Cause
  /// The orchestrator's words for why the flow, not the app, was at fault.
  public let reason: String
  public let redRuns: [String]
  /// The prepared run that proved the repaired checks red at the merge base.
  public let atBaseRun: String
  /// The step the red runs failed at, and its command.
  public let failingStep: Int?
  public let failingCommand: String?
  public let removed: [String]
  public let added: [String]

  public init(
    requirement: String, rows: [Int], checks: [String], buildRun: String,
    cause: QAFlowRepair.Cause, reason: String, redRuns: [String], atBaseRun: String,
    failingStep: Int?, failingCommand: String?, removed: [String], added: [String]
  ) {
    self.requirement = requirement
    self.rows = rows
    self.checks = checks
    self.buildRun = buildRun
    self.cause = cause
    self.reason = reason
    self.redRuns = redRuns
    self.atBaseRun = atBaseRun
    self.failingStep = failingStep
    self.failingCommand = failingCommand
    self.removed = removed
    self.added = added
  }
}

/// `qa/repairs.json`: every repair plan state took, oldest first.
public struct QAFlowRepairs: Sendable, Equatable, Codable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let repairs: [QAFlowRepairRecord]

  public init(repairs: [QAFlowRepairRecord]) {
    self.schemaVersion = Self.currentSchemaVersion
    self.repairs = repairs
  }

  public static func decode(_ data: Data) throws -> QAFlowRepairs {
    let decoded = try JSONDecoder().decode(QAFlowRepairs.self, from: data)
    guard decoded.schemaVersion == currentSchemaVersion else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: [], debugDescription: "unsupported schemaVersion \(decoded.schemaVersion)"))
    }
    return decoded
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(self)
    data.append(UInt8(ascii: "\n"))
    return data
  }
}
