import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// A ``Rate`` shaped for `--json`: the raw counts plus the derived value (`null` when the
/// denominator is zero), so a reader never has to recompute "n/a" from a bare percentage.
struct RateJSON: Sendable, Equatable, Encodable {
  let numerator: Int
  let denominator: Int
  let value: Double?

  init(_ rate: Rate) {
    numerator = rate.numerator
    denominator = rate.denominator
    value = rate.value
  }
}

/// `swiftgate stats --design <doc>`'s report: every §10/§12 metric for one design, plus notes
/// naming every optional input that was missing rather than silently treated as zero.
struct DesignStatsReport: Sendable, Equatable, Encodable {
  struct LaneRow: Sendable, Equatable, Encodable {
    let lane: ResearchLane
    let total: Int
    let refuteRate: RateJSON
    let unverifiedRate: RateJSON

    init(_ metrics: LaneClaimMetrics) {
      lane = metrics.lane
      total = metrics.total
      refuteRate = RateJSON(metrics.refuteRate)
      unverifiedRate = RateJSON(metrics.unverifiedRate)
    }
  }

  struct ReviewerRow: Sendable, Equatable, Encodable {
    let reviewer: String
    let accepted: Int
    let dismissed: Int
    let precision: RateJSON

    init(_ precision: ReviewerPrecision) {
      reviewer = precision.reviewer
      accepted = precision.accepted
      dismissed = precision.dismissed
      self.precision = RateJSON(precision.precision)
    }
  }

  struct PhaseRow: Sendable, Equatable, Encodable {
    let phase: DesignPlanPhase
    let runs: Int
    let tokens: Int
    let costUSD: Double?
    let wallMilliseconds: Int

    init(_ totals: PhaseGroupTotals<DesignPlanPhase>) {
      phase = totals.key
      runs = totals.runs
      tokens = totals.tokens
      costUSD = totals.costUSD
      wallMilliseconds = totals.wallMilliseconds
    }
  }

  struct AgentRow: Sendable, Equatable, Encodable {
    let agentRole: ContextPackRole
    let runs: Int
    let tokens: Int
    let costUSD: Double?
    let wallMilliseconds: Int

    init(_ totals: PhaseGroupTotals<ContextPackRole>) {
      agentRole = totals.key
      runs = totals.runs
      tokens = totals.tokens
      costUSD = totals.costUSD
      wallMilliseconds = totals.wallMilliseconds
    }
  }

  struct EstimateErrorRow: Sendable, Equatable, Encodable {
    struct Task: Sendable, Equatable, Encodable {
      let id: String
      let estLines: Int
      let actualLines: Int
      let error: Int
    }

    let perTask: [Task]
    let excludedTaskIDs: [String]
    let meanAbsoluteError: Double?

    init(_ report: EstimateErrorReport) {
      perTask = report.perTask.map {
        Task(id: $0.id, estLines: $0.estLines, actualLines: $0.actualLines, error: $0.error)
      }
      excludedTaskIDs = report.excludedTaskIDs
      meanAbsoluteError = report.meanAbsoluteError
    }

    static let empty = EstimateErrorRow(
      EstimateErrorReport.init(perTask:excludedTaskIDs:meanAbsoluteError:)([], [], nil))
  }

  struct ProbeRow: Sendable, Equatable, Encodable {
    let total: Int
    let failed: Int
    let failRate: RateJSON

    init(_ report: ProbeFailReport) {
      total = report.total
      failed = report.failed
      failRate = RateJSON(report.failRate)
    }
  }

  struct CacheRow: Sendable, Equatable, Encodable {
    let entries: Int
    let reuses: Int
    let hitRate: RateJSON

    init(_ report: CacheHitReport) {
      entries = report.entries
      reuses = report.reuses
      hitRate = RateJSON(report.hitRate)
    }
  }

  let command = "stats"
  let verdict: Verdict
  let design: String
  let plan: String?
  let claimLanes: [LaneRow]
  let unknownLaneClaimCounts: [String: Int]
  let escapeRate: RateJSON
  let reviewerPrecision: [ReviewerRow]
  let phaseTotals: [PhaseRow]
  let agentTotals: [AgentRow]
  let nonDraftWallShare: RateJSON
  /// Spec §9.3's overhead share from the `--plan` ledger; `nil` without a plan or a schedule.
  let overheadShare: Double?
  let estimateError: EstimateErrorRow
  let probes: ProbeRow
  let cache: CacheRow
  let notes: [String]
  let message: String
}

/// The deterministic body of `stats --design`: every input is optional except the design doc
/// itself, and a missing one becomes a named note (never a silent zero) while a malformed one
/// blocks the whole report (spec: "a malformed file is exit 2 naming file:line"). Factored out of
/// the `ParsableCommand` so it's testable without argument parsing (matches
/// `EvidenceFindRun`/`EvidenceCheckRun`).
enum DesignStatsRun {
  struct Options: Sendable, Equatable {
    var design: String
    var plan: String?
    var cacheHome: String?
  }

  static func run(options: Options, root: URL, runner: any ProcessRunner) async -> DesignStatsReport
  {
    guard PlanFile.isValidDesignPath(options.design) else {
      return blocked(
        options: options,
        "--design `\(options.design)` must be a repo-relative docs/**/designs/<name>.md path")
    }
    var notes: [String] = []
    let layout = EvidenceLayout(designDocPath: options.design)

    let claimsLoaded = loadClaims(root: root, layout: layout)
    if let malformed = claimsLoaded.malformed { return blocked(options: options, malformed) }
    if let note = claimsLoaded.note { notes.append(note) }

    let amendmentsLoaded = loadJSONL(
      Amendment.self, root: root, path: layout.amendmentsFile, dateDecoding: .iso8601,
      missingNote: "no amendments file at \(layout.amendmentsFile); escape rate assumes none")
    if let malformed = amendmentsLoaded.malformed { return blocked(options: options, malformed) }
    if let note = amendmentsLoaded.note { notes.append(note) }

    let reviewLogPath = layout.root + "/review-log.jsonl"
    let reviewLogLoaded = loadJSONL(
      ReviewLogRecord.self, root: root, path: reviewLogPath,
      missingNote: "no review-log file at \(reviewLogPath); reviewer precision excluded")
    if let malformed = reviewLogLoaded.malformed { return blocked(options: options, malformed) }
    if let note = reviewLogLoaded.note { notes.append(note) }

    let slug = URL(filePath: options.design).deletingPathExtension().lastPathComponent
    let phasesPath = RunLayout.runDirectory(for: "design-\(slug)") + "phases.jsonl"
    let phasesLoaded = loadJSONL(
      PhaseRecord.self, root: root, path: phasesPath,
      missingNote:
        "no phases file at \(phasesPath); token/cost/wall and non-draft wall share excluded")
    if let malformed = phasesLoaded.malformed { return blocked(options: options, malformed) }
    if let note = phasesLoaded.note { notes.append(note) }

    let probesLoaded = loadProbes(root: root, layout: layout)
    if let malformed = probesLoaded.malformed { return blocked(options: options, malformed) }
    if let note = probesLoaded.note { notes.append(note) }

    let tasksLoaded = await loadTaskEstimates(plan: options.plan, root: root, runner: runner)
    if let malformed = tasksLoaded.malformed { return blocked(options: options, malformed) }
    if let note = tasksLoaded.note { notes.append(note) }

    let cacheLoaded = loadCache(cacheHome: options.cacheHome)
    notes += cacheLoaded.notes

    let laneReport = DesignMetrics.laneReport(claimsLoaded.claims)
    let escapeReport = DesignMetrics.escapeRate(
      claims: claimsLoaded.claims, amendments: amendmentsLoaded.records)
    let reviewerRows = DesignMetrics.reviewerPrecision(reviewLogLoaded.records)
    let phaseTotals = DesignMetrics.totalsByPhase(phasesLoaded.records)
    let agentTotals = DesignMetrics.totalsByAgent(phasesLoaded.records)
    let nonDraftWall = DesignMetrics.nonDraftWallShare(phasesLoaded.records)
    let overhead = overheadShare(ledger: tasksLoaded.ledger)
    if let note = overhead.note { notes.append(note) }
    let estimateErrorReport = DesignMetrics.estimateError(tasksLoaded.tasks)
    let probeReport = DesignMetrics.probeFailRate(probesLoaded.records)
    let cacheReport = DesignMetrics.cacheHitRate(
      claims: cacheLoaded.claims, verdicts: cacheLoaded.verdicts)

    for (lane, count) in laneReport.unknownLaneClaimCounts.sorted(by: { $0.key < $1.key }) {
      notes.append("\(count) claim(s) name an unrecognised lane `\(lane)`")
    }

    return DesignStatsReport(
      verdict: .green, design: options.design, plan: options.plan,
      claimLanes: laneReport.lanes.map(DesignStatsReport.LaneRow.init),
      unknownLaneClaimCounts: laneReport.unknownLaneClaimCounts,
      escapeRate: RateJSON(escapeReport.rate),
      reviewerPrecision: reviewerRows.map(DesignStatsReport.ReviewerRow.init),
      phaseTotals: phaseTotals.map(DesignStatsReport.PhaseRow.init),
      agentTotals: agentTotals.map(DesignStatsReport.AgentRow.init),
      nonDraftWallShare: RateJSON(nonDraftWall), overheadShare: overhead.share,
      estimateError: DesignStatsReport.EstimateErrorRow(estimateErrorReport),
      probes: DesignStatsReport.ProbeRow(probeReport),
      cache: DesignStatsReport.CacheRow(cacheReport),
      notes: notes,
      message:
        "\(claimsLoaded.claims.count) claim(s), \(phasesLoaded.records.count) phase record(s)")
  }

  static func render(_ report: DesignStatsReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
    case .human:
      guard report.verdict == .green else {
        return "stats \(Verdict.blocked.rawValue) \(report.message)"
      }
      var lines = ["stats --design \(report.design): \(report.message)"]
      lines.append("lanes:")
      for lane in report.claimLanes {
        lines.append(
          "  \(lane.lane.rawValue): total=\(lane.total) refute=\(percent(lane.refuteRate)) "
            + "unverified=\(percent(lane.unverifiedRate))")
      }
      lines.append("escape rate: \(percent(report.escapeRate))")
      lines.append("reviewer precision:")
      for reviewer in report.reviewerPrecision {
        lines.append("  \(reviewer.reviewer): \(percent(reviewer.precision))")
      }
      lines.append("phases:")
      for phase in report.phaseTotals {
        lines.append(
          "  \(phase.phase.rawValue): runs=\(phase.runs) tokens=\(phase.tokens) "
            + "cost=\(cost(phase.costUSD)) wall=\(ReportRenderer.duration(phase.wallMilliseconds))")
      }
      lines.append("agents:")
      for agent in report.agentTotals {
        lines.append(
          "  \(agent.agentRole.rawValue): runs=\(agent.runs) tokens=\(agent.tokens) "
            + "cost=\(cost(agent.costUSD)) wall=\(ReportRenderer.duration(agent.wallMilliseconds))")
      }
      lines.append(
        "overhead share: "
          + (report.overheadShare.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"))
      lines.append("non-draft wall share: \(percent(report.nonDraftWallShare))")
      let mae = report.estimateError.meanAbsoluteError.map { String(format: "%.1f", $0) } ?? "n/a"
      lines.append(
        "estimate error: mean |error|=\(mae) lines over \(report.estimateError.perTask.count) "
          + "task(s); excluded=\(report.estimateError.excludedTaskIDs.count)")
      lines.append(
        "probes: \(report.probes.failed)/\(report.probes.total) failed "
          + "(\(percent(report.probes.failRate)))")
      lines.append("cache hit rate: \(percent(report.cache.hitRate))")
      for note in report.notes { lines.append("  note: \(note)") }
      return lines.joined(separator: "\n")
    }
  }

  private static func percent(_ rate: RateJSON) -> String {
    guard let value = rate.value else { return "n/a" }
    return String(format: "%.1f%% (%d/%d)", value * 100, rate.numerator, rate.denominator)
  }

  private static func cost(_ costUSD: Double?) -> String {
    costUSD.map { String(format: "$%.2f", $0) } ?? "n/a"
  }

  private static func blocked(options: Options, _ message: String) -> DesignStatsReport {
    let zero = RateJSON(Rate(numerator: 0, denominator: 0))
    return DesignStatsReport(
      verdict: .blocked, design: options.design, plan: options.plan, claimLanes: [],
      unknownLaneClaimCounts: [:], escapeRate: zero, reviewerPrecision: [], phaseTotals: [],
      agentTotals: [], nonDraftWallShare: zero, overheadShare: nil, estimateError: .empty,
      probes: DesignStatsReport.ProbeRow(
        ProbeFailReport(total: 0, failed: 0, failRate: Rate(numerator: 0, denominator: 0))),
      cache: DesignStatsReport.CacheRow(
        CacheHitReport(entries: 0, reuses: 0, hitRate: Rate(numerator: 0, denominator: 0))),
      notes: [], message: message)
  }

  // MARK: - Loaders

  private static func loadClaims(root: URL, layout: EvidenceLayout)
    -> (claims: [Claim], note: String?, malformed: String?)
  {
    do {
      return (try EvidenceFiles.claims(root: root, layout: layout), nil, nil)
    } catch {
      switch error {
      case .claimsFileMissing(let path):
        return ([], "no claims file at \(path); lane and escape-rate metrics excluded", nil)
      case .claimsFileUnreadable(let path, let detail):
        return ([], "can't read \(path): \(detail)", nil)
      case .malformedClaimLine(let path, let line):
        return ([], nil, "\(path):\(line): not a valid claim record")
      case .refNotFound, .git:
        return ([], nil, "unexpected error reading claims: \(error)")
      }
    }
  }

  private static func loadJSONL<T: Decodable>(
    _ type: T.Type, root: URL, path: String,
    dateDecoding: JSONDecoder.DateDecodingStrategy = .deferredToDate, missingNote: String
  ) -> (records: [T], note: String?, malformed: String?) {
    guard let data = FileManager.default.contents(atPath: root.appending(path: path).path) else {
      return ([], missingNote, nil)
    }
    do {
      return (
        try StrictJSONL.decode(type, data: data, path: path, dateDecoding: dateDecoding), nil, nil
      )
    } catch {
      return ([], nil, "\(error.path):\(error.line): not a valid record")
    }
  }

  private static func loadProbes(root: URL, layout: EvidenceLayout)
    -> (records: [ProbeVerdictRecord], note: String?, malformed: String?)
  {
    let directory = root.appending(path: layout.probesDirectory)
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
      return ([], "no probes directory at \(layout.probesDirectory); probe fail rate excluded", nil)
    }
    var records: [ProbeVerdictRecord] = []
    for name in names.sorted() where name.hasSuffix(".verdict.json") {
      let path = layout.probesDirectory + "/" + name
      guard let data = FileManager.default.contents(atPath: root.appending(path: path).path)
      else { continue }
      guard let record = try? JSONDecoder().decode(ProbeVerdictRecord.self, from: data) else {
        return ([], nil, "\(path):1: not a valid probe verdict record")
      }
      records.append(record)
    }
    return (records, nil, nil)
  }

  /// Spec §9.3's overhead share, the figure the ledger page shows: the ledger's recomputed
  /// schedule against its critical path.
  private static func overheadShare(ledger: Ledger?) -> (share: Double?, note: String?) {
    guard let ledger else { return (nil, "no ledger; overhead share excluded") }
    switch PlanSchedule.schedule(tasks: ledger.tasks, maxParallel: ledger.maxParallel) {
    case .failure(let error):
      return (nil, "overhead share excluded: \(LedgerRender.describe(error))")
    case .success(let waves):
      let share = LedgerRender.predictedOverheadShare(tasks: ledger.tasks, waves: waves)
      return (share, share == nil ? "overhead share is n/a: no estimated task lines" : nil)
    }
  }

  private static func loadTaskEstimates(plan: String?, root: URL, runner: any ProcessRunner) async
    -> (tasks: [TaskEstimate], ledger: Ledger?, note: String?, malformed: String?)
  {
    guard let plan else {
      return ([], nil, "no --plan given; estimate error excluded", nil)
    }
    let git = LiveGit(runner: runner, repositoryRoot: root.path)
    do {
      let store = try await PlanStateStore.locate(slug: plan, git: git)
      let ledger = try store.ledger()
      let tasks = ledger.tasks.map {
        TaskEstimate(id: $0.id, estLines: $0.estLines, actualLines: $0.actualLines)
      }
      let missingActuals = tasks.count { $0.actualLines == nil }
      let note =
        missingActuals == 0
        ? nil
        : "\(missingActuals) task(s) have no actualLines yet; excluded from estimate error"
      return (tasks, ledger, note, nil)
    } catch {
      if case .missing(let path) = error {
        return ([], nil, "no ledger yet at \(path); estimate error excluded", nil)
      }
      return ([], nil, nil, "plan `\(plan)`: \(error)")
    }
  }

  private static func loadCache(cacheHome: String?)
    -> (claims: [CachedClaim], verdicts: [CachedVerdict], notes: [String])
  {
    guard let home = cacheHome ?? ProcessInfo.processInfo.environment["HOME"] else {
      return (
        [], [],
        [
          "missing required option '--cache-home <path>' ($HOME is not set); cache hit rate excluded"
        ]
      )
    }
    let layout = EvidenceCacheLayout(home: home)
    guard FileManager.default.fileExists(atPath: layout.root) else {
      return ([], [], ["no evidence cache at \(layout.root); cache hit rate excluded"])
    }
    let store = EvidenceCacheStore(home: URL(filePath: home, directoryHint: .isDirectory))
    var claims: [CachedClaim] = []
    var verdicts: [CachedVerdict] = []
    var notes: [String] = []
    for bucket in cacheBuckets(root: layout.root) + [.verdicts] {
      let contents: EvidenceCacheContents
      do {
        contents = try store.contents(of: bucket)
      } catch {
        notes.append("evidence cache: can't read \(bucket): \(error)")
        continue
      }
      notes += contents.findings.map { "evidence cache: \($0.message)" }
      claims += contents.claims
      verdicts += Array(contents.verdicts.values)
    }
    return (claims, verdicts, notes)
  }

  /// Every bucket file that currently exists under the cache root (matches
  /// `EvidenceFindRun.cacheBuckets`): package pins at the top level, SDK pins under `sdk/`.
  private static func cacheBuckets(root: String) -> [EvidenceCacheBucket] {
    let fm = FileManager.default
    var buckets: [EvidenceCacheBucket] = []
    for name in (try? fm.contentsOfDirectory(atPath: root)) ?? []
    where name.hasSuffix(".jsonl") && name.contains("@") {
      buckets.append(.package(pin: String(name.dropLast(".jsonl".count))))
    }
    for name in (try? fm.contentsOfDirectory(atPath: root + "/sdk")) ?? []
    where name.hasSuffix(".jsonl") {
      buckets.append(.sdk(pin: String(name.dropLast(".jsonl".count))))
    }
    return buckets
  }
}

/// `swiftgate stats --build <run>`'s report: every ``BuildMetrics/Report`` field, JSON-stable and
/// with a fixed `command`, so a reader never has to special-case the run-not-found shape.
struct BuildStatsReport: Sendable, Equatable, Encodable {
  struct TaskRow: Sendable, Equatable, Encodable {
    let task: String
    let status: TaskStatus
    let startedAt: Date
    let endedAt: Date
    let wallMilliseconds: Int

    init(_ duration: BuildMetrics.TaskDuration) {
      task = duration.task
      status = duration.endStatus
      startedAt = duration.startedAt
      endedAt = duration.endedAt
      wallMilliseconds = duration.wallMilliseconds
    }
  }

  struct MergeRow: Sendable, Equatable, Encodable {
    let task: String
    let at: Date
    let preCommit: String
    let postCommit: String

    init(_ merge: BuildMetrics.MergeRecord) {
      task = merge.task
      at = merge.at
      preCommit = merge.preCommit
      postCommit = merge.postCommit
    }
  }

  /// `events.jsonl` damage, JSON-shaped: `undecodable-line`'s `reason` is `nil` for
  /// `torn-last-line`, never an empty string standing in for "none".
  struct DamageRow: Sendable, Equatable, Encodable {
    let kind: String
    let line: Int
    let reason: String?

    init(_ damage: BuildEventLog.Damage) {
      switch damage {
      case .tornLastLine(let line):
        kind = "torn-last-line"
        self.line = line
        reason = nil
      case .undecodableLine(let line, let why):
        kind = "undecodable-line"
        self.line = line
        reason = why
      }
    }
  }

  let command = "stats"
  let verdict: Verdict
  let plan: String
  let runId: String
  let presetName: String?
  let budgetMinutes: Int?
  let overBudget: Bool
  let totalWallMilliseconds: Int?
  let tasks: [TaskRow]
  let mergeCount: Int
  let merges: [MergeRow]
  let damage: [DamageRow]
  let message: String
}

/// The deterministic body of `stats --build`: opens the named run through ``BuildRunStore``
/// (never parses `run.json`/`events.jsonl` itself), computes ``BuildMetrics``, and shapes the
/// result for either output format. A damaged log still yields a report — the damage is a field on
/// it, not a reason to withhold the rest.
enum BuildStatsRun {
  struct Options: Sendable, Equatable {
    var runID: String
    var plan: String
  }

  static func run(options: Options, git: any Git) async -> BuildStatsReport {
    let store: BuildRunStore
    do {
      store = try await BuildRunStore.open(plan: options.plan, runID: options.runID, git: git)
    } catch {
      return blocked(options: options, "can't open run `\(options.runID)`: \(error)")
    }
    let record: BuildRunRecord
    do {
      record = try store.record()
    } catch {
      return blocked(options: options, "can't read run.json for `\(options.runID)`: \(error)")
    }
    let log: BuildEventLog
    do {
      log = try store.events()
    } catch {
      return blocked(options: options, "can't read events.jsonl for `\(options.runID)`: \(error)")
    }
    let metrics = BuildMetrics.compute(record: record, log: log)
    let damage = metrics.damage.map(BuildStatsReport.DamageRow.init)
    let message =
      damage.isEmpty
      ? "\(metrics.taskDurations.count) task(s) timed, \(metrics.merges.count) merge(s)"
      : "\(metrics.taskDurations.count) task(s) timed, \(metrics.merges.count) merge(s); "
        + "\(damage.count) damaged line(s) in events.jsonl"
    return BuildStatsReport(
      verdict: .green, plan: options.plan, runId: options.runID, presetName: record.presetName,
      budgetMinutes: metrics.budgetMinutes, overBudget: metrics.overBudget,
      totalWallMilliseconds: metrics.totalWallMilliseconds,
      tasks: metrics.taskDurations.map(BuildStatsReport.TaskRow.init),
      mergeCount: metrics.merges.count, merges: metrics.merges.map(BuildStatsReport.MergeRow.init),
      damage: damage, message: message)
  }

  static func render(_ report: BuildStatsReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      encoder.dateEncodingStrategy = .iso8601
      return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
    case .human:
      guard report.verdict == .green else {
        return "stats \(Verdict.blocked.rawValue) \(report.message)"
      }
      var lines = [
        "stats --build \(report.runId) (plan \(report.plan)"
          + (report.presetName.map { ", preset \($0)" } ?? "") + ")"
      ]
      let budget = report.budgetMinutes.map { $0 == 0 ? "none" : "\($0)m" } ?? "none"
      let total = report.totalWallMilliseconds.map(ReportRenderer.duration) ?? "n/a"
      lines.append(
        "budget: \(budget)  total: \(total)"
          + (report.overBudget ? "  OVER BUDGET" : ""))
      lines.append("tasks:")
      if report.tasks.isEmpty {
        lines.append("  (none timed yet)")
      }
      for task in report.tasks {
        lines.append(
          "  \(task.task): \(task.status.rawValue) \(ReportRenderer.duration(task.wallMilliseconds))"
        )
      }
      lines.append("merges: \(report.mergeCount)")
      for merge in report.merges {
        lines.append("  \(merge.task) at \(ISO8601DateFormatter().string(from: merge.at))")
      }
      for damage in report.damage {
        lines.append(
          "  damaged line \(damage.line): \(damage.kind)"
            + (damage.reason.map { " (\($0))" } ?? ""))
      }
      return lines.joined(separator: "\n")
    }
  }

  private static func blocked(options: Options, _ message: String) -> BuildStatsReport {
    BuildStatsReport(
      verdict: .blocked, plan: options.plan, runId: options.runID, presetName: nil,
      budgetMinutes: nil, overBudget: false, totalWallMilliseconds: nil, tasks: [], mergeCount: 0,
      merges: [], damage: [], message: message)
  }
}

enum StatsRenderer {
  static func human(_ rows: [TierStats], invalidLines: Int) -> String {
    guard !rows.isEmpty else {
      return "no runs recorded in \(RunLayout.historyFile)" + unreadable(invalidLines)
    }
    let header = ["command", "tier", "runs", "p50", "p95", "budget", "verdicts"]
    let body = rows.map { row -> [String] in
      let verdicts = Verdict.allCases.compactMap { verdict in
        row.verdicts[verdict].map { "\($0) \(verdict.rawValue)" }
      }
      return [
        row.command, row.tier.rawValue, "\(row.runs)",
        ReportRenderer.duration(row.p50Milliseconds),
        ReportRenderer.duration(row.p95Milliseconds) + (row.overBudget ? " OVER" : ""),
        row.budgetMilliseconds.map(ReportRenderer.duration) ?? "-",
        verdicts.joined(separator: ", "),
      ]
    }
    let table = [header] + body
    let widths = header.indices.map { column in table.map { $0[column].count }.max() ?? 0 }
    let lines = table.map { cells in
      zip(cells, widths).map { cell, width in
        cell + String(repeating: " ", count: width - cell.count)
      }
      .joined(separator: "  ")
      .trimmingCharacters(in: .whitespaces)
    }
    return lines.joined(separator: "\n") + unreadable(invalidLines)
  }

  private static func unreadable(_ count: Int) -> String {
    count == 0 ? "" : "\n\(count) unreadable history line\(count == 1 ? "" : "s") skipped"
  }

  struct Row: Encodable {
    let command: String
    let tier: String
    let runs: Int
    let p50Milliseconds: Int
    let p95Milliseconds: Int
    let budgetMilliseconds: Int?
    let overBudget: Bool
    let verdicts: [String: Int]
  }

  static func json(_ rows: [TierStats]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let encoded = rows.map {
      Row(
        command: $0.command, tier: $0.tier.rawValue, runs: $0.runs,
        p50Milliseconds: $0.p50Milliseconds, p95Milliseconds: $0.p95Milliseconds,
        budgetMilliseconds: $0.budgetMilliseconds, overBudget: $0.overBudget,
        verdicts: Dictionary(uniqueKeysWithValues: $0.verdicts.map { ($0.key.rawValue, $0.value) }))
    }
    return String(decoding: try encoder.encode(encoded), as: UTF8.self)
  }
}

struct StatsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "stats",
    abstract: "Per-command, per-tier duration p50/p95 against budgets, from run history.",
    discussion:
      "Without --design or --build: per-command, per-tier duration p50/p95 against budgets, from "
      + "run history. With --design <doc>: §10/§12 design and plan metrics (lane "
      + "refute/UNVERIFIED rates, escape rate, reviewer precision, tokens/cost/wall per agent and "
      + "phase, estimate error, probe fail rate, cache hit rate) for that design. With --build "
      + "<run-id> --plan <slug>: §13 wall time per task and merge for that build run, against the "
      + "run's preset budget. Exit 0 always, except 2 for a malformed --design, --plan, --build or "
      + "evidence input.")

  @Option(help: "Report §10/§12 metrics for this design doc instead of gate-run history stats.")
  var design: String?

  @Option(help: "Report §13 wall-time metrics for this build run id instead of other stats modes.")
  var build: String?

  @Option(
    help: ArgumentHelp(
      "The plan slug: required with --build (whose run store lives under it), and backs "
        + "estimate error with --design."))
  var plan: String?

  @Option(help: "The evidence reuse cache's home directory; defaults to $HOME (needs --design).")
  var cacheHome: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    if let design {
      let report = await DesignStatsRun.run(
        options: .init(design: design, plan: plan, cacheHome: cacheHome), root: root,
        runner: LiveProcessRunner())
      Console.write(DesignStatsRun.render(report, format: output.format))
      if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
      return
    }
    if let build {
      guard let plan else {
        Console.write("stats \(Verdict.blocked.rawValue) --build needs --plan <slug>")
        throw ExitCode(Verdict.blocked.exitCode)
      }
      let report = await BuildStatsRun.run(
        options: .init(runID: build, plan: plan), git: BuildLoop.git())
      Console.write(BuildStatsRun.render(report, format: output.format))
      if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
      return
    }
    let history = try RunStore(worktreeRoot: root).readHistory()
    // Budgets are optional context: without a readable config the table has no budget column.
    let budgets = (try? ConfigLoader().load(repositoryRoot: root))??.budgets
    let rows = RunStats.summarize(history.records, budgets: budgets)
    switch output.format {
    case .human: Console.write(StatsRenderer.human(rows, invalidLines: history.invalidLines))
    case .json: Console.write(try StatsRenderer.json(rows))
    }
  }
}
