/// `design-lint`'s diagram and prose-budget rules (spec §5.3, §6.2): the Architecture section
/// carries its Mermaid diagrams, and every section — plus the document as a whole — stays inside
/// its configured word budget. Every numeric limit comes from `DocsBudgets`; this file names none
/// of its own.
public enum DesignLintDiagrams {
  /// Mermaid diagram grammars `design-lint` recognises without running `mmdc`. A fence whose
  /// declaration falls outside this set — a typo, an invented type, an all-blank fence, or a `%%`
  /// comment standing in for the real declaration — is unknown. Full syntax validation still runs
  /// through `mmdc` when it's on `PATH` (spec §5.3); this check runs unconditionally.
  public static let knownMermaidDiagramTypes: Set<String> = [
    "flowchart", "graph", "sequenceDiagram", "classDiagram", "stateDiagram", "stateDiagram-v2",
    "erDiagram", "journey", "gantt", "pie", "quadrantChart", "requirementDiagram", "gitGraph",
    "mindmap", "timeline", "sankey-beta", "block-beta", "xychart-beta", "C4Context",
  ]

  private static let minimumArchitectureDiagrams = 2

  public static func check(
    document: DesignDocument, docPath: String, budgets: DocsBudgets
  ) throws(ReportContractViolation) -> [Finding] {
    var findings = try architectureDiagramFindings(document: document, docPath: docPath)
    try findings.append(
      contentsOf: sectionBudgetFindings(document: document, docPath: docPath, budgets: budgets))
    try findings.append(
      contentsOf: documentBudgetFinding(document: document, docPath: docPath, budgets: budgets))
    return findings
  }

  // MARK: - Architecture's Mermaid diagrams

  private static func architectureDiagramFindings(
    document: DesignDocument, docPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    let mermaidFences = (document.architecture?.fences ?? []).filter { $0.language == "mermaid" }
    var findings: [Finding] = []

    for fence in mermaidFences where !isKnownType(fence.mermaidDiagramType) {
      let named = fence.mermaidDiagramType.map { "\"\($0)\"" } ?? "none declared"
      findings.append(
        try Finding(
          ruleID: "design-lint.architecture-diagram-unknown-type", severity: .major,
          file: docPath, line: nil,
          message:
            "Architecture has a mermaid fence with an unrecognised diagram type (\(named)).",
          failureScenario: nil))
    }

    let knownDiagramCount = mermaidFences.filter { isKnownType($0.mermaidDiagramType) }.count
    if knownDiagramCount < minimumArchitectureDiagrams {
      findings.append(
        try Finding(
          ruleID: "design-lint.architecture-diagram-count", severity: .major, file: docPath,
          line: nil,
          message:
            "Architecture has \(knownDiagramCount) mermaid diagram(s) of a known type; "
            + "needs at least \(minimumArchitectureDiagrams).",
          failureScenario: nil))
    }
    return findings
  }

  private static func isKnownType(_ type: String?) -> Bool {
    guard let type, !type.isEmpty else { return false }
    return knownMermaidDiagramTypes.contains(type)
  }

  // MARK: - Prose word budgets

  /// Only a section named in `budgets.sections` is individually checked; an unnamed section is
  /// still bounded by `documentBudgetFinding` below. Walks every depth, not just the top level —
  /// a design doc's own `# Title` always wraps its `##` sections one level deeper, so a shallow
  /// scan would never reach them.
  private static func sectionBudgetFindings(
    document: DesignDocument, docPath: String, budgets: DocsBudgets
  ) throws(ReportContractViolation) -> [Finding] {
    try sectionBudgetFindings(
      sections: document.markdown.sections, docPath: docPath, budgets: budgets)
  }

  private static func sectionBudgetFindings(
    sections: [MarkdownDocument.Section], docPath: String, budgets: DocsBudgets
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    for section in sections {
      if let limit = budgets.sections[section.anchor], section.proseWordCount > limit {
        findings.append(
          try Finding(
            ruleID: "design-lint.section-word-budget", severity: .major, file: docPath, line: nil,
            message:
              "\"\(section.heading)\" is \(section.proseWordCount) prose words, "
              + "over its \(limit)-word budget.",
            failureScenario: nil))
      }
      try findings.append(
        contentsOf: sectionBudgetFindings(
          sections: section.subsections, docPath: docPath, budgets: budgets))
    }
    return findings
  }

  private static func documentBudgetFinding(
    document: DesignDocument, docPath: String, budgets: DocsBudgets
  ) throws(ReportContractViolation) -> [Finding] {
    let total = totalProseWords(document.markdown.sections)
    guard total > budgets.design else { return [] }
    return [
      try Finding(
        ruleID: "design-lint.document-word-budget", severity: .major, file: docPath, line: nil,
        message: "the design doc is \(total) prose words, over its \(budgets.design)-word budget.",
        failureScenario: nil)
    ]
  }

  private static func totalProseWords(_ sections: [MarkdownDocument.Section]) -> Int {
    sections.reduce(0) { $0 + $1.proseWordCount + totalProseWords($1.subsections) }
  }
}
