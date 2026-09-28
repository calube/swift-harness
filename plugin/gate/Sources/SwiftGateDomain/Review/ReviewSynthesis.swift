import Foundation

/// A review lens. Each focus is one reviewer agent plus its verifier (spec §9.2).
public enum ReviewFocus: String, Sendable, Codable, CaseIterable, Comparable {
  case concurrency
  case architecture
  case testQuality = "test-quality"
  case apiErrors = "api-errors"
  /// Runs only when the diff touches a module importing SwiftUI.
  case swiftui

  private var ordinal: Int {
    switch self {
    case .concurrency: 0
    case .architecture: 1
    case .testQuality: 2
    case .apiErrors: 3
    case .swiftui: 4
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.ordinal < rhs.ordinal }
}

/// The literal, machine-matched review verdicts (spec §9.1).
public enum ReviewVerdict: String, Sendable, Codable {
  case merge
  case fixThenMerge = "fix-then-merge"
  case refactorNeeded = "refactor-needed"
}

/// One verifier-checked finding in the shared review contract (the plugin's
/// `docs/review-contract.md`).
public struct ReviewFinding: Sendable, Equatable, Codable {
  /// How the finding was verified. A defect is verified by reproducing its failure scenario; a
  /// standards violation by its cited rule, the quoted code, and why the rule applies.
  public enum Kind: String, Sendable, Codable {
    case defect
    case standardsViolation = "standards-violation"
  }

  public let severity: Severity
  /// Short kebab-case defect class (`data-race`, `layering`). For a defect, with `file` and
  /// `line` it is the dedupe key; a standards violation dedupes on `rule` instead.
  public let category: String
  public let file: String
  public let line: Int?
  public let title: String
  /// Concrete input or state → wrong outcome; for a standards violation, the maintenance or
  /// correctness risk the rule prevents. A finding without one is dropped.
  public let failureScenario: String?
  public let evidence: String
  public let fix: String
  /// Set by the verifier; only `true` survives synthesis.
  public let verified: Bool?
  /// Absent in focus files written before the field existed; read through ``effectiveKind``.
  public let kind: Kind?
  /// The standards or playbook rule id a standards violation breaks (`D7`, `P5`).
  public let rule: String?
  /// What the verifier traced; kept so a reader of `review.json` can audit the confirmation.
  public let verificationNote: String?
  /// Set by the review workflow when the verifier returned no entry for this finding.
  public let unmatched: Bool?
  /// The last line of the wrong code when it spans several; `line` is the first.
  public let endLine: Int?
  /// The contract severity rule the verifier applied; synthesis raises `severity` to it.
  public let severityRule: SeverityRule?

  public init(
    severity: Severity, category: String, file: String, line: Int?, title: String,
    failureScenario: String?, evidence: String, fix: String, verified: Bool?,
    kind: Kind? = nil, rule: String? = nil, verificationNote: String? = nil,
    unmatched: Bool? = nil, endLine: Int? = nil, severityRule: SeverityRule? = nil
  ) {
    self.severity = severity
    self.category = category
    self.file = file
    self.line = line
    self.title = title
    self.failureScenario = failureScenario
    self.evidence = evidence
    self.fix = fix
    self.verified = verified
    self.kind = kind
    self.rule = rule
    self.verificationNote = verificationNote
    self.unmatched = unmatched
    self.endLine = endLine
    self.severityRule = severityRule
  }

  private enum CodingKeys: String, CodingKey {
    case severity, category, file, line, title, evidence, fix, verified, kind, rule, unmatched
    case failureScenario = "failure_scenario"
    case verificationNote = "verification_note"
    case endLine = "end_line"
    case severityRule = "severity_rule"
  }

  /// The same finding with a different severity, category and evidence: what a merge or a
  /// severity rule changes.
  func with(severity: Severity, category: String, evidence: String) -> ReviewFinding {
    ReviewFinding(
      severity: severity, category: category, file: file, line: line, title: title,
      failureScenario: failureScenario, evidence: evidence, fix: fix, verified: verified,
      kind: kind, rule: rule, verificationNote: verificationNote, unmatched: unmatched,
      endLine: endLine, severityRule: severityRule)
  }

  /// The lines the finding covers, or `nil` when it names no line.
  var lineRange: ClosedRange<Int>? {
    guard let line else { return nil }
    return line...max(line, endLine ?? line)
  }

  public var effectiveKind: Kind { kind ?? .defect }

  var hasFailureScenario: Bool {
    !(failureScenario ?? "").allSatisfy(\.isWhitespace)
  }

  var citesRule: Bool {
    !(rule ?? "").allSatisfy(\.isWhitespace)
  }
}

/// What one focus's reviewer+verifier pair produced.
public struct FocusReview: Sendable, Equatable, Codable {
  public enum Status: String, Sendable, Codable {
    case reviewed
    /// The reviewer or verifier died or returned nothing usable.
    case notReviewed = "not-reviewed"
    /// Only for ``ReviewFocus/swiftui`` when no SwiftUI module is touched.
    case notApplicable = "not-applicable"
  }

  public let focus: ReviewFocus
  public let status: Status
  public let reason: String?
  public let findings: [ReviewFinding]

  public init(focus: ReviewFocus, status: Status, reason: String?, findings: [ReviewFinding]) {
    self.focus = focus
    self.status = status
    self.reason = reason
    self.findings = findings
  }
}

public enum ReviewContractViolation: Error, Sendable, Equatable {
  case duplicateFocus(ReviewFocus)
  case notApplicable(ReviewFocus)
  case unsupportedSchemaVersion(Int)
  /// The verifier cited a severity rule the contract states only for the other kind.
  case severityRuleKind(SeverityRule, ReviewFinding.Kind)
}

/// The per-focus files the review workflow writes and `review-synth` reads.
public enum FocusReviewJSON {
  public static let schemaVersion = 1

  private struct Envelope: Codable {
    let schemaVersion: Int
    let focus: ReviewFocus
    let status: FocusReview.Status
    let reason: String?
    let findings: [ReviewFinding]
  }

  public static func decode(_ data: Data) throws -> FocusReview {
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.schemaVersion == schemaVersion else {
      throw ReviewContractViolation.unsupportedSchemaVersion(envelope.schemaVersion)
    }
    return FocusReview(
      focus: envelope.focus, status: envelope.status, reason: envelope.reason,
      findings: envelope.findings)
  }

  public static func encode(_ review: FocusReview) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(
      Envelope(
        schemaVersion: schemaVersion, focus: review.focus, status: review.status,
        reason: review.reason, findings: review.findings))
  }
}

/// The synthesized review: `review.json`.
public struct ReviewReport: Sendable, Equatable, Codable {
  public struct Merged: Sendable, Equatable, Codable {
    public let finding: ReviewFinding
    /// Every focus that reported this finding, in focus order.
    public let focuses: [ReviewFocus]
    /// Every line the merged copies cited, ascending.
    public let lines: [Int]
  }

  public struct Dropped: Sendable, Equatable, Codable {
    public enum Reason: String, Sendable, Codable {
      case noFailureScenario = "no-failure-scenario"
      case unverified
      /// A standards violation that names no rule can't be checked against the standards.
      case noRuleCitation = "no-rule-citation"
    }
    public let focus: ReviewFocus
    public let finding: ReviewFinding
    public let reason: Reason
  }

  /// A finding the verifier returned no entry for: kept visible, and the verdict can't be
  /// `merge` while one on code the diff changed is listed, as for an unreviewed focus.
  public struct Unmatched: Sendable, Equatable, Codable {
    public let focus: ReviewFocus
    public let finding: ReviewFinding
    /// On code the diff didn't add or change, so it never holds the verdict.
    public let preExisting: Bool
  }

  public struct Unreviewed: Sendable, Equatable, Codable {
    public let focus: ReviewFocus
    public let reason: String
  }

  public static let schemaVersion = 1

  public let schemaVersion: Int
  public let verdict: ReviewVerdict
  /// Findings on code the diff added or changed. Most severe first, then by file, line and
  /// category.
  public let findings: [Merged]
  /// Verified findings on code the diff didn't add or change: reported with their severity,
  /// never counted toward the verdict.
  public let preExisting: [Merged]
  public let dropped: [Dropped]
  public let unmatched: [Unmatched]
  public let notReviewed: [Unreviewed]
  public let notApplicable: [ReviewFocus]
  /// Why the pre-existing check didn't run, when it didn't; every finding then counts.
  public let baselineUnavailable: String?
  /// The run's telemetry file, set by the command that wrote it.
  public var telemetry: String?
}

/// `review-synth`: deterministic dedupe and verdict (spec §9.2 step 4). No judgment happens here;
/// every judgment was made by a reviewer and confirmed by a verifier.
public enum ReviewSynthesis {
  /// Same-kind findings in one file merge when their line ranges overlap or lie at most this many
  /// lines apart: in a real run, three reviewers cited one race across a 4-line span.
  public static let dedupeWindow = 3

  /// Category names reviewers invented for one defect class, mapped to the canonical name.
  static let categorySynonyms: [String: String] = [
    "missing-cancellation": "effect-lifetime",
    "missing-effect-cancellation": "effect-lifetime",
  ]

  /// `telemetry` is the path of the run's telemetry file, written before synthesis.
  public static func synthesize(
    _ inputs: [FocusReview],
    baseline: ReviewBaseline = .unavailable(reason: "no numbered diff was given"),
    telemetry: String
  ) throws(ReviewContractViolation) -> ReviewReport {
    var byFocus: [ReviewFocus: FocusReview] = [:]
    for input in inputs {
      guard byFocus[input.focus] == nil else { throw .duplicateFocus(input.focus) }
      if input.status == .notApplicable, input.focus != .swiftui {
        throw .notApplicable(input.focus)
      }
      byFocus[input.focus] = input
    }

    var notReviewed: [ReviewReport.Unreviewed] = []
    var notApplicable: [ReviewFocus] = []
    var dropped: [ReviewReport.Dropped] = []
    var unmatched: [ReviewReport.Unmatched] = []
    var kept: [Candidate] = []
    for focus in ReviewFocus.allCases {
      guard let review = byFocus[focus] else {
        notReviewed.append(.init(focus: focus, reason: "no result was produced for this focus"))
        continue
      }
      switch review.status {
      case .notApplicable:
        notApplicable.append(focus)
        continue
      case .notReviewed:
        notReviewed.append(.init(focus: focus, reason: review.reason ?? "no reason given"))
        continue
      case .reviewed:
        break
      }
      for finding in review.findings {
        if let rule = finding.severityRule, !rule.applies(to: finding.effectiveKind) {
          throw .severityRuleKind(rule, finding.effectiveKind)
        }
        let preExisting = isPreExisting(finding, baseline: baseline)
        if let reason = dropReason(finding) {
          // The verifier never judged this finding, so it is neither verified nor refuted.
          if reason == .unverified, finding.unmatched == true {
            unmatched.append(.init(focus: focus, finding: finding, preExisting: preExisting))
            continue
          }
          dropped.append(.init(focus: focus, finding: finding, reason: reason))
          continue
        }
        kept.append(
          Candidate(finding: enforcingRule(finding), focus: focus, preExisting: preExisting))
      }
    }

    let findings = merge(kept.filter { !$0.preExisting })
    let preExisting = merge(kept.filter(\.preExisting))
    let baselineUnavailable: String?
    if case .unavailable(let reason) = baseline {
      baselineUnavailable = reason
    } else {
      baselineUnavailable = nil
    }
    return ReviewReport(
      schemaVersion: ReviewReport.schemaVersion,
      verdict: verdict(
        findings: findings,
        anyUnreviewed: !notReviewed.isEmpty || unmatched.contains { !$0.preExisting }),
      findings: findings, preExisting: preExisting,
      dropped: dropped.sorted { order($0.finding) < order($1.finding) },
      unmatched: unmatched.sorted { order($0.finding) < order($1.finding) },
      notReviewed: notReviewed, notApplicable: notApplicable,
      baselineUnavailable: baselineUnavailable, telemetry: nil)
  }

  /// The verify step's drop rule, shared by code and design review so the two can't drift.
  /// Location plays no part: it is `file:line` for code and a section anchor for a design.
  static func dropReason(_ finding: ReviewFinding) -> ReviewReport.Dropped.Reason? {
    guard finding.hasFailureScenario else { return .noFailureScenario }
    guard finding.effectiveKind == .defect || finding.citesRule else { return .noRuleCitation }
    guard finding.verified == true else { return .unverified }
    return nil
  }

  static func verdict(findings: [ReviewReport.Merged], anyUnreviewed: Bool) -> ReviewVerdict {
    if findings.contains(where: {
      $0.finding.severity == .blocker && $0.focuses.contains(.architecture)
    }) {
      return .refactorNeeded
    }
    if findings.contains(where: { $0.finding.severity.failsGate }) { return .fixThenMerge }
    // An unreviewed focus or finding may hide a blocker; the fix is to re-run it.
    return anyUnreviewed ? .fixThenMerge : .merge
  }

  /// A finding with no line can't be placed, so it counts, as does every finding when the diff
  /// couldn't be read.
  static func isPreExisting(_ finding: ReviewFinding, baseline: ReviewBaseline) -> Bool {
    guard case .diff(let changed) = baseline, let range = finding.lineRange else { return false }
    return !changed.introduces(file: finding.file, lines: range)
  }

  /// A severity rule raises the finding to the severity it states and never lowers it: lowering
  /// is the verifier's call, under the contract's downgrade rules.
  static func enforcingRule(_ finding: ReviewFinding) -> ReviewFinding {
    guard let rule = finding.severityRule, rule.severity.rank < finding.severity.rank else {
      return finding
    }
    return finding.with(
      severity: rule.severity, category: finding.category, evidence: finding.evidence)
  }

  static func canonicalCategory(_ category: String) -> String {
    let lowered = category.lowercased()
    return categorySynonyms[lowered] ?? lowered
  }

  private struct Candidate {
    let finding: ReviewFinding
    let focus: ReviewFocus
    let preExisting: Bool
  }

  /// Defects merge on file and canonical category, standards violations on file and rule:
  /// category is free text each reviewer invents, while the rule id is shared vocabulary. Within
  /// that, findings chain into one while each starts within ``dedupeWindow`` lines of the lines
  /// covered so far; findings with no line merge only with each other.
  private struct GroupKey: Hashable {
    enum Identity: Hashable {
      case defect(category: String)
      case violation(rule: String)
    }

    let file: String
    let located: Bool
    let identity: Identity

    init(_ finding: ReviewFinding) {
      file = finding.file
      located = finding.line != nil
      switch finding.effectiveKind {
      case .defect:
        identity = .defect(category: ReviewSynthesis.canonicalCategory(finding.category))
      case .standardsViolation:
        let rule = (finding.rule ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        identity = .violation(rule: rule)
      }
    }
  }

  private static func merge(_ candidates: [Candidate]) -> [ReviewReport.Merged] {
    let groups = Dictionary(grouping: candidates) { GroupKey($0.finding) }
    var clusters: [[Candidate]] = []
    for group in groups.values {
      let sorted = group.sorted { clusterOrder($0) < clusterOrder($1) }
      var current: [Candidate] = []
      var upper = Int.min
      for candidate in sorted {
        let range = candidate.finding.lineRange
        if !current.isEmpty, let range, range.lowerBound > upper + dedupeWindow {
          clusters.append(current)
          current = []
        }
        current.append(candidate)
        if let range { upper = max(upper, range.upperBound) }
      }
      if !current.isEmpty { clusters.append(current) }
    }
    return clusters.map(merged).sorted { order($0.finding) < order($1.finding) }
  }

  private static func merged(_ cluster: [Candidate]) -> ReviewReport.Merged {
    // The most severe copy leads; ties go to the first in line, focus and title order, then to
    // the one its focus reported first.
    let lead = cluster.dropFirst().reduce(cluster[0]) { best, next in
      (next.finding.severity.rank, clusterOrder(next))
        < (best.finding.severity.rank, clusterOrder(best)) ? next : best
    }
    var evidence: [String] = []
    for candidate in [lead] + cluster where !evidence.contains(candidate.finding.evidence) {
      evidence.append(candidate.finding.evidence)
    }
    let category =
      lead.finding.effectiveKind == .defect
      ? canonicalCategory(lead.finding.category) : lead.finding.category
    return ReviewReport.Merged(
      finding: lead.finding.with(
        severity: lead.finding.severity, category: category,
        evidence: evidence.joined(separator: "\n---\n")),
      focuses: Set(cluster.map(\.focus)).sorted(),
      lines: Set(cluster.compactMap(\.finding.line)).sorted())
  }

  private static func clusterOrder(_ candidate: Candidate) -> ClusterKey {
    let range = candidate.finding.lineRange
    return ClusterKey(
      lower: range?.lowerBound ?? 0, upper: range?.upperBound ?? 0, focus: candidate.focus,
      title: candidate.finding.title)
  }

  private struct ClusterKey: Comparable {
    let lower: Int
    let upper: Int
    let focus: ReviewFocus
    let title: String

    static func < (lhs: Self, rhs: Self) -> Bool {
      (lhs.lower, lhs.upper, lhs.focus, lhs.title) < (rhs.lower, rhs.upper, rhs.focus, rhs.title)
    }
  }

  private static func order(_ finding: ReviewFinding) -> OrderKey {
    OrderKey(
      rank: finding.severity.rank, file: finding.file, line: finding.line ?? 0,
      category: finding.category, title: finding.title)
  }

  private struct OrderKey: Comparable {
    let rank: Int
    let file: String
    let line: Int
    let category: String
    let title: String

    static func < (lhs: Self, rhs: Self) -> Bool {
      (lhs.rank, lhs.file, lhs.line, lhs.category, lhs.title)
        < (rhs.rank, rhs.file, rhs.line, rhs.category, rhs.title)
    }
  }
}

/// The ≤ 30-line summary the caller of the review receives: verdict, gaps, top findings.
public enum ReviewSummary {
  public static let topFindings = 10
  static let maxLines = 30
  static let topUnmatched = 4
  static let topPreExisting = 3
  static let scenarioLimit = 160

  public static func render(_ report: ReviewReport, reportPath: String) -> String {
    let counts = Severity.allCases.compactMap { severity -> String? in
      let n = report.findings.filter { $0.finding.severity == severity }.count
      return n == 0 ? nil : "\(n) \(severity.rawValue)"
    }
    var header = "review: \(report.verdict.rawValue) — \(report.findings.count) findings"
    if !counts.isEmpty { header += " (\(counts.joined(separator: ", ")))" }
    if !report.dropped.isEmpty { header += ", \(report.dropped.count) dropped at verify" }
    var head = [header]
    if let reason = report.baselineUnavailable {
      head.append("pre-existing check unavailable: \(reason); every finding counts")
    }
    if !report.notReviewed.isEmpty {
      head.append(
        "NOT REVIEWED: "
          + report.notReviewed.map { "\($0.focus.rawValue) (\($0.reason))" }.joined(
            separator: "; "))
    }
    if !report.unmatched.isEmpty {
      head.append(
        "UNMATCHED AT VERIFY (the verifier returned nothing for these; re-run the review):")
      for entry in report.unmatched.prefix(topUnmatched) {
        let finding = entry.finding
        let baseline = entry.preExisting ? " (pre-existing)" : ""
        head.append(
          "   [\(finding.severity.rawValue)] \(entry.focus.rawValue)/\(finding.category) \(location(finding))\(baseline) — \(finding.title)"
        )
      }
      if report.unmatched.count > topUnmatched {
        head.append("   … \(report.unmatched.count - topUnmatched) more in review.json")
      }
    }

    var tail: [String] = []
    if !report.preExisting.isEmpty {
      let shown = report.preExisting.prefix(topPreExisting).map {
        "[\($0.finding.severity.rawValue)] \($0.finding.category) \(location($0.finding))"
      }
      let more =
        report.preExisting.count > topPreExisting
        ? "; … \(report.preExisting.count - topPreExisting) more" : ""
      tail.append(
        "PRE-EXISTING (not counted toward the verdict): \(report.preExisting.count) — "
          + shown.joined(separator: "; ") + more)
    }
    if let telemetry = report.telemetry { tail.append("telemetry: \(telemetry)") }

    // Each listed finding takes two lines; one more line closes the list.
    let room = max(0, (maxLines - head.count - tail.count - 1) / 2)
    let shown = min(topFindings, room)
    var lines = head
    for (index, merged) in report.findings.prefix(shown).enumerated() {
      let finding = merged.finding
      let focuses = merged.focuses.map(\.rawValue).joined(separator: ",")
      let rule = finding.effectiveKind == .standardsViolation ? " (\(finding.rule ?? ""))" : ""
      lines.append(
        "\(index + 1). [\(finding.severity.rawValue)] \(focuses)/\(finding.category)\(rule) \(location(finding)) — \(finding.title)"
      )
      lines.append("   scenario: \(truncated(finding.failureScenario ?? ""))")
    }
    let rest = report.findings.count - shown
    lines.append(
      rest > 0 ? "… \(rest) more in \(reportPath)" : "full report: \(reportPath)")
    return (lines + tail).joined(separator: "\n")
  }

  private static func location(_ finding: ReviewFinding) -> String {
    finding.line.map { "\(finding.file):\($0)" } ?? finding.file
  }

  private static func truncated(_ text: String) -> String {
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    return flat.count <= scenarioLimit ? flat : String(flat.prefix(scenarioLimit - 1)) + "…"
  }
}
