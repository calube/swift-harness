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

/// One verifier-checked finding in the shared review contract (spec §9.1, refined by
/// `docs/adrs/0001-review-severity-for-standards-violations.md`).
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

  public init(
    severity: Severity, category: String, file: String, line: Int?, title: String,
    failureScenario: String?, evidence: String, fix: String, verified: Bool?,
    kind: Kind? = nil, rule: String? = nil, verificationNote: String? = nil
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
  }

  private enum CodingKeys: String, CodingKey {
    case severity, category, file, line, title, evidence, fix, verified, kind, rule
    case failureScenario = "failure_scenario"
    case verificationNote = "verification_note"
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

  public struct Unreviewed: Sendable, Equatable, Codable {
    public let focus: ReviewFocus
    public let reason: String
  }

  public static let schemaVersion = 1

  public let schemaVersion: Int
  public let verdict: ReviewVerdict
  /// Most severe first, then by file, line and category.
  public let findings: [Merged]
  public let dropped: [Dropped]
  public let notReviewed: [Unreviewed]
  public let notApplicable: [ReviewFocus]
}

/// `review-synth`: deterministic dedupe and verdict (spec §9.2 step 4). No judgment happens here;
/// every judgment was made by a reviewer and confirmed by a verifier.
public enum ReviewSynthesis {
  public static func synthesize(_ inputs: [FocusReview]) throws(ReviewContractViolation)
    -> ReviewReport
  {
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
    var merged: [DedupeKey: (finding: ReviewFinding, focuses: Set<ReviewFocus>)] = [:]
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
        guard finding.hasFailureScenario else {
          dropped.append(.init(focus: focus, finding: finding, reason: .noFailureScenario))
          continue
        }
        guard finding.effectiveKind == .defect || finding.citesRule else {
          dropped.append(.init(focus: focus, finding: finding, reason: .noRuleCitation))
          continue
        }
        guard finding.verified == true else {
          dropped.append(.init(focus: focus, finding: finding, reason: .unverified))
          continue
        }
        let key = DedupeKey(finding)
        if let existing = merged[key] {
          let keep =
            finding.severity.rank < existing.finding.severity.rank ? finding : existing.finding
          merged[key] = (keep, existing.focuses.union([focus]))
        } else {
          merged[key] = (finding, [focus])
        }
      }
    }

    let findings = merged.values
      .map { ReviewReport.Merged(finding: $0.finding, focuses: $0.focuses.sorted()) }
      .sorted { order($0.finding) < order($1.finding) }
    return ReviewReport(
      schemaVersion: ReviewReport.schemaVersion,
      verdict: verdict(findings: findings, anyUnreviewed: !notReviewed.isEmpty),
      findings: findings,
      dropped: dropped.sorted { order($0.finding) < order($1.finding) },
      notReviewed: notReviewed, notApplicable: notApplicable)
  }

  static func verdict(findings: [ReviewReport.Merged], anyUnreviewed: Bool) -> ReviewVerdict {
    if findings.contains(where: {
      $0.finding.severity == .blocker && $0.focuses.contains(.architecture)
    }) {
      return .refactorNeeded
    }
    if findings.contains(where: { $0.finding.severity.failsGate }) { return .fixThenMerge }
    // An unreviewed focus may hide a blocker; the fix is to re-run it.
    return anyUnreviewed ? .fixThenMerge : .merge
  }

  /// Defects merge on (file, line, category). Standards violations merge on (file, line, rule):
  /// category is free text each reviewer invents, so two focuses citing one rule at one line
  /// name it differently, while the rule id is shared vocabulary.
  private struct DedupeKey: Hashable {
    enum Identity: Hashable {
      case defect(category: String)
      case violation(rule: String)
    }

    let file: String
    let line: Int?
    let identity: Identity

    init(_ finding: ReviewFinding) {
      file = finding.file
      line = finding.line
      switch finding.effectiveKind {
      case .defect:
        identity = .defect(category: finding.category.lowercased())
      case .standardsViolation:
        let rule = (finding.rule ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        identity = .violation(rule: rule)
      }
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

/// The ≤ 30-line summary the caller of the review receives: verdict, gaps, top 10 findings.
public enum ReviewSummary {
  public static let topFindings = 10
  static let scenarioLimit = 160

  public static func render(_ report: ReviewReport, reportPath: String) -> String {
    let counts = Severity.allCases.compactMap { severity -> String? in
      let n = report.findings.filter { $0.finding.severity == severity }.count
      return n == 0 ? nil : "\(n) \(severity.rawValue)"
    }
    var header = "review: \(report.verdict.rawValue) — \(report.findings.count) findings"
    if !counts.isEmpty { header += " (\(counts.joined(separator: ", ")))" }
    if !report.dropped.isEmpty { header += ", \(report.dropped.count) dropped at verify" }
    var lines = [header]
    if !report.notReviewed.isEmpty {
      lines.append(
        "NOT REVIEWED: "
          + report.notReviewed.map { "\($0.focus.rawValue) (\($0.reason))" }.joined(
            separator: "; "))
    }
    for (index, merged) in report.findings.prefix(topFindings).enumerated() {
      let finding = merged.finding
      let location = finding.line.map { "\(finding.file):\($0)" } ?? finding.file
      let focuses = merged.focuses.map(\.rawValue).joined(separator: ",")
      let rule = finding.effectiveKind == .standardsViolation ? " (\(finding.rule ?? ""))" : ""
      lines.append(
        "\(index + 1). [\(finding.severity.rawValue)] \(focuses)/\(finding.category)\(rule) \(location) — \(finding.title)"
      )
      lines.append("   scenario: \(truncated(finding.failureScenario ?? ""))")
    }
    let rest = report.findings.count - topFindings
    lines.append(
      rest > 0 ? "… \(rest) more in \(reportPath)" : "full report: \(reportPath)")
    return lines.joined(separator: "\n")
  }

  private static func truncated(_ text: String) -> String {
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    return flat.count <= scenarioLimit ? flat : String(flat.prefix(scenarioLimit - 1)) + "…"
  }
}
