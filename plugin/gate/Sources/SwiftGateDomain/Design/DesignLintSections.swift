import Foundation

/// `design-lint`'s section-structure and id rules (spec §5.3, id form §5.1): every design doc
/// carries the same section skeleton in the same order, its Problem statement isn't blank, its
/// `req-`/`test-` ids are well-formed and unique across the repo (not just this doc), every test
/// plan item names a tier, Options carries 2–3 entries, and every Module kinds row names a kind
/// the standards model recognises.
///
/// This file parses nothing itself — every accessor, including the required section list and
/// order, comes from ``DesignDocument``: ``DesignDocument/RequiredSection`` is the single source
/// of truth for spec §5.3's section anchors, shared with the parser's own per-field lookups.
///
/// Ids defined by every *other* design in the repo are an input, not something this pure check
/// reads off disk: the caller collects `otherDesignIds` (every `req-`/`test-` id parsed from every
/// other `docs/**/designs/*.md`) and passes it in. An id merely referenced in this doc's prose
/// never enters this set or `document.requirements`/`document.testPlan`, so citing another
/// design's id is never mistaken for redefining it.
public enum DesignLintSections {
  private static let minimumOptions = 2
  private static let maximumOptions = 3
  /// spec §5.1: `req-`/`test-` ids are the prefix plus at least this many kebab words.
  private static let minimumIDWords = 3
  /// spec §5.3's Test plan by tier only ever names T1–T3; T0 is static checks, not a test.
  private static let validTestTiers: Set<Tier> = [.t1, .t2, .t3]

  public static func check(
    document: DesignDocument, docPath: String, otherDesignIds: Set<String> = []
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    try findings.append(contentsOf: sectionStructureFindings(document: document, docPath: docPath))
    try findings.append(contentsOf: problemFindings(document: document, docPath: docPath))
    try findings.append(
      contentsOf: idFindings(document: document, docPath: docPath, otherDesignIds: otherDesignIds))
    try findings.append(contentsOf: testTierFindings(document: document, docPath: docPath))
    try findings.append(contentsOf: optionsCountFindings(document: document, docPath: docPath))
    try findings.append(contentsOf: moduleKindFindings(document: document, docPath: docPath))
    return findings
  }

  // MARK: - Section presence and order

  private static func sectionStructureFindings(
    document: DesignDocument, docPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    for section in DesignDocument.RequiredSection.allCases
    where document.markdown.section(anchor: section.anchor) == nil {
      findings.append(
        try Finding(
          ruleID: "design-lint.section-missing", severity: .major, file: docPath, line: nil,
          message: "\"\(section.name)\" section is missing (spec §5.3).", failureScenario: nil))
    }

    let requiredAnchors = Set(DesignDocument.RequiredSection.allCases.map(\.anchor))
    let docOrder = flatten(document.markdown.sections).map(\.anchor)
    let presentAnchors = Set(docOrder)
    let actualOrder = docOrder.filter { requiredAnchors.contains($0) }
    let expectedOrder = DesignDocument.RequiredSection.allCases.map(\.anchor).filter {
      presentAnchors.contains($0)
    }
    if actualOrder != expectedOrder {
      findings.append(
        try Finding(
          ruleID: "design-lint.section-order", severity: .major, file: docPath, line: nil,
          message:
            "design sections are out of §5.3 order: expected "
            + "\(expectedOrder.joined(separator: ", ")); got \(actualOrder.joined(separator: ", ")).",
          failureScenario: nil))
    }
    return findings
  }

  /// Pre-order walk of the whole section tree, in document order — required sections live at
  /// whatever depth the doc's own `#` title puts them at, and a fence-nested heading-shaped line
  /// never enters this tree at all (``MarkdownDocument`` skips it at the heading scan).
  private static func flatten(_ sections: [MarkdownDocument.Section]) -> [MarkdownDocument.Section]
  {
    sections.flatMap { [$0] + flatten($0.subsections) }
  }

  // MARK: - Problem non-empty

  private static func problemFindings(
    document: DesignDocument, docPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    // A missing Problem section is already a `section-missing` finding above.
    guard let problem = document.problem, problem.proseWordCount == 0 else { return [] }
    return [
      try Finding(
        ruleID: "design-lint.problem-empty", severity: .major, file: docPath, line: nil,
        message: "\"Problem\" section is present but has no prose (spec §5.3).",
        failureScenario: nil)
    ]
  }

  // MARK: - Requirement and test-plan ids: D18 form and repo-uniqueness

  private static func idFindings(
    document: DesignDocument, docPath: String, otherDesignIds: Set<String>
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    let requirementIDs = document.requirements.map(\.id)
    let testIDs = document.testPlan.map(\.id)

    try findings.append(
      contentsOf: formFindings(
        ids: requirementIDs, prefix: "req-", ruleID: "design-lint.requirement-id-form",
        docPath: docPath))
    try findings.append(
      contentsOf: formFindings(
        ids: testIDs, prefix: "test-", ruleID: "design-lint.test-id-form", docPath: docPath))
    try findings.append(
      contentsOf: duplicateFindings(
        ids: requirementIDs, otherDesignIds: otherDesignIds,
        ruleID: "design-lint.requirement-id-duplicate", docPath: docPath))
    try findings.append(
      contentsOf: duplicateFindings(
        ids: testIDs, otherDesignIds: otherDesignIds, ruleID: "design-lint.test-id-duplicate",
        docPath: docPath))
    return findings
  }

  private static func formFindings(
    ids: [String], prefix: String, ruleID: String, docPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    for id in ids where !isD18Form(id, prefix: prefix) {
      findings.append(
        try Finding(
          ruleID: ruleID, severity: .major, file: docPath, line: nil,
          message:
            "id \"\(id)\" isn't \"\(prefix)\" plus \(minimumIDWords)+ kebab words (spec §5.1).",
          failureScenario: nil))
    }
    return findings
  }

  private static func isD18Form(_ id: String, prefix: String) -> Bool {
    guard id.hasPrefix(prefix) else { return false }
    let words = id.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: true)
    return words.count >= minimumIDWords
  }

  /// An id is flagged when it's defined more than once anywhere in the repo — including twice in
  /// this same doc — because spec §5.1 makes ids unique across the repo, not per design. `ids`
  /// only ever holds ids this doc *defines* (``DesignDocument`` parses them from the Requirements
  /// / Test plan bullet prefix only), so a bare mention elsewhere in the doc's prose never reaches
  /// this check.
  private static func duplicateFindings(
    ids: [String], otherDesignIds: Set<String>, ruleID: String, docPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    var countInThisDoc: [String: Int] = [:]
    for id in ids { countInThisDoc[id, default: 0] += 1 }

    var findings: [Finding] = []
    var reported = Set<String>()
    for id in ids where !reported.contains(id) {
      guard (countInThisDoc[id] ?? 0) > 1 || otherDesignIds.contains(id) else { continue }
      reported.insert(id)
      findings.append(
        try Finding(
          ruleID: ruleID, severity: .major, file: docPath, line: nil,
          message:
            "id \"\(id)\" is defined more than once; ids are unique across the repo, "
            + "not per design (spec §5.1).",
          failureScenario: nil))
    }
    return findings
  }

  // MARK: - Test plan tiers

  private static func testTierFindings(
    document: DesignDocument, docPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    for item in document.testPlan where !isValidTestTier(item.tier) {
      let message =
        item.tier.isEmpty
        ? "test item \"\(item.id)\" names no tier (spec §5.3 requires \" — tier T1/T2/T3\")."
        : "test item \"\(item.id)\" names an unrecognised tier \"\(item.tier)\" "
          + "(must be T1, T2 or T3)."
      findings.append(
        try Finding(
          ruleID: "design-lint.test-tier-invalid", severity: .major, file: docPath, line: nil,
          message: message, failureScenario: nil))
    }
    return findings
  }

  private static func isValidTestTier(_ raw: String) -> Bool {
    guard let tier = Tier(rawValue: raw) else { return false }
    return validTestTiers.contains(tier)
  }

  // MARK: - Options count

  private static func optionsCountFindings(
    document: DesignDocument, docPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    // A missing Options section is already a `section-missing` finding above.
    guard document.markdown.section(anchor: DesignDocument.RequiredSection.options.anchor) != nil
    else { return [] }
    let count = document.options.count
    guard count < minimumOptions || count > maximumOptions else { return [] }
    return [
      try Finding(
        ruleID: "design-lint.options-count", severity: .major, file: docPath, line: nil,
        message:
          "Options has \(count) option(s); spec §5.3 requires \(minimumOptions)–\(maximumOptions).",
        failureScenario: nil)
    ]
  }

  // MARK: - Module kinds

  private static func moduleKindFindings(
    document: DesignDocument, docPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    guard let table = document.moduleKinds,
      let kindColumn = table.header.firstIndex(where: {
        $0.caseInsensitiveCompare("kind") == .orderedSame
      })
    else { return [] }

    var findings: [Finding] = []
    for row in table.rows where row.indices.contains(kindColumn) {
      let raw = row[kindColumn].trimmingCharacters(in: .whitespaces)
      guard ModuleKind(rawValue: raw) == nil else { continue }
      let moduleName = row.first ?? raw
      findings.append(
        try Finding(
          ruleID: "design-lint.module-kind-unknown", severity: .major, file: docPath, line: nil,
          message:
            "\(moduleName) names an unrecognised module kind \"\(raw)\" (standards model §2).",
          failureScenario: nil))
    }
    return findings
  }
}
