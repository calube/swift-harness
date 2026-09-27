import Foundation

/// A design's depth tier (spec §8.1). It sets which reviewers the verdict requires.
public enum DesignTier: String, Sendable, Codable, CaseIterable {
  case quick
  case standard
  case deep
  /// A spec that already states what to build, such as an interview README (spec §9). Never
  /// recommended by `design-scope`; only a preset or `--tier sketch` selects it.
  case sketch

  /// Quick and sketch tiers run no review agents: the user's approval is the review (spec §8.1,
  /// §9).
  public var requiredReviewers: [DesignReviewer] {
    switch self {
    case .quick, .sketch: []
    case .standard: [.evidenceAuditor, .standardsReviewer, .challenger]
    case .deep: [.evidenceAuditor, .standardsReviewer, .challenger, .preMortem]
    }
  }
}

/// A design review agent (spec §7.2). Raw values are the `reviewer` strings in a reviewer file.
public enum DesignReviewer: String, Sendable, Codable, CaseIterable, Comparable {
  case evidenceAuditor = "evidence-auditor"
  case standardsReviewer = "standards-reviewer"
  case challenger
  case preMortem = "pre-mortem"

  private var ordinal: Int {
    switch self {
    case .evidenceAuditor: 0
    case .standardsReviewer: 1
    case .challenger: 2
    case .preMortem: 3
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.ordinal < rhs.ordinal }
}

/// The literal, machine-matched design review verdicts (spec §8.2).
public enum DesignReviewVerdict: String, Sendable, Codable {
  case ready
  case revise
  case rethink
}

/// A Foundation review finding (spec §9.1) located by a design section anchor instead of
/// `file:line`. On the wire it is the ``ReviewFinding`` object with `file`/`line` replaced by
/// `location: {anchor}`; in memory the Foundation finding carries the anchor in `file` so the
/// drop, dedupe and severity rules are the ones `review-synth` applies to code findings.
public struct DesignFinding: Sendable, Equatable, Codable {
  public let anchor: String
  public let finding: ReviewFinding

  public init(
    anchor: String, severity: Severity, category: String, title: String,
    failureScenario: String?, evidence: String, fix: String, verified: Bool?,
    kind: ReviewFinding.Kind? = nil, rule: String? = nil, verificationNote: String? = nil
  ) {
    self.anchor = anchor
    self.finding = ReviewFinding(
      severity: severity, category: category, file: anchor, line: nil, title: title,
      failureScenario: failureScenario, evidence: evidence, fix: fix, verified: verified,
      kind: kind, rule: rule, verificationNote: verificationNote)
  }

  private struct Location: Codable {
    let anchor: String
  }

  private enum CodingKeys: String, CodingKey {
    case severity, category, location, title, evidence, fix, verified, kind, rule
    case failureScenario = "failure_scenario"
    case verificationNote = "verification_note"
    case file, line
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // A reviewer that fills in the code contract's location has mixed up the two contracts;
    // reading its finding by anchor alone would hide that.
    for key in [CodingKeys.file, .line] where container.contains(key) {
      throw DecodingError.dataCorruptedError(
        forKey: key, in: container,
        debugDescription: "a design finding is located by location.anchor, not file:line")
    }
    self.init(
      anchor: try container.decode(Location.self, forKey: .location).anchor,
      severity: try container.decode(Severity.self, forKey: .severity),
      category: try container.decode(String.self, forKey: .category),
      title: try container.decode(String.self, forKey: .title),
      failureScenario: try container.decodeIfPresent(String.self, forKey: .failureScenario),
      evidence: try container.decode(String.self, forKey: .evidence),
      fix: try container.decode(String.self, forKey: .fix),
      verified: try container.decodeIfPresent(Bool.self, forKey: .verified),
      kind: try container.decodeIfPresent(ReviewFinding.Kind.self, forKey: .kind),
      rule: try container.decodeIfPresent(String.self, forKey: .rule),
      verificationNote: try container.decodeIfPresent(String.self, forKey: .verificationNote))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Location(anchor: anchor), forKey: .location)
    try container.encode(finding.severity, forKey: .severity)
    try container.encode(finding.category, forKey: .category)
    try container.encode(finding.title, forKey: .title)
    try container.encodeIfPresent(finding.failureScenario, forKey: .failureScenario)
    try container.encode(finding.evidence, forKey: .evidence)
    try container.encode(finding.fix, forKey: .fix)
    try container.encodeIfPresent(finding.verified, forKey: .verified)
    try container.encodeIfPresent(finding.kind, forKey: .kind)
    try container.encodeIfPresent(finding.rule, forKey: .rule)
    try container.encodeIfPresent(finding.verificationNote, forKey: .verificationNote)
  }
}

/// What one design reviewer produced: the design counterpart of ``FocusReview``.
public struct DesignReview: Sendable, Equatable {
  public enum Status: String, Sendable, Codable {
    case reviewed
    /// The reviewer died or returned nothing usable (`NOT REVIEWED`).
    case notReviewed = "not-reviewed"
    /// A research lane this reviewer depends on died (`NOT RESEARCHED`).
    case notResearched = "not-researched"
  }

  public let reviewer: DesignReviewer
  public let status: Status
  public let reason: String?
  public let findings: [DesignFinding]

  public init(
    reviewer: DesignReviewer, status: Status, reason: String?, findings: [DesignFinding]
  ) {
    self.reviewer = reviewer
    self.status = status
    self.reason = reason
    self.findings = findings
  }
}

public enum DesignReviewContractViolation: Error, Sendable, Equatable {
  case duplicateReviewer(DesignReviewer)
  case unknownAnchor(reviewer: DesignReviewer, anchor: String)
  case unsupportedSchemaVersion(Int)
}

/// The per-reviewer files the design review workflow writes and `review-synth --design` reads.
public enum DesignReviewJSON {
  public static let schemaVersion = 1

  private struct Envelope: Codable {
    let schemaVersion: Int
    let reviewer: DesignReviewer
    let status: DesignReview.Status
    let reason: String?
    let findings: [DesignFinding]
  }

  public static func decode(_ data: Data) throws -> DesignReview {
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.schemaVersion == schemaVersion else {
      throw DesignReviewContractViolation.unsupportedSchemaVersion(envelope.schemaVersion)
    }
    return DesignReview(
      reviewer: envelope.reviewer, status: envelope.status, reason: envelope.reason,
      findings: envelope.findings)
  }

  public static func encode(_ review: DesignReview) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(
      Envelope(
        schemaVersion: schemaVersion, reviewer: review.reviewer, status: review.status,
        reason: review.reason, findings: review.findings))
  }
}

/// The synthesized design review: `design-review.json`.
public struct DesignReviewReport: Sendable, Equatable, Codable {
  public struct Merged: Sendable, Equatable, Codable {
    public let finding: DesignFinding
    /// Every reviewer that reported this finding, in reviewer order.
    public let reviewers: [DesignReviewer]
  }

  public struct Dropped: Sendable, Equatable, Codable {
    public let reviewer: DesignReviewer
    public let finding: DesignFinding
    public let reason: ReviewReport.Dropped.Reason
  }

  public struct Gap: Sendable, Equatable, Codable {
    public let reviewer: DesignReviewer
    public let reason: String
  }

  public static let schemaVersion = 1

  public let schemaVersion: Int
  public let tier: DesignTier
  public let verdict: DesignReviewVerdict
  public let required: [DesignReviewer]
  /// The reviewers to run again: those whose kept blocker or major drove the verdict, plus every
  /// NOT REVIEWED or NOT RESEARCHED one. Empty exactly when the verdict is `ready`.
  public let rerun: [DesignReviewer]
  /// Most severe first, then by anchor, category and title.
  public let findings: [Merged]
  public let dropped: [Dropped]
  public let notReviewed: [Gap]
  public let notResearched: [Gap]
}

/// `review-synth --design`: the §8.2 verdict over verified design review findings. Findings pass
/// the same drop rules as `review-synth`; only the location and the verdict mapping differ.
public enum DesignReviewSynthesis {
  public static let decisionAnchor = "decision"

  public static func synthesize(
    _ inputs: [DesignReview], tier: DesignTier, document: MarkdownDocument
  ) throws(DesignReviewContractViolation) -> DesignReviewReport {
    var byReviewer: [DesignReviewer: DesignReview] = [:]
    for input in inputs {
      guard byReviewer[input.reviewer] == nil else { throw .duplicateReviewer(input.reviewer) }
      for finding in input.findings where document.section(anchor: finding.anchor) == nil {
        throw .unknownAnchor(reviewer: input.reviewer, anchor: finding.anchor)
      }
      byReviewer[input.reviewer] = input
    }

    var notReviewed: [DesignReviewReport.Gap] = []
    var notResearched: [DesignReviewReport.Gap] = []
    var dropped: [DesignReviewReport.Dropped] = []
    var merged: [DedupeKey: (finding: DesignFinding, reviewers: Set<DesignReviewer>)] = [:]
    // Judged per reviewer, not per merged finding: a reviewer that rated a shared finding minor
    // didn't drive a revise another reviewer's major caused, so re-running it wastes a round.
    var raisedGatingFinding: Set<DesignReviewer> = []
    let required = Set(tier.requiredReviewers)
    for reviewer in DesignReviewer.allCases {
      guard let review = byReviewer[reviewer] else {
        if required.contains(reviewer) {
          notReviewed.append(
            .init(reviewer: reviewer, reason: "no result was produced for this reviewer"))
        }
        continue
      }
      switch review.status {
      case .notReviewed:
        notReviewed.append(.init(reviewer: reviewer, reason: review.reason ?? "no reason given"))
        continue
      case .notResearched:
        notResearched.append(.init(reviewer: reviewer, reason: review.reason ?? "no reason given"))
        continue
      case .reviewed:
        break
      }
      for designFinding in review.findings {
        if let reason = ReviewSynthesis.dropReason(designFinding.finding) {
          dropped.append(.init(reviewer: reviewer, finding: designFinding, reason: reason))
          continue
        }
        if designFinding.finding.severity.failsGate { raisedGatingFinding.insert(reviewer) }
        let key = DedupeKey(designFinding)
        if let existing = merged[key] {
          let keep =
            designFinding.finding.severity.rank < existing.finding.finding.severity.rank
            ? designFinding : existing.finding
          merged[key] = (keep, existing.reviewers.union([reviewer]))
        } else {
          merged[key] = (designFinding, [reviewer])
        }
      }
    }

    let findings = merged.values
      .map { DesignReviewReport.Merged(finding: $0.finding, reviewers: $0.reviewers.sorted()) }
      .sorted { order($0.finding) < order($1.finding) }
    let driving = findings.filter { $0.finding.finding.severity.failsGate }
    let gaps = notReviewed + notResearched
    let rerun = raisedGatingFinding.union(gaps.map(\.reviewer)).sorted()
    let decisionAnchors = anchors(under: document.section(anchor: decisionAnchor))
    return DesignReviewReport(
      schemaVersion: DesignReviewReport.schemaVersion, tier: tier,
      verdict: verdict(
        driving: driving, anyGap: !gaps.isEmpty, decisionAnchors: decisionAnchors),
      required: tier.requiredReviewers, rerun: rerun, findings: findings,
      dropped: dropped.sorted { order($0.finding) < order($1.finding) },
      notReviewed: notReviewed, notResearched: notResearched)
  }

  static func verdict(
    driving: [DesignReviewReport.Merged], anyGap: Bool, decisionAnchors: Set<String>
  ) -> DesignReviewVerdict {
    if driving.contains(where: {
      $0.finding.finding.severity == .blocker && decisionAnchors.contains($0.finding.anchor)
    }) {
      return .rethink
    }
    // A missing reviewer or research lane may hide a blocker; the fix is to re-run it.
    return driving.isEmpty && !anyGap ? .ready : .revise
  }

  private static func anchors(under section: MarkdownDocument.Section?) -> Set<String> {
    guard let section else { return [] }
    return section.subsections.reduce(into: [section.anchor]) { $0.formUnion(anchors(under: $1)) }
  }

  /// `review-synth`'s dedupe key with the anchor in place of `file:line`.
  private struct DedupeKey: Hashable {
    enum Identity: Hashable {
      case defect(category: String)
      case violation(rule: String)
    }

    let anchor: String
    let identity: Identity

    init(_ designFinding: DesignFinding) {
      anchor = designFinding.anchor
      let finding = designFinding.finding
      switch finding.effectiveKind {
      case .defect:
        identity = .defect(category: finding.category.lowercased())
      case .standardsViolation:
        let rule = (finding.rule ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        identity = .violation(rule: rule)
      }
    }
  }

  private static func order(_ designFinding: DesignFinding) -> OrderKey {
    let finding = designFinding.finding
    return OrderKey(
      rank: finding.severity.rank, anchor: designFinding.anchor, category: finding.category,
      title: finding.title)
  }

  private struct OrderKey: Comparable {
    let rank: Int
    let anchor: String
    let category: String
    let title: String

    static func < (lhs: Self, rhs: Self) -> Bool {
      (lhs.rank, lhs.anchor, lhs.category, lhs.title)
        < (rhs.rank, rhs.anchor, rhs.category, rhs.title)
    }
  }
}

/// The summary the caller of a design review receives: verdict, re-runs, gaps, top findings.
public enum DesignReviewSummary {
  public static func render(_ report: DesignReviewReport, reportPath: String) -> String {
    var lines = [
      "design review: \(report.verdict.rawValue) (tier \(report.tier.rawValue)) — "
        + "\(report.findings.count) findings, \(report.dropped.count) dropped at verify"
    ]
    if !report.rerun.isEmpty {
      lines.append("re-run: " + report.rerun.map(\.rawValue).joined(separator: ", "))
    }
    for (label, gaps) in [
      ("NOT REVIEWED", report.notReviewed), ("NOT RESEARCHED", report.notResearched),
    ]
    where !gaps.isEmpty {
      lines.append(
        "\(label): "
          + gaps.map { "\($0.reviewer.rawValue) (\($0.reason))" }.joined(separator: "; "))
    }
    for (index, merged) in report.findings.prefix(ReviewSummary.topFindings).enumerated() {
      let finding = merged.finding.finding
      let reviewers = merged.reviewers.map(\.rawValue).joined(separator: ",")
      lines.append(
        "\(index + 1). [\(finding.severity.rawValue)] \(reviewers)/\(finding.category) "
          + "#\(merged.finding.anchor) — \(finding.title)")
    }
    let rest = report.findings.count - ReviewSummary.topFindings
    lines.append(rest > 0 ? "… \(rest) more in \(reportPath)" : "full report: \(reportPath)")
    return lines.joined(separator: "\n")
  }
}
