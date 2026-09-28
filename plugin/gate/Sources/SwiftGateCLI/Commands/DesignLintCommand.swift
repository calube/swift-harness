import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Runs every `design-lint` rule family — sections and ids, evidence tags, diagrams and budgets —
/// plus `prose`, over one design doc, in a single pass (spec §5.3, §6.2). Nothing here
/// re-implements a rule: each family's own `check(...)` in `SwiftGateDomain` is the sole source of
/// its findings. This file's own job is assembling that family's inputs (the doc, its
/// `claims.jsonl`, repo-wide ids, `mmdc` availability) and the two checks no existing family owns:
/// a parsed `.unknown` status, and a `claims.jsonl` that's missing despite tagged bullets.
enum DesignLintCheck {
  static func run(root: URL, docPath: String, git: any Git, processRunner: any ProcessRunner) async
    -> StaticCheckOutcome
  {
    let text: String
    switch readText(docPath, root: root) {
    case .failure(let failure): return .blocked(reason: failure.reason)
    case .success(let value): text = value
    }

    let config: Config?
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let loaded): config = loaded
    case .failure(let failure): return failure.outcome
    }

    let document = DesignDocument(markdown: MarkdownDocument.parse(text))
    let evidenceLayout = EvidenceLayout(designDocPath: docPath)
    let claimsLoaded = DesignLintClaims.load(
      claimsFileURL: resolve(evidenceLayout.claimsFile, in: root))

    let knownIds = await KnownIdSources.load(root: root, git: git)
    let otherDesignSources = idsDefinedElsewhere(
      designDocIds(root: root), linted: resolve(docPath, in: root), root: root)

    let fences = mermaidFences(in: document)
    let mermaidOutcome = await MermaidValidation.validate(
      fences: fences.map { (heading: $0.heading, index: $0.index, source: $0.source) },
      runner: processRunner)

    do throws(ReportContractViolation) {
      let findings = try allFindings(
        document: document, docPath: docPath, rawText: text, claimsLoaded: claimsLoaded,
        otherDesignSources: otherDesignSources, budgets: config?.docs.budgets ?? DocsBudgets(),
        sentenceCeiling: config?.docs.sentenceCeiling ?? DocsConfig.defaultSentenceCeiling,
        mermaidOutcome: mermaidOutcome, hasMermaidFences: !fences.isEmpty)
      let outcome = StaticCheckOutcome.checked(RuleRunResult(findings: findings, allowances: []))
      return KnownIdSourceFindings.appending(knownIds.unreadable, to: outcome)
    } catch {
      return .blocked(reason: "design-lint: \(error)")
    }
  }

  // MARK: - Ids other designs define

  /// The `req-`/`test-` ids each design doc under `docs/` defines, keyed by repo-relative path.
  /// A doc that can't be read is left out here without a note of its own: ``KnownIdSources``
  /// reads the same docs and already reports each unreadable one as a finding.
  private static func designDocIds(root: URL) -> [String: [String]] {
    var result: [String: [String]] = [:]
    let paths = RepositoryFiles.list(
      root: root, under: "docs", where: DesignDocument.isDesignDocPath)
    for path in paths {
      guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8)
      else { continue }
      let design = DesignDocument(markdown: MarkdownDocument.parse(text))
      result[path] = design.requirements.map(\.id) + design.testPlan.map(\.id)
    }
    return result
  }

  /// Every `req-`/`test-` id a design doc other than the linted one defines, mapped to the first
  /// such doc by path. Only the linted doc's own entry is set aside, by file identity rather than
  /// by id: subtracting its ids from the repo-wide set would also erase the very ids another doc
  /// shares with it, which are the duplicates spec §5.1 forbids.
  private static func idsDefinedElsewhere(
    _ idsByPath: [String: [String]], linted: URL, root: URL
  ) -> [String: String] {
    let lintedIdentity = identity(of: linted)
    var result: [String: String] = [:]
    for path in idsByPath.keys.sorted()
    where identity(of: resolve(path, in: root)) != lintedIdentity {
      for id in idsByPath[path] ?? [] where result[id] == nil { result[id] = path }
    }
    return result
  }

  private static func identity(of url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  // MARK: - Combining every rule family

  private static func allFindings(
    document: DesignDocument, docPath: String, rawText: String,
    claimsLoaded: DesignLintClaims.Loaded, otherDesignSources: [String: String],
    budgets: DocsBudgets,
    sentenceCeiling: Int, mermaidOutcome: MermaidValidation.Outcome, hasMermaidFences: Bool
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    findings += try DesignLintSections.check(
      document: document, docPath: docPath, otherDesignIds: Set(otherDesignSources.keys),
      otherDesignSources: otherDesignSources)
    findings += try DesignLintEvidence.check(
      document: document, docPath: docPath, claims: claimsLoaded.claims ?? [])
    findings += try DesignLintDiagrams.check(document: document, docPath: docPath, budgets: budgets)
    findings += try ProseRules.check(
      rawText, file: docPath, sentenceCeiling: sentenceCeiling)
    findings += try statusFindings(document: document, docPath: docPath)
    findings += try claimsFileFindings(
      document: document, docPath: docPath, claimsLoaded: claimsLoaded)
    findings += try mermaidFindings(
      mermaidOutcome, hasMermaidFences: hasMermaidFences, docPath: docPath)
    return findings
  }

  // MARK: - Frontmatter status

  /// Not one of spec §5.4's four transitions: a status the doc claims that `DesignDocument` can't
  /// place, so it's surfaced rather than silently read as "not yet approved."
  private static func statusFindings(document: DesignDocument, docPath: String)
    throws(ReportContractViolation) -> [Finding]
  {
    guard case .unknown(let raw) = document.status else { return [] }
    return [
      try Finding(
        ruleID: DesignLintRule.statusUnknown.rawValue, severity: .major, file: docPath, line: nil,
        message:
          "frontmatter status \"\(raw)\" is none of proposed, approved, built or "
          + "superseded-by: <slug> (spec §5.4).",
        failureScenario: nil)
    ]
  }

  // MARK: - A missing claims.jsonl despite tagged bullets

  private static func claimsFileFindings(
    document: DesignDocument, docPath: String, claimsLoaded: DesignLintClaims.Loaded
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    if claimsLoaded.claims == nil, hasTaggedBullets(document) {
      findings.append(
        try Finding(
          ruleID: DesignLintRule.claimsFileMissing.rawValue, severity: .major, file: docPath,
          line: nil,
          message:
            "the design tags Evidence, Decision or Perf & scale bullets, but its claims.jsonl "
            + "doesn't exist; every tag will read as citing an unknown claim.",
          failureScenario: nil))
    }
    if claimsLoaded.invalidLineCount > 0 {
      findings.append(
        try Finding(
          ruleID: DesignLintRule.claimsFileUnreadableLines.rawValue, severity: .minor,
          file: docPath,
          line: nil,
          message:
            "\(claimsLoaded.invalidLineCount) line(s) of claims.jsonl didn't parse as a claim "
            + "and were skipped.",
          failureScenario: nil))
    }
    return findings
  }

  private static func hasTaggedBullets(_ document: DesignDocument) -> Bool {
    let taggedSections = [
      document.markdown.section(anchor: "evidence"), document.decision, document.perfAndScale,
    ]
    return taggedSections.contains { section in
      guard let section else { return false }
      return section.bullets.contains { bullet in
        bullet.tags.contains { $0 == "UNVERIFIED" || $0.hasPrefix("ev-") }
      }
    }
  }

  // MARK: - Mermaid syntax (mmdc)

  private static func mermaidFindings(
    _ outcome: MermaidValidation.Outcome, hasMermaidFences: Bool, docPath: String
  ) throws(ReportContractViolation) -> [Finding] {
    switch outcome {
    case .notOnPath:
      guard hasMermaidFences else { return [] }
      return [
        try Finding(
          ruleID: DesignLintRule.mmdcUnavailable.rawValue, severity: .minor, file: docPath,
          line: nil,
          message:
            "mmdc is not on PATH: mermaid fences were checked for a known diagram type but not "
            + "validated for syntax (spec §5.3).",
          failureScenario: nil)
      ]
    case .validated(let failures):
      var findings: [Finding] = []
      for failure in failures {
        findings.append(
          try Finding(
            ruleID: DesignLintRule.mermaidSyntax.rawValue, severity: .major, file: docPath,
            line: nil,
            message:
              "\(failure.heading)'s mermaid fence #\(failure.index + 1) failed mmdc validation: "
              + "\(failure.diagnostic)",
            failureScenario: nil))
      }
      return findings
    }
  }

  /// Every `mermaid`-language fence in document order, tagged with its own section heading and
  /// its position among that heading's mermaid fences (spec §5.3: Architecture and Options may
  /// each carry one).
  private static func mermaidFences(in document: DesignDocument)
    -> [(heading: String, index: Int, source: String)]
  {
    var result: [(heading: String, index: Int, source: String)] = []
    func walk(_ sections: [MarkdownDocument.Section]) {
      for section in sections {
        var index = 0
        for fence in section.fences where fence.language == "mermaid" {
          result.append((section.heading, index, fence.body.joined(separator: "\n")))
          index += 1
        }
        walk(section.subsections)
      }
    }
    walk(document.markdown.sections)
    return result
  }

  // MARK: - Reading the doc

  private struct ReadFailure: Error {
    let reason: String
  }

  private static func readText(_ docPath: String, root: URL) -> Result<String, ReadFailure> {
    let url = resolve(docPath, in: root)
    do {
      return .success(try String(contentsOf: url, encoding: .utf8))
    } catch {
      return .failure(
        ReadFailure(reason: "design-lint: can't read \(docPath): \(error.localizedDescription)"))
    }
  }

  private static func resolve(_ path: String, in root: URL) -> URL {
    path.hasPrefix("/")
      ? URL(filePath: path) : root.appending(path: path, directoryHint: .notDirectory)
  }
}

struct DesignLintCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design-lint",
    abstract:
      "Lint a design doc against spec §5.3: cited ids, evidence tags, sections and diagrams.",
    discussion:
      "Runs sections-and-ids, evidence tags, diagrams-and-budgets and prose over the doc in one "
      + "pass. Validates every mermaid fence with mmdc when it's on PATH; otherwise notes the gap "
      + "without blocking. Exit 0 clean, 1 on a finding, 2 when the doc can't be read.")

  @Argument(help: "The design doc to lint.")
  var doc: String

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    try await StaticCheckRun.execute(root: root, format: output.format) {
      await DesignLintCheck.run(
        root: root, docPath: doc, git: git, processRunner: LiveProcessRunner())
    }
  }
}
