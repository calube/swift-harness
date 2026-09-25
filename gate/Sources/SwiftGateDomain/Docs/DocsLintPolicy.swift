/// `docs-lint`'s policy and budget families (spec §6.2): the ones that check a repo's own rules
/// against reality, rather than cross-referencing ids between docs (that's
/// `DocsLintReferences`'s job). Every finding here is `major`: the spec's `docs-lint` family table
/// calls each of these a violation, never an advisory warning — unlike `plan-lint`, which does have
/// warnings, `docs-lint` doesn't, so `minor` never appears in this file.
///
/// `check` sweeps a whole corpus in one pass (`docs-lint` takes no `<doc>` argument, unlike
/// `design-lint <doc>`): the caller — the FS adapter — reads every file docs-lint scans and hands
/// each one over as a ``ScannedDocument``.
public enum DocsLintPolicy {
  /// The harness's own product paths: binaries and caches it legitimately tells readers to look
  /// at, so ``LocalPathRule`` never flags them. No config key — letting a repo override this would
  /// let a real machine-specific path slip through disguised as "product".
  public static let productPaths: [String] = [
    "~/.swift-harness/",
    "~/.local/bin/swiftgate",
    "~/.cache/swift-harness/",
  ]

  /// One file `docs-lint` read off disk: its repository-relative path, raw text (for
  /// ``LocalPathRule`` and the banned-phrase scan, which work over untouched source text, not a
  /// parsed tree) and parsed structure (for word counts and anchors).
  ///
  /// This is the one corpus type `docs-lint` reads the whole docs tree into: ``DocsLintReferences``
  /// reads the same type rather than defining its own, and `docs-lint-command`'s `DocsTreeReader`
  /// adapter is the one place that builds it from the filesystem.
  public struct ScannedDocument: Sendable, Equatable {
    public let path: String
    public let rawText: String
    public let markdown: MarkdownDocument

    public init(path: String, rawText: String, markdown: MarkdownDocument) {
      self.path = path
      self.rawText = rawText
      self.markdown = markdown
    }
  }

  public static func check(
    documents: [ScannedDocument], config: DocsConfig
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    try findings.append(contentsOf: managedFileFindings(documents: documents, config: config))
    try findings.append(contentsOf: anchorVacuityFindings(documents: documents, config: config))
    for document in documents {
      try findings.append(contentsOf: bannedPhraseFindings(document: document, config: config))
      try findings.append(contentsOf: budgetFindings(document: document, config: config))
      findings.append(contentsOf: localPathFindings(document: document))
    }
    return findings
  }

  // MARK: - Managed files (both directions)

  /// `managed_files` is a small, explicit whitelist (routers, the `AGENTS.md` pointer) — not every
  /// doc in the repo — so the two directions check different things: a declared entry must exist
  /// anywhere among the scanned files, and a router or `AGENTS.md` that exists must be declared.
  /// The second direction is what catches the file `bootstrap` stamps for a new area router but
  /// config never learns about.
  private static func managedFileFindings(
    documents: [ScannedDocument], config: DocsConfig
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    let existingPaths = Set(documents.map(\.path))
    for declared in config.managedFiles.sorted() where !existingPaths.contains(declared) {
      findings.append(
        try Finding(
          ruleID: "docs-lint.managed-file-missing", severity: .major, file: Config.fileName,
          line: nil,
          message: "[docs] managed_files lists \"\(declared)\", which wasn't found.",
          failureScenario: nil))
    }

    let declaredSet = Set(config.managedFiles)
    let managedCandidates = documents.map(\.path).filter { isRouter($0) || isAgentsFile($0) }
    for candidate in managedCandidates.sorted() where !declaredSet.contains(candidate) {
      findings.append(
        try Finding(
          ruleID: "docs-lint.managed-file-unlisted", severity: .major, file: candidate, line: nil,
          message:
            "\(candidate) is a router or pointer file but isn't listed in [docs] managed_files.",
          failureScenario: nil))
    }
    return findings
  }

  // MARK: - Non-vacuity: repo-specific anchors

  /// A repo's `[docs] anchors` names extra anchors `docs-lint` should accept as known-good beyond
  /// the ids it already tracks. An entry that matches no heading anywhere in the scanned corpus
  /// can't be doing that job — it's dead config, silently protecting nothing (spec: "an anchor or
  /// rule that matches nothing fails").
  private static func anchorVacuityFindings(
    documents: [ScannedDocument], config: DocsConfig
  ) throws(ReportContractViolation) -> [Finding] {
    let knownAnchors = Set(documents.flatMap { allAnchors($0.markdown.sections) })
    var findings: [Finding] = []
    for anchor in config.anchors.sorted() where !knownAnchors.contains(anchor) {
      findings.append(
        try Finding(
          ruleID: "docs-lint.anchor-vacuous", severity: .major, file: Config.fileName, line: nil,
          message:
            "[docs] anchors lists \"\(anchor)\", which matches no heading in any scanned doc.",
          failureScenario: nil))
    }
    return findings
  }

  private static func allAnchors(_ sections: [MarkdownDocument.Section]) -> [String] {
    sections.flatMap { [$0.anchor] + allAnchors($0.subsections) }
  }

  // MARK: - Banned phrases

  /// `BannedPhrase.reason` is never empty by the time one reaches here: `ConfigSchema` requires it
  /// at parse time and `Config`'s own invariants require it again for a hand-built `Config`
  /// (`DocsPlanConfigTests.bannedPhraseWithoutReasonRejected` proves the parse-time half), so this
  /// rule never has to guard against a reasonless ban — a "config error, not a silent pass" one
  /// layer down, not this one.
  private static func bannedPhraseFindings(
    document: ScannedDocument, config: DocsConfig
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    for banned in config.bannedPhrases {
      guard let line = firstLine(containing: banned.phrase, in: document.rawText) else { continue }
      findings.append(
        try Finding(
          ruleID: "docs-lint.banned-phrase", severity: .major, file: document.path, line: line,
          message: "\"\(banned.phrase)\" is banned: \(banned.reason)", failureScenario: nil))
    }
    return findings
  }

  /// 1-based line of the phrase's first occurrence; `nil` when it appears nowhere (including a
  /// phrase that only exists by spanning a line break, which this rule doesn't chase).
  private static func firstLine(containing phrase: String, in text: String) -> Int? {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last == "" { lines.removeLast() }
    for (index, line) in lines.enumerated() where line.contains(phrase) { return index + 1 }
    return nil
  }

  // MARK: - Budgets

  /// Whole-file budgets only: per-section budgets (`[docs.budgets.sections]`, e.g. Architecture's
  /// 80 words) are `design-lint`'s job against a parsed `DesignDocument` — `docs-lint` never
  /// re-applies them to an arbitrary doc's same-named heading. A router doc with its own
  /// "Architecture" section, for instance, is bounded only by the router budget as a whole, never
  /// individually. Design docs are excluded outright: `design-lint` already checks their whole-doc
  /// and per-section budgets against `budgets.design`, so charging them a `docs-lint` topic budget
  /// too would double-govern the same prose under two different limits.
  private static func budgetFindings(
    document: ScannedDocument, config: DocsConfig
  ) throws(ReportContractViolation) -> [Finding] {
    if isAgentsFile(document.path) {
      let lineCount = lineCount(of: document.rawText)
      guard lineCount > config.budgets.agentsMdLines else { return [] }
      return [
        try Finding(
          ruleID: "docs-lint.agents-md-line-budget", severity: .major, file: document.path,
          line: nil,
          message:
            "\(document.path) is \(lineCount) lines, over its "
            + "\(config.budgets.agentsMdLines)-line budget.",
          failureScenario: nil)
      ]
    }
    guard !DesignDocument.isDesignDocPath(document.path) else { return [] }

    let words = totalProseWords(document.markdown.sections)
    if isRouter(document.path) {
      guard words > config.budgets.router else { return [] }
      return [
        try Finding(
          ruleID: "docs-lint.router-word-budget", severity: .major, file: document.path, line: nil,
          message:
            "\(document.path) is \(words) prose words, over its "
            + "\(config.budgets.router)-word router budget.",
          failureScenario: nil)
      ]
    }
    guard words > config.budgets.topic else { return [] }
    return [
      try Finding(
        ruleID: "docs-lint.topic-word-budget", severity: .major, file: document.path, line: nil,
        message:
          "\(document.path) is \(words) prose words, over its "
          + "\(config.budgets.topic)-word topic budget.",
        failureScenario: nil)
    ]
  }

  private static func totalProseWords(_ sections: [MarkdownDocument.Section]) -> Int {
    sections.reduce(0) { $0 + $1.proseWordCount + totalProseWords($1.subsections) }
  }

  private static func lineCount(of text: String) -> Int {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last == "" { lines.removeLast() }
    return lines.count
  }

  // MARK: - Local paths

  private static func localPathFindings(document: ScannedDocument) -> [Finding] {
    LocalPathRule.scan(document.rawText, file: document.path)
  }

  // MARK: - Doc classification

  private static func isRouter(_ path: String) -> Bool {
    let components = path.split(separator: "/")
    return components.first == "docs" && components.last == "index.md"
  }

  private static func isAgentsFile(_ path: String) -> Bool {
    path == "AGENTS.md"
  }
}
