import Foundation

/// `design-lint`'s evidence-tagging rules (spec §5.3, §11, D5): every Evidence, Decision and Perf
/// & scale bullet carries a citation tag; a Decision's cited claim must be `supported` and may
/// never be tagged `[UNVERIFIED]`; an `[UNVERIFIED]` tag anywhere in those three sections must be
/// restated in Risks or Open questions; and Perf & scale names all seven dimensions. `claims` is
/// the design's `claims.jsonl`, loaded by the caller — this type does no IO of its own.
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
    let claimsByID = Dictionary(grouping: claims, by: \.id)
    let (tier, tierFinding) = try parsedTier(document.tier, docPath: docPath)
    // Spec §9: at `sketch`, no research lane checked the doc's claims, so a Decision bullet may
    // stay `[UNVERIFIED]` and skip the Risks/Open-questions mirror. Every other tagging and
    // citation rule — including a Decision citing a claim that isn't `supported` — is unchanged.
    let sketchRelaxesDecision = tier == .sketch
    let taggedSections:
      [(
        name: String, section: MarkdownDocument.Section?, requireSupported: Bool,
        forbidUnverified: Bool
      )] = [
        ("Evidence", document.markdown.section(anchor: "evidence"), false, false),
        ("Decision", document.decision, true, !sketchRelaxesDecision),
        ("Perf & scale", document.perfAndScale, false, false),
      ]

    var findings = try duplicateClaimFindings(claimsByID: claimsByID, docPath: docPath)
    if let tierFinding { findings.append(tierFinding) }
    for entry in taggedSections {
      try findings.append(
        contentsOf: taggingFindings(
          section: entry.section, sectionName: entry.name, docPath: docPath,
          claimsByID: claimsByID, requireSupported: entry.requireSupported,
          forbidUnverified: entry.forbidUnverified))
    }
    try findings.append(
      contentsOf: unverifiedCoverageFindings(
        sections:
          taggedSections
          .filter { !(sketchRelaxesDecision && $0.name == "Decision") }
          .map { (name: $0.name, section: $0.section) },
        risks: document.risks, openQuestions: document.openQuestions, docPath: docPath))
    try findings.append(
      contentsOf: perfDimensionFindings(section: document.perfAndScale, docPath: docPath))
    return findings
  }

  /// The frontmatter `tier` string, closed against ``DesignTier``. A value the doc names that
  /// isn't one of the tier's known raw values is a finding, not a crash or a silent no-tier read —
  /// an unrecognised tier must never be mistaken for `sketch`'s relaxed rules.
  private static func parsedTier(
    _ raw: String?, docPath: String
  ) throws(ReportContractViolation) -> (DesignTier?, Finding?) {
    guard let raw else { return (nil, nil) }
    guard let tier = DesignTier(rawValue: raw) else {
      let finding = try Finding(
        ruleID: "design-lint.unknown-tier", severity: .major, file: docPath, line: nil,
        message:
          "frontmatter tier \"\(raw)\" is not a known design tier ("
          + DesignTier.allCases.map(\.rawValue).joined(separator: ", ") + ").",
        failureScenario: nil)
      return (nil, finding)
    }
    return (tier, nil)
  }

  // MARK: - Tagging and citation checks (Evidence, Decision, Perf & scale)

  private static func taggingFindings(
    section: MarkdownDocument.Section?, sectionName: String, docPath: String,
    claimsByID: [String: [Claim]], requireSupported: Bool, forbidUnverified: Bool
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
      // Spec §11: a claim that can't be pinned down ends `refuted` or `[UNVERIFIED]`, "never in
      // Decision" — so Decision forbids the tag outright rather than treating it as satisfying
      // "each tagged." (Spec §9: `sketch` lifts this one rule for Decision.)
      if forbidUnverified, tags.contains("UNVERIFIED") {
        findings.append(
          try Finding(
            ruleID: "design-lint.unverified-in-decision", severity: .major, file: docPath,
            line: nil,
            message:
              "Decision has an [UNVERIFIED] bullet: \"\(bullet.text)\". "
              + "An unverified claim must never back a decision.",
            failureScenario: nil))
      }
      for tag in tags where tag != "UNVERIFIED" {
        guard let recorded = claimsByID[tag], !recorded.isEmpty else {
          findings.append(
            try Finding(
              ruleID: "design-lint.unknown-claim", severity: .major, file: docPath, line: nil,
              message: "\(sectionName) cites \"\(tag)\", which isn't a captured claim.",
              failureScenario: nil))
          continue
        }
        // Every record of a repeated id must be supported: trusting whichever line came last
        // would let an appended `supported` record hide a `refuted` one.
        let unsupported = recorded.map(\.status).filter { $0 != .supported }
        guard requireSupported, let status = unsupported.first else { continue }
        findings.append(
          try Finding(
            ruleID: "design-lint.citation-not-supported", severity: .major, file: docPath,
            line: nil,
            message:
              "\(sectionName) cites \"\(tag)\", which is \(status.rawValue), not supported.",
            failureScenario: nil))
      }
    }
    return findings
  }

  // MARK: - Repeated claim ids

  /// A claim id is the key every citation resolves through (spec §5.1), so two records under one
  /// id leave a citation with no single answer. The finding names every status recorded; no
  /// record is chosen over another.
  private static func duplicateClaimFindings(
    claimsByID: [String: [Claim]], docPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    for id in claimsByID.keys.sorted() {
      guard let recorded = claimsByID[id], recorded.count > 1 else { continue }
      let statuses = recorded.map(\.status.rawValue).joined(separator: ", ")
      findings.append(
        try Finding(
          ruleID: "design-lint.claim-id-duplicate", severity: .major, file: docPath, line: nil,
          message:
            "claims.jsonl records \"\(id)\" \(recorded.count) times (\(statuses)); a claim id "
            + "names exactly one claim.",
          failureScenario: nil))
    }
    return findings
  }

  // MARK: - [UNVERIFIED] coverage in Risks / Open questions

  /// Spec §5.3: "every `[UNVERIFIED]` bullet elsewhere appears here [Risks] or in Open questions."
  /// "Appears" is made mechanical: after stripping citation tags, collapsing whitespace, folding
  /// case and dropping a trailing period, the unverified bullet's text must be a substring of some
  /// Risks or Open-questions bullet — a verbatim restatement, optionally wrapped in more context,
  /// never a paraphrase the checker would have to judge.
  private static func unverifiedCoverageFindings(
    sections: [(name: String, section: MarkdownDocument.Section?)],
    risks: MarkdownDocument.Section?, openQuestions: MarkdownDocument.Section?, docPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    let coverage = ((risks?.bullets ?? []) + (openQuestions?.bullets ?? []))
      .map { normalizedForCoverageMatch($0.text) }

    var findings: [Finding] = []
    for entry in sections {
      guard let section = entry.section else { continue }
      for bullet in section.bullets where realTags(in: bullet.text).contains("UNVERIFIED") {
        let normalized = normalizedForCoverageMatch(bullet.text)
        guard !coverage.contains(where: { $0.contains(normalized) }) else { continue }
        findings.append(
          try Finding(
            ruleID: "design-lint.unverified-uncovered", severity: .major, file: docPath, line: nil,
            message:
              "\(entry.name)'s \"\(bullet.text)\" is tagged [UNVERIFIED] but isn't restated in "
              + "Risks or Open questions.",
            failureScenario: nil))
      }
    }
    return findings
  }

  /// Strips `[UNVERIFIED]`/`[ev-…]` tags, collapses whitespace runs to a single space, drops one
  /// trailing period, trims, and lower-cases — the shared normal form both sides of the coverage match
  /// compare in.
  private static func normalizedForCoverageMatch(_ text: String) -> String {
    var stripped = ""
    var index = text.startIndex
    while index < text.endIndex {
      if text[index] == "[", let close = text[index...].firstIndex(of: "]") {
        let inner = text[text.index(after: index)..<close]
        if inner == "UNVERIFIED" || inner.hasPrefix("ev-") {
          index = text.index(after: close)
          continue
        }
      }
      stripped.append(text[index])
      index = text.index(after: index)
    }
    var collapsed = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if collapsed.hasSuffix(".") { collapsed.removeLast() }
    // A tag stripped from just before the final period leaves a space in front of it.
    return collapsed.trimmingCharacters(in: .whitespaces).lowercased()
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
