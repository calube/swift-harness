import Foundation

/// A ratio that is honest about having nothing to measure yet: `nil`, never a fabricated `0` or
/// `100%` (worker-brief pitfall: an optional means "not known", not a placeholder number).
public struct Rate: Sendable, Equatable {
  public let numerator: Int
  public let denominator: Int

  public init(numerator: Int, denominator: Int) {
    self.numerator = numerator
    self.denominator = denominator
  }

  /// `nil` when the denominator is zero — "n/a", not a real zero or a real 100%.
  public var value: Double? {
    denominator == 0 ? nil : Double(numerator) / Double(denominator)
  }
}

/// A line this build can't decode, named by file and 1-based line number rather than dropped.
public struct MalformedLine: Sendable, Equatable, Error {
  public let path: String
  public let line: Int

  public init(path: String, line: Int) {
    self.path = path
    self.line = line
  }
}

/// Strict JSONL decoding for the metrics inputs `stats` reads itself (spec §10/§12): unlike
/// `ClaimJSON`/`AmendmentJSON`, which count a torn line and carry on because other readers only
/// need the lines that did parse, a bad line here fails the whole file — a metrics report built
/// over a file it couldn't fully read would misstate every rate in it silently.
public enum StrictJSONL {
  public static func decode<T: Decodable>(
    _ type: T.Type, data: Data, path: String,
    dateDecoding: JSONDecoder.DateDecodingStrategy = .deferredToDate
  ) throws(MalformedLine) -> [T] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = dateDecoding
    var out: [T] = []
    for (index, line) in data.split(
      separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false
    ).enumerated() where !line.isEmpty {
      guard let value = try? decoder.decode(T.self, from: Data(line)) else {
        throw MalformedLine(path: path, line: index + 1)
      }
      out.append(value)
    }
    return out
  }
}

// MARK: - Research lanes

/// The closed set of research lanes a claim's `lane` field names (spec §7.1: codebase, Apple
/// docs, packages, prior decisions). Closed on purpose, per the worker-brief's "close types at
/// trust boundaries" pitfall: `claims.jsonl` is agent-written, so a lane this build doesn't
/// recognise is never folded into an existing bucket — it's counted apart and named instead
/// (``ClaimLaneReport/unknownLaneClaimCounts``).
public enum ResearchLane: String, Sendable, Equatable, CaseIterable, Codable {
  case codebase
  case appleDocs = "apple-docs"
  case packages
  case priorDecisions = "prior-decisions"
}

/// One lane's claim outcomes: how many claims it produced, and of those, how many the pipeline
/// refuted or never reached a supported/refuted verdict for (spec §12's badge model: a claim
/// renders as `supported`, `refuted`, or `UNVERIFIED` — anything short of the first two).
public struct LaneClaimMetrics: Sendable, Equatable {
  public let lane: ResearchLane
  public let total: Int
  public let refuteRate: Rate
  public let unverifiedRate: Rate

  public init(lane: ResearchLane, total: Int, refuteRate: Rate, unverifiedRate: Rate) {
    self.lane = lane
    self.total = total
    self.refuteRate = refuteRate
    self.unverifiedRate = unverifiedRate
  }
}

public struct ClaimLaneReport: Sendable, Equatable {
  public let lanes: [LaneClaimMetrics]
  /// Claims whose `lane` string matched no known ``ResearchLane``, keyed by that raw string —
  /// named rather than silently merged into a catch-all bucket.
  public let unknownLaneClaimCounts: [String: Int]

  public init(lanes: [LaneClaimMetrics], unknownLaneClaimCounts: [String: Int]) {
    self.lanes = lanes
    self.unknownLaneClaimCounts = unknownLaneClaimCounts
  }
}

// MARK: - Escape rate

/// A `supported` claim whose id a later `amend`-class amendment named in `changedIds` (spec
/// §12): the design trusted it, and an amendment record is the only proof "later" can mean here,
/// since claims carry no timestamp of their own. A `clarify` amendment disproves nothing (it
/// only removes ambiguity, §5.5), so it never counts a claim as escaped.
public struct EscapeRateReport: Sendable, Equatable {
  public let escapedClaimIDs: Set<String>
  public let supportedCount: Int
  public let rate: Rate

  public init(escapedClaimIDs: Set<String>, supportedCount: Int, rate: Rate) {
    self.escapedClaimIDs = escapedClaimIDs
    self.supportedCount = supportedCount
    self.rate = rate
  }
}

// MARK: - review-log.jsonl

/// One line of `<slug>.evidence/review-log.jsonl` (spec §12): a reviewer finding's disposition
/// after the user's Request-changes/approve decision. First defined here — no earlier wave
/// recorded this shape.
public struct ReviewLogRecord: Sendable, Equatable, Codable {
  public enum Disposition: String, Sendable, Equatable, CaseIterable, Codable {
    /// The finding stood: it blocked approval or was folded into a revise round.
    case accepted
    /// The user judged the finding not worth acting on.
    case dismissed
  }

  public let findingId: String
  public let reviewer: String
  public let disposition: Disposition
  public let reason: String

  public init(findingId: String, reviewer: String, disposition: Disposition, reason: String) {
    self.findingId = findingId
    self.reviewer = reviewer
    self.disposition = disposition
    self.reason = reason
  }
}

/// JSON Lines encoding for `review-log.jsonl`, matching `ClaimJSON`/`AmendmentJSON`'s shape: one
/// compact, key-sorted object per line, so two encodes of the same value produce identical bytes.
public enum ReviewLogJSON {
  public static func encodeLine(_ record: ReviewLogRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(record)
    data.append(UInt8(ascii: "\n"))
    return data
  }
}

/// A reviewer's findings that ever got a disposition: `accepted / (accepted + dismissed)`, `nil`
/// when the reviewer has neither (spec §12: "precision comes from the user's Request-changes
/// decisions and the dismissed-findings log").
public struct ReviewerPrecision: Sendable, Equatable {
  public let reviewer: String
  public let accepted: Int
  public let dismissed: Int
  public let precision: Rate

  public init(reviewer: String, accepted: Int, dismissed: Int, precision: Rate) {
    self.reviewer = reviewer
    self.accepted = accepted
    self.dismissed = dismissed
    self.precision = precision
  }
}

// MARK: - phases.jsonl

/// The closed set of phases the design and plan workflows pass through (spec §3.1, §3.2). First
/// defined here — the design skill (a later wave) writes `phases.jsonl` against this schema.
public enum DesignPlanPhase: String, Sendable, Equatable, CaseIterable, Codable {
  case frame
  case research
  case verify
  case draft
  case review
  /// One re-run of only the named reviewers (spec §8.4/§8.5's revise round).
  case revise
  case publish
  case amend
  case clarify
  case decompose
  case schedule
  case lint
  case index
}

/// One line of `.harness/runs/design-<id>/phases.jsonl`: what one agent invocation (or, for a
/// mechanical phase like `schedule`/`lint`/`index`, one `swiftgate` call) cost in one phase of one
/// run. `agentRole` reuses `ContextPackRole` (spec §5.10's fixed agent set) rather than a second,
/// drifting enum; it's `nil` for a mechanical phase no agent ran. `lane` is set only when
/// `agentRole == .researchLane`, naming which of the four lanes ran. A pre-mortem pass (deep tier
/// only) is logged under `agentRole == .challenger`: it shares that role's context pack and isn't
/// a fifth ``ContextPackRole``.
public struct PhaseRecord: Sendable, Equatable, Codable {
  public let schemaVersion: Int
  public let runId: String
  public let phase: DesignPlanPhase
  public let agentRole: ContextPackRole?
  public let lane: ResearchLane?
  public let tokens: Int
  /// `nil` when cost isn't tracked for this invocation (never a placeholder `0`).
  public let costUSD: Double?
  public let wallMilliseconds: Int

  public init(
    schemaVersion: Int = 1, runId: String, phase: DesignPlanPhase, agentRole: ContextPackRole?,
    lane: ResearchLane? = nil, tokens: Int, costUSD: Double?, wallMilliseconds: Int
  ) {
    self.schemaVersion = schemaVersion
    self.runId = runId
    self.phase = phase
    self.agentRole = agentRole
    self.lane = lane
    self.tokens = tokens
    self.costUSD = costUSD
    self.wallMilliseconds = wallMilliseconds
  }
}

/// One group's totals: every ``PhaseRecord`` sharing a phase, or sharing an agent role.
public struct PhaseGroupTotals<Key: Sendable & Equatable>: Sendable, Equatable {
  public let key: Key
  public let runs: Int
  public let tokens: Int
  /// `nil` only when not one contributing record carried a cost.
  public let costUSD: Double?
  public let wallMilliseconds: Int

  public init(key: Key, runs: Int, tokens: Int, costUSD: Double?, wallMilliseconds: Int) {
    self.key = key
    self.runs = runs
    self.tokens = tokens
    self.costUSD = costUSD
    self.wallMilliseconds = wallMilliseconds
  }
}

// MARK: - Estimate error (spec §9.3)

/// One task's planned size against what it actually took. `actualLines` is `nil` until something
/// records it (no wave writes it yet — `stats` names every task as excluded rather than treating
/// the gap as a real zero error).
public struct TaskEstimate: Sendable, Equatable {
  public let id: String
  public let estLines: Int
  public let actualLines: Int?

  public init(id: String, estLines: Int, actualLines: Int?) {
    self.id = id
    self.estLines = estLines
    self.actualLines = actualLines
  }
}

public struct TaskEstimateError: Sendable, Equatable {
  public let id: String
  public let estLines: Int
  public let actualLines: Int
  /// `actualLines - estLines`: positive means the task ran long.
  public let error: Int

  public init(id: String, estLines: Int, actualLines: Int, error: Int) {
    self.id = id
    self.estLines = estLines
    self.actualLines = actualLines
    self.error = error
  }
}

public struct EstimateErrorReport: Sendable, Equatable {
  public let perTask: [TaskEstimateError]
  public let excludedTaskIDs: [String]
  /// Mean of `|error|` over `perTask`; `nil` when every task was excluded.
  public let meanAbsoluteError: Double?

  public init(
    perTask: [TaskEstimateError], excludedTaskIDs: [String], meanAbsoluteError: Double?
  ) {
    self.perTask = perTask
    self.excludedTaskIDs = excludedTaskIDs
    self.meanAbsoluteError = meanAbsoluteError
  }
}

// MARK: - Probe fail rate (spec §12)

public struct ProbeFailReport: Sendable, Equatable {
  public let total: Int
  public let failed: Int
  public let failRate: Rate

  public init(total: Int, failed: Int, failRate: Rate) {
    self.total = total
    self.failed = failed
    self.failRate = failRate
  }
}

// MARK: - Cache hit rate (spec §12)

/// `hits / (hits + misses)`: a miss is a first-time cache entry (``CachedClaim``/``CachedVerdict``
/// created fresh); a hit is a later reuse of one (``CachedClaim/reuseCount`` /
/// ``CachedVerdict/reuseCount``).
public struct CacheHitReport: Sendable, Equatable {
  public let entries: Int
  public let reuses: Int
  public let hitRate: Rate

  public init(entries: Int, reuses: Int, hitRate: Rate) {
    self.entries = entries
    self.reuses = reuses
    self.hitRate = hitRate
  }
}

/// Pure §10/§12 metrics over already-decoded evidence, ledger and run records. No filesystem or
/// process access — every input is handed in already parsed, so this stays testable without a
/// repository (worker-brief rule: `SwiftGateDomain` touches no IO).
public enum DesignMetrics {
  /// Every ``ResearchLane`` is always present, even with zero claims (`Rate.value` is then `nil`,
  /// never a fabricated 0%): a lane with no research yet is a fact worth showing, not a row to
  /// omit.
  public static func laneReport(_ claims: [Claim]) -> ClaimLaneReport {
    var byLane: [ResearchLane: [Claim]] = [:]
    var unknown: [String: Int] = [:]
    for claim in claims {
      if let lane = ResearchLane(rawValue: claim.lane) {
        byLane[lane, default: []].append(claim)
      } else {
        unknown[claim.lane, default: 0] += 1
      }
    }
    let lanes = ResearchLane.allCases.map { lane -> LaneClaimMetrics in
      let claims = byLane[lane] ?? []
      let refuted = claims.count { $0.status == .refuted }
      let unverified = claims.count { $0.status != .supported && $0.status != .refuted }
      return LaneClaimMetrics(
        lane: lane, total: claims.count,
        refuteRate: Rate(numerator: refuted, denominator: claims.count),
        unverifiedRate: Rate(numerator: unverified, denominator: claims.count))
    }
    return ClaimLaneReport(lanes: lanes, unknownLaneClaimCounts: unknown)
  }

  public static func escapeRate(claims: [Claim], amendments: [Amendment]) -> EscapeRateReport {
    let amendedIDs = Set(amendments.filter { $0.class == .amend }.flatMap(\.changedIds))
    let supported = claims.filter { $0.status == .supported }
    let escaped = supported.filter { amendedIDs.contains($0.id) }
    return EscapeRateReport(
      escapedClaimIDs: Set(escaped.map(\.id)), supportedCount: supported.count,
      rate: Rate(numerator: escaped.count, denominator: supported.count))
  }

  public static func reviewerPrecision(_ records: [ReviewLogRecord]) -> [ReviewerPrecision] {
    let byReviewer = Dictionary(grouping: records, by: \.reviewer)
    return byReviewer.keys.sorted().map { reviewer in
      let entries = byReviewer[reviewer] ?? []
      let accepted = entries.count { $0.disposition == .accepted }
      let dismissed = entries.count { $0.disposition == .dismissed }
      return ReviewerPrecision(
        reviewer: reviewer, accepted: accepted, dismissed: dismissed,
        precision: Rate(numerator: accepted, denominator: accepted + dismissed))
    }
  }

  public static func totalsByPhase(_ records: [PhaseRecord]) -> [PhaseGroupTotals<DesignPlanPhase>]
  {
    DesignPlanPhase.allCases.compactMap { phase in
      let matched = records.filter { $0.phase == phase }
      guard !matched.isEmpty else { return nil }
      return totals(key: phase, matched)
    }
  }

  public static func totalsByAgent(_ records: [PhaseRecord])
    -> [PhaseGroupTotals<ContextPackRole>]
  {
    ContextPackRole.allCases.compactMap { role in
      let matched = records.filter { $0.agentRole == role }
      guard !matched.isEmpty else { return nil }
      return totals(key: role, matched)
    }
  }

  private static func totals<Key: Sendable & Equatable>(key: Key, _ records: [PhaseRecord])
    -> PhaseGroupTotals<Key>
  {
    let costs = records.compactMap(\.costUSD)
    return PhaseGroupTotals(
      key: key, runs: records.count, tokens: records.reduce(0) { $0 + $1.tokens },
      costUSD: costs.isEmpty ? nil : costs.reduce(0, +),
      wallMilliseconds: records.reduce(0) { $0 + $1.wallMilliseconds })
  }

  /// Share of total wall time spent outside `draft` (spec §9.3: "overhead share"). `nil` when
  /// there's no wall time recorded at all.
  public static func overheadShare(_ records: [PhaseRecord]) -> Rate {
    let total = records.reduce(0) { $0 + $1.wallMilliseconds }
    let draft = records.filter { $0.phase == .draft }.reduce(0) { $0 + $1.wallMilliseconds }
    return Rate(numerator: total - draft, denominator: total)
  }

  public static func estimateError(_ tasks: [TaskEstimate]) -> EstimateErrorReport {
    var perTask: [TaskEstimateError] = []
    var excluded: [String] = []
    for task in tasks {
      guard let actual = task.actualLines else {
        excluded.append(task.id)
        continue
      }
      perTask.append(
        TaskEstimateError(
          id: task.id, estLines: task.estLines, actualLines: actual,
          error: actual - task.estLines))
    }
    let mae: Double?
    if perTask.isEmpty {
      mae = nil
    } else {
      mae = Double(perTask.reduce(0) { $0 + abs($1.error) }) / Double(perTask.count)
    }
    return EstimateErrorReport(
      perTask: perTask, excludedTaskIDs: excluded, meanAbsoluteError: mae)
  }

  public static func probeFailRate(_ verdicts: [ProbeVerdictRecord]) -> ProbeFailReport {
    let failed = verdicts.count { $0.verdict == .fail }
    return ProbeFailReport(
      total: verdicts.count, failed: failed,
      failRate: Rate(numerator: failed, denominator: verdicts.count))
  }

  public static func cacheHitRate(claims: [CachedClaim], verdicts: [CachedVerdict])
    -> CacheHitReport
  {
    let entries = claims.count + verdicts.count
    let reuses =
      claims.reduce(0) { $0 + $1.reuseCount } + verdicts.reduce(0) { $0 + $1.reuseCount }
    return CacheHitReport(
      entries: entries, reuses: reuses,
      hitRate: Rate(numerator: reuses, denominator: entries + reuses))
  }
}
