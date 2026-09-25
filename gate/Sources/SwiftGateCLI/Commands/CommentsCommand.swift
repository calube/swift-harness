import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Mechanical comment discipline on the lines a commit adds (standards K1–K2).
enum CommentsCheck {
  /// Resolves module scopes from the repository's config, then checks.
  static func run(root: URL, git: any Git, swiftPM: any SwiftPM) async -> StaticCheckOutcome {
    let config: Config?
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let loaded): config = loaded
    case .failure(let failure): return failure.outcome
    }
    switch await ScopeResolution.resolve(config: config, root: root, swiftPM: swiftPM) {
    case .failed(let outcome): return outcome
    case .resolved(let scopes):
      let collector = SwiftSourceCollector(root: root, excluding: config?.exclude ?? [])
      let knownIds = await KnownIdSources.load(root: root, git: git)
      let outcome = await run(
        git: git, scopes: scopes, isExcluded: collector.isExcluded, knownIds: knownIds.ids)
      return KnownIdSourceFindings.appending(knownIds.unreadable, to: outcome)
    }
  }

  /// - Parameter isExcluded: takes a project-relative path; excluded files are not checked.
  static func run(
    git: any Git, scopes: ResolvedScopes, isExcluded: (String) -> Bool = { _ in false },
    knownIds: Set<String> = []
  ) async -> StaticCheckOutcome {
    let prefix: String
    let added: [AddedLines]
    let contents: [String: String]
    let markdownFindings: [Finding]
    do throws(GitError) {
      prefix = try await git.workingDirectoryPrefix()
      let staged = try await git.stagedAddedLines()
      added = staged.filter {
        $0.path.hasSuffix(".swift") && $0.path.hasPrefix(prefix)
          && !isExcluded(String($0.path.dropFirst(prefix.count)))
      }
      contents = try await git.stagedContents(of: added.map(\.path))
      // Hand-edited docs only: the index (never a filesystem walk) is what `git add` populated,
      // so a gitignored `.build`/`.harness` doc never reaches this scan unless force-added.
      let markdownPaths = staged.filter {
        $0.path.hasSuffix(".md") && $0.path.hasPrefix(prefix)
          && !isExcluded(String($0.path.dropFirst(prefix.count)))
      }.map(\.path)
      let markdownContents = try await git.stagedContents(of: markdownPaths)
      markdownFindings = markdownPaths.sorted().flatMap { path in
        LocalPathRule.scan(
          markdownContents[path] ?? "", file: String(path.dropFirst(prefix.count)))
      }
    } catch {
      return .blocked(reason: "git: \(error)")
    }
    // Git paths are toplevel-relative; module scopes are relative to this project's root.
    let local = added.map {
      AddedLines(path: String($0.path.dropFirst(prefix.count)), ranges: $0.ranges)
    }
    let inputs = zip(added, local).compactMap { staged, lines in
      contents[staged.path].map { SourceInput(path: lines.path, text: $0) }
    }
    let context = RuleContext(scopes: scopes.resolver, knownIds: knownIds)
    let outcome = StaticCheck.evaluate(
      RuleCatalog.comments, inputs, context: context, restrictTo: local)
    return scopes.appendingNotices(to: Self.appending(markdownFindings, to: outcome))
  }

  /// No-op when there is nothing to add or the outcome never reached a checked state (`blocked`
  /// findings already explain themselves).
  private static func appending(_ findings: [Finding], to outcome: StaticCheckOutcome)
    -> StaticCheckOutcome
  {
    guard case .checked(let result) = outcome, !findings.isEmpty else { return outcome }
    return .checked(
      RuleRunResult(findings: result.findings + findings, allowances: result.allowances))
  }
}

/// The `commit-msg` hook (spec §6.3): the exact scan `comments.leaked-id` runs, applied to a
/// commit message's raw text instead of an extracted Swift comment, since a message is never
/// Swift source.
enum CommitMessageCheck {
  static func run(path: String, root: URL, git: any Git) async -> StaticCheckOutcome {
    // A message can only be judged clean or leaking when the known-id feed is trustworthy; outside
    // a repository (or one git can't answer for) there is no ledger to read, so this must block
    // rather than silently pass every message as clean.
    guard (try? await git.commonDirectory()) != nil else {
      return .blocked(reason: "not a git repository")
    }
    let text: String
    do {
      text = try String(contentsOf: URL(filePath: path), encoding: .utf8)
    } catch {
      return .blocked(reason: "commit message \(path): \(error.localizedDescription)")
    }
    let knownIds = await KnownIdSources.load(root: root, git: git)
    do throws(ReportContractViolation) {
      let findings = try IdLeakScan.matches(in: text, knownIds: knownIds.ids).map {
        match throws(ReportContractViolation) in
        try Finding(
          ruleID: "comments.leaked-id", severity: .major, file: path,
          line: lineNumber(of: match.range.lowerBound, in: text), message: match.message,
          failureScenario: nil)
      }
      let outcome = StaticCheckOutcome.checked(RuleRunResult(findings: findings, allowances: []))
      return KnownIdSourceFindings.appending(knownIds.unreadable, to: outcome)
    } catch {
      return .blocked(reason: "rule engine: \(error)")
    }
  }

  private static func lineNumber(of index: String.Index, in text: String) -> Int {
    text[text.startIndex..<index].count(where: \.isNewline) + 1
  }
}

struct CommentsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "comments",
    abstract: "Check comments on staged added lines (pre-commit), or a commit message (commit-msg)."
  )

  @Flag(help: "Check the lines the staged change adds.")
  var staged = false

  @Option(help: "Check a commit message file for leaked ledger/claim/doc ids (commit-msg hook).")
  var commitMsg: String?

  @OptionGroup var output: OutputOptions

  func validate() throws {
    switch (staged, commitMsg) {
    case (true, nil), (false, .some): break
    case (true, .some): throw ValidationError("pass either --staged or --commit-msg, not both")
    case (false, nil): throw ValidationError("pass --staged or --commit-msg <file>")
    }
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    try await StaticCheckRun.execute(root: root, format: output.format) {
      if let commitMsg {
        await CommitMessageCheck.run(path: commitMsg, root: root, git: git)
      } else {
        await CommentsCheck.run(
          root: root, git: git, swiftPM: ScopeResolution.liveSwiftPM(root: root))
      }
    }
  }
}
