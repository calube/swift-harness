import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Sweeps the whole docs corpus once (`DocsTreeReader`), then runs both `docs-lint` rule families
/// over it: `DocsLintPolicy` (managed files, non-vacuity, banned phrases, budgets, local paths) and
/// `DocsLintReferences` (reference integrity, relative links, router reachability). A repository
/// with no `[docs]` table in `.swiftgate.toml` still runs — the generic families and their
/// defaults — but that's worth saying out loud rather than leaving silent.
enum DocsLintCheck {
  static let noDocsSectionRuleID = "docs-lint.no-docs-section"
  static let noDocsDirectoryRuleID = "docs-lint.no-docs-directory"
  private static let docsDirectoryName = "docs"

  static func run(root: URL, runner: any ProcessRunner) async -> StaticCheckOutcome {
    let docsConfig: DocsConfig
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let loaded): docsConfig = loaded?.docs ?? DocsConfig()
    case .failure(let failure): return failure.outcome
    }
    let hasDocsSection = hasDocsSection(root: root)

    let corpus: DocsTreeReader.Corpus
    do {
      corpus = try await DocsTreeReader(runner: runner).read(repositoryRoot: root)
    } catch {
      return .blocked(reason: "docs-lint: \(error)")
    }

    do throws(ReportContractViolation) {
      var findings = try DocsLintPolicy.check(documents: corpus.documents, config: docsConfig)
      findings += try DocsLintReferences.check(
        files: corpus.documents, claims: [], repoPaths: corpus.repoPaths)
      if !hasDocsSection {
        findings.append(
          try Finding(
            ruleID: noDocsSectionRuleID, severity: .minor, file: Config.fileName, line: nil,
            message:
              "no [docs] table in \(Config.fileName): docs-lint ran the generic families only, "
              + "with default budgets and no repo-specific anchors.",
            failureScenario: nil))
      }
      if !corpus.docsDirectoryExists {
        findings.append(
          try Finding(
            ruleID: noDocsDirectoryRuleID, severity: .minor, file: Self.docsDirectoryName,
            line: nil,
            message:
              "no docs/ directory: docs-lint scanned an empty docs corpus (root AGENTS.md only, "
              + "if present).",
            failureScenario: nil))
      }
      return .checked(RuleRunResult(findings: findings, allowances: []))
    } catch {
      return .blocked(reason: "docs-lint: \(error)")
    }
  }

  /// Whether `.swiftgate.toml` declares a `[docs]` table (bare or dotted, e.g.
  /// `[docs.budgets]`) — a line-level check, not a full TOML parse, because this only ever gates
  /// an advisory note (spec §6.2: a repo with none still gets the generic families and defaults).
  /// A missing or unreadable config file counts as "no section": ``StaticCheckInputs/loadConfig``
  /// already turns a malformed one into its own blocking or red outcome before this ever runs.
  private static func hasDocsSection(root: URL) -> Bool {
    let url = root.appending(path: Config.fileName, directoryHint: .notDirectory)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[["),
        let close = trimmed.firstIndex(of: "]")
      else { continue }
      let name = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
      if name == "docs" || name.hasPrefix("docs.") { return true }
    }
    return false
  }
}

struct DocsLintCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "docs-lint",
    abstract:
      "Lint docs/: reference integrity, relative links, router reachability, banned phrases and "
      + "per-file prose budgets.",
    discussion:
      "Reads docs/ and root AGENTS.md, and an optional [docs] table from .swiftgate.toml. Takes "
      + "no positional arguments. Exit 0 clean, 1 on a finding, 2 when the docs tree or git can't "
      + "be read.")

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    try await StaticCheckRun.execute(root: root, format: output.format) {
      await DocsLintCheck.run(root: root, runner: LiveProcessRunner())
    }
  }
}
