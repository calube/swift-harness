/// `design-lint`'s evidence-tagging rules (spec §5.3, D5): every Evidence, Decision and Perf &
/// scale bullet carries a citation tag; a Decision's cited claim must be `supported`; an
/// `[UNVERIFIED]` tag anywhere in those three sections needs Risks or Open questions to carry
/// something back for it; and Perf & scale names all seven dimensions. `claims` is the design's
/// `claims.jsonl`, loaded by the caller — this type does no IO of its own.
public enum DesignLintEvidence {
  /// The seven Perf & scale dimensions spec §5.3 requires named — closed, so a missing dimension
  /// can only ever be "not yet named," never "some dimension nobody defined here."
  public enum PerfDimension: String, CaseIterable, Sendable, Equatable {
    case throughput
    case tailLatency = "tail-latency"
    case fanOut = "fan-out"
    case failureIsolation = "failure-isolation"
    case resources
    case backpressure
    case tenX = "10x"

    public var displayName: String {
      switch self {
      case .throughput: "throughput"
      case .tailLatency: "tail latency"
      case .fanOut: "fan-out"
      case .failureIsolation: "failure isolation"
      case .resources: "resources"
      case .backpressure: "backpressure"
      case .tenX: "10×"
      }
    }

    /// Case-insensitive substrings that count as this dimension being named. Perf & scale bullets
    /// write the dimension as their own label ("throughput: …"), so a loose substring match is
    /// enough — this rule checks presence, not phrasing or placement.
    fileprivate var keywords: [String] {
      switch self {
      case .throughput: ["throughput"]
      case .tailLatency: ["tail latency", "tail-latency"]
      case .fanOut: ["fan-out", "fan out"]
      case .failureIsolation: ["failure isolation", "failure-isolation"]
      case .resources: ["resources", "resource accounting"]
      case .backpressure: ["backpressure"]
      case .tenX: ["10×", "10x"]
      }
    }
  }

  public static func check(
    document: DesignDocument, docPath: String, claims: [Claim]
  ) throws(ReportContractViolation) -> [Finding] {
    let claimsByID = Dictionary(
      claims.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    let evidenceSection = document.markdown.section(anchor: "evidence")

    var findings: [Finding] = []
    try findings.append(
      contentsOf: taggingFindings(
        section: evidenceSection, sectionName: "Evidence", docPath: docPath,
        claimsByID: claimsByID, requireSupported: false))
    try findings.append(
      contentsOf: taggingFindings(
        section: document.decision, sectionName: "Decision", docPath: docPath,
        claimsByID: claimsByID, requireSupported: true))
    try findings.append(
      contentsOf: taggingFindings(
        section: document.perfAndScale, sectionName: "Perf & scale", docPath: docPath,
        claimsByID: claimsByID, requireSupported: false))
    try findings.append(
      contentsOf: unverifiedCoverageFindings(
        sections: [evidenceSection, document.decision, document.perfAndScale],
        risks: document.risks, openQuestions: document.openQuestions, docPath: docPath))
    try findings.append(
      contentsOf: perfDimensionFindings(section: document.perfAndScale, docPath: docPath))
    return findings
  }

  // MARK: - Tagging and citation checks (Evidence, Decision, Perf & scale)

  private static func taggingFindings(
    section: MarkdownDocument.Section?, sectionName: String, docPath: String,
    claimsByID: [String: Claim], requireSupported: Bool
  ) throws(ReportContractViolation) -> [Finding] {
    guard let section else { return [] }
    var findings: [Finding] = []
    for bullet in section.bullets {
      let tags = realTags(in: bullet.text)
      guard !tags.isEmpty else {
        findings.append(
          try Finding(
            ruleID: "design-lint.untagged-bullet", severity: .major, file: docPath, line: nil,
            message: "\(sectionName) has an untagged bullet: \"\(bullet.text)\".",
            failureScenario: nil))
        continue
      }
      for tag in tags where tag != "UNVERIFIED" {
        guard let claim = claimsByID[tag] else {
          findings.append(
            try Finding(
              ruleID: "design-lint.unknown-claim", severity: .major, file: docPath, line: nil,
              message: "\(sectionName) cites \"\(tag)\", which isn't a captured claim.",
              failureScenario: nil))
          continue
        }
        guard requireSupported, claim.status != .supported else { continue }
        findings.append(
          try Finding(
            ruleID: "design-lint.citation-not-supported", severity: .major, file: docPath,
            line: nil,
            message:
              "\(sectionName) cites \"\(tag)\", which is \(claim.status.rawValue), not supported.",
            failureScenario: nil))
      }
    }
    return findings
  }

  // MARK: - [UNVERIFIED] coverage in Risks / Open questions

  /// Spec §5.3: "every `[UNVERIFIED]` bullet elsewhere appears here [Risks] or in Open questions."
  /// The mechanical check can't judge whether Risks prose actually addresses a given claim — that's
  /// the evidence-auditor's job — so it enforces the structural half: once the doc has any
  /// `[UNVERIFIED]` tag, Risks or Open questions must carry something back for it, not sit empty.
  private static func unverifiedCoverageFindings(
    sections: [MarkdownDocument.Section?], risks: MarkdownDocument.Section?,
    openQuestions: MarkdownDocument.Section?, docPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    let risksHasContent = !(risks?.bullets.isEmpty ?? true)
    let openQuestionsHasContent = !(openQuestions?.bullets.isEmpty ?? true)
    guard !risksHasContent, !openQuestionsHasContent else { return [] }

    var findings: [Finding] = []
    for section in sections.compactMap({ $0 }) {
      for bullet in section.bullets where realTags(in: bullet.text).contains("UNVERIFIED") {
        findings.append(
          try Finding(
            ruleID: "design-lint.unverified-uncovered", severity: .major, file: docPath, line: nil,
            message:
              "\"\(bullet.text)\" is tagged [UNVERIFIED] but neither Risks nor Open questions "
              + "has any bullets.",
            failureScenario: nil))
      }
    }
    return findings
  }

  // MARK: - Perf & scale's seven dimensions

  private static func perfDimensionFindings(
    section: MarkdownDocument.Section?, docPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    let haystack = (section?.bullets.map(\.text) ?? []).joined(separator: "\n").lowercased()
    var findings: [Finding] = []
    for dimension in PerfDimension.allCases {
      guard !dimension.keywords.contains(where: { haystack.contains($0.lowercased()) }) else {
        continue
      }
      findings.append(
        try Finding(
          ruleID: "design-lint.perf-missing-dimension", severity: .major, file: docPath, line: nil,
          message: "Perf & scale doesn't name \(dimension.displayName).", failureScenario: nil))
    }
    return findings
  }

  // MARK: - Inline-code-aware tag extraction

  /// Scans for `[...]` bracket tags the same way `MarkdownDocument`'s bullet parser does, except a
  /// bracket inside a backtick-delimited span is prose, not a citation — a bullet may show
  /// `` `[ev-example]` `` as literal syntax without citing it. `Bullet.tags` doesn't make this
  /// distinction (it scans the whole line for brackets), so this rule re-scans the raw bullet text.
  private static func realTags(in text: String) -> [String] {
    var tags: [String] = []
    var inInlineCode = false
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if character == "`" {
        inInlineCode.toggle()
        index = text.index(after: index)
      } else if character == "[", !inInlineCode, let close = text[index...].firstIndex(of: "]") {
        tags.append(String(text[text.index(after: index)..<close]))
        index = text.index(after: close)
      } else {
        index = text.index(after: index)
      }
    }
    return tags
  }
}
