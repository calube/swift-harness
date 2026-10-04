import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Gathers a design page's inputs through `design-lint`'s and `evidence check`'s own code paths,
/// then hands them to ``DesignRender``. Refuses, writing nothing, when the doc fails design-lint.
enum DesignRenderRun {
  struct Options: Sendable, Equatable {
    var design: String
    var packageResolved: String
    var sdk: String?
  }

  enum Outcome: Sendable, Equatable {
    /// `path` is repo-relative inside the tree, else absolute; `capabilities` is the Artifact tool's `capabilities` value.
    case written(path: String, designSha: String, capabilities: String, notes: [String])
    /// design-lint's gating findings; no HTML was written.
    case lintFailed([Finding])
    case blocked(String)
  }

  /// Relative to the state root.
  static func outputPath(for design: String) -> String {
    let file = design.split(separator: "/").last.map(String.init) ?? design
    let slug = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
    return "\(RunLayout.designRenderDirectory)/\(slug).html"
  }

  static func run(options: Options, root: URL, git: any Git, runner: any ProcessRunner) async
    -> Outcome
  {
    let lint = await DesignLintCheck.run(
      root: root, docPath: options.design, git: git, processRunner: runner)
    switch lint {
    case .blocked(let reason): return .blocked(reason)
    case .invalid(let reason, let file): return .blocked("\(file): \(reason)")
    case .checked(let result):
      let gating = result.findings.filter { $0.severity.failsGate }
      if !gating.isEmpty { return .lintFailed(gating) }
    }

    let docURL = root.appending(path: options.design, directoryHint: .notDirectory)
    let rawText: String
    do {
      rawText = try String(contentsOf: docURL, encoding: .utf8)
    } catch {
      return .blocked("can't read \(options.design): \(error.localizedDescription)")
    }

    var notes: [String] = []
    var claims: [Claim] = []
    var results: [EvidenceCheckResult] = []
    let claimsFile = EvidenceLayout(designDocPath: options.design).claimsFile
    if FileManager.default.fileExists(atPath: root.appending(path: claimsFile).path) {
      let evidence = await EvidenceCheckRun.run(
        options: .init(
          design: options.design, at: nil, packageResolved: options.packageResolved,
          sdk: options.sdk),
        root: root, runner: runner)
      switch evidence {
      case .blocked(let message): return .blocked("evidence check: \(message)")
      case .checked(let checkedClaims, let checkResults):
        claims = checkedClaims
        results = checkResults
      }
    } else {
      notes.append("\(claimsFile) doesn't exist; the page shows no cited evidence.")
    }

    let page = DesignRender.page(
      .init(rawText: rawText, claims: claims, checkResults: results))
    let state = StateRootResolver.resolve(worktree: root)
    let path = state.displayPath(outputPath(for: options.design))
    let outputURL = state.url(outputPath(for: options.design), directoryHint: .notDirectory)
    do {
      try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(page.html.utf8).write(to: outputURL, options: .atomic)
    } catch {
      return .blocked("can't write \(path): \(error.localizedDescription)")
    }
    return .written(
      path: path, designSha: DesignSha.of(rawText), capabilities: page.capabilityDeclaration,
      notes: notes)
  }

  static func render(_ outcome: Outcome, design: String, format: OutputFormat) -> String {
    switch format {
    case .json:
      var json = DesignRenderJSON(design: design)
      switch outcome {
      case .written(let path, let designSha, let capabilities, let notes):
        json.verdict = Verdict.green.rawValue
        json.output = path
        json.designSha = designSha
        json.capabilities = capabilities
        json.notes = notes
      case .lintFailed(let findings):
        json.verdict = Verdict.red.rawValue
        json.findings = findings.map(describe)
      case .blocked(let message):
        json.verdict = Verdict.blocked.rawValue
        json.message = message
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return (try? encoder.encode(json)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    case .human:
      switch outcome {
      case .written(let path, let designSha, let capabilities, let notes):
        let lines = [
          "design-render: \(Verdict.green.rawValue) wrote \(path)", "  designSha \(designSha)",
          "  publish with capabilities \(capabilities)",
        ]
        return (lines + notes.map { "  note: \($0)" }).joined(separator: "\n")
      case .lintFailed(let findings):
        let head =
          "design-render: \(Verdict.red.rawValue) design-lint found \(findings.count) gating "
          + "finding(s); nothing was written"
        return ([head] + findings.map { "  \(describe($0))" }).joined(separator: "\n")
      case .blocked(let message):
        return "design-render: \(Verdict.blocked.rawValue) \(message)"
      }
    }
  }

  private static func describe(_ finding: Finding) -> String {
    "\(finding.file): \(finding.ruleID): \(finding.message)"
  }

  static func exitCode(_ outcome: Outcome) -> Int32 {
    switch outcome {
    case .written: Verdict.green.exitCode
    case .lintFailed: Verdict.red.exitCode
    case .blocked: Verdict.blocked.exitCode
    }
  }
}

/// `--json` shape. Keys absent for an outcome are omitted.
struct DesignRenderJSON: Encodable {
  var command = "design-render"
  var verdict = ""
  var design: String
  var output: String?
  var designSha: String?
  var capabilities: String?
  var notes: [String]?
  var findings: [String]?
  var message: String?

  init(design: String) {
    self.design = design
  }
}

struct DesignRenderCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design-render",
    abstract:
      "Render a design doc's Artifact page (diagrams, options, evidence badges, approval), or a "
      + "plan's ledger page with --ledger.",
    discussion:
      "With a design doc: runs design-lint and evidence check over it, then writes "
      + "design-render/<slug>.html under the harness state directory for the design skill to publish with the printed "
      + "capabilities. Exit 0 written, 1 when design-lint finds a gating problem (nothing is "
      + "written), 2 when the doc, its claims or the output can't be read or written.\n"
      + "With --ledger <plan>: reads the plan's shared state and the design at its designSha, "
      + "or a spec-page plan's page at its confirmed pageSha, then writes "
      + "design-render/<plan>-ledger.html under the harness state directory: the task DAG, the wave timeline, the "
      + "requirement (or slice) × task coverage matrix and the predicted overhead share. Exit 0 "
      + "written, 2 when the plan state, its designSha or the design at that revision can't be "
      + "read, or when a spec page is unconfirmed, unreadable, malformed or changed since its "
      + "confirmation.")

  @Argument(help: "The repo-relative design doc to render. Omit when --ledger names a plan.")
  var doc: String?

  @Option(help: "Render this plan's ledger page instead of a design doc, naming its slug.")
  var ledger: String?

  @Option(help: "The repo-relative Package.resolved that package pins are checked against.")
  var packageResolved = "Package.resolved"

  @Option(help: "The SDK version now in effect; defaults to what xcrun reports.")
  var sdk: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let runner = LiveProcessRunner()
    let git = LiveGit(runner: runner, repositoryRoot: root.path)

    if let slug = ledger {
      guard doc == nil else {
        throw ValidationError("pass either a design doc or --ledger <plan>, not both")
      }
      let outcome = await LedgerRenderRun.run(slug: slug, root: root, git: git)
      Console.write(LedgerRenderRun.render(outcome, slug: slug, format: output.format))
      let code = LedgerRenderRun.exitCode(outcome)
      if code != 0 { throw ExitCode(code) }
      return
    }

    guard let doc else {
      throw ValidationError("pass a design doc to render, or --ledger <plan> for its ledger page")
    }
    let outcome = await DesignRenderRun.run(
      options: .init(design: doc, packageResolved: packageResolved, sdk: sdk), root: root,
      git: git, runner: runner)
    Console.write(DesignRenderRun.render(outcome, design: doc, format: output.format))
    let code = DesignRenderRun.exitCode(outcome)
    if code != 0 { throw ExitCode(code) }
  }
}

/// Gathers a ledger page's inputs the same way `plan-lint` gathers `plan-lint`'s (spec §9.2):
/// the plan's shared state under the git common dir, the design revision named by its
/// `designSha` (walked from committed history, never the working tree), then hands them to
/// ``LedgerRender``.
enum LedgerRenderRun {
  enum Outcome: Sendable, Equatable {
    /// `path` is repo-relative inside the tree, else absolute; `capabilities` is the Artifact tool's `capabilities` value.
    case written(path: String, designSha: String, capabilities: String, notes: [String])
    /// A spec-page plan's page, rendered from the page whose bytes hash to `pageSha`.
    case writtenFromSpecPage(path: String, pageSha: String, capabilities: String, notes: [String])
    case blocked(String)
  }

  /// Relative to the state root.
  static func outputPath(for slug: String) -> String {
    "\(RunLayout.designRenderDirectory)/\(slug)-ledger.html"
  }

  static func run(slug: String, root: URL, git: any Git) async -> Outcome {
    let store: PlanStateStore
    let plan: PlanFile
    let ledger: Ledger
    do throws(PlanStateStoreError) {
      store = try await PlanStateStore.locate(slug: slug, git: git)
      plan = try store.planFile()
      ledger = try store.ledger()
    } catch {
      return .blocked("plan `\(slug)`: \(describe(error))")
    }

    let source: LedgerRender.Source
    switch plan.source {
    case .design(let planDesign):
      switch await designSource(slug: slug, planDesign: planDesign, git: git) {
      case .success(let found): source = found
      case .failure(let refusal): return .blocked(refusal.message)
      }
    case .specPage(let pageSource):
      switch specPageSource(slug: slug, pageSource: pageSource, store: store) {
      case .success(let found): source = found
      case .failure(let refusal): return .blocked(refusal.message)
      }
    case .livePlan:
      return .blocked(
        "plan `\(slug)` is a live plan; its PLAN.md is the page, so there is no design page to "
          + "render")
    }

    var notes: [String] = []
    let build = await buildView(slug: slug, ledger: ledger, root: root, git: git, notes: &notes)
    let page = LedgerRender.page(
      .init(
        slug: slug, ledger: ledger, source: source, buildMetrics: build?.metrics,
        build: build?.view))
    let state = StateRootResolver.resolve(worktree: root)
    let path = state.displayPath(outputPath(for: slug))
    let outputURL = state.url(outputPath(for: slug), directoryHint: .notDirectory)
    do {
      try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(page.html.utf8).write(to: outputURL, options: .atomic)
    } catch {
      return .blocked("can't write \(path): \(error.localizedDescription)")
    }
    switch source {
    case .design(_, let designSha):
      return .written(
        path: path, designSha: designSha, capabilities: page.capabilityDeclaration, notes: notes)
    case .specPage(_, let pageSha):
      return .writtenFromSpecPage(
        path: path, pageSha: pageSha, capabilities: page.capabilityDeclaration, notes: notes)
    }
  }

  /// Why a plan's source can't be rendered; the command exits 2 with it.
  struct Refusal: Error, Equatable {
    let message: String
  }

  /// The design at the plan's `designSha`, walked from committed history.
  private static func designSource(
    slug: String, planDesign: PlanFile.DesignSource, git: any Git
  ) async -> Result<LedgerRender.Source, Refusal> {
    guard let designSha = planDesign.designSha else {
      return .failure(
        Refusal(
          message: "plan `\(slug)` has no designSha yet (claimed, not drafted): there is no "
            + "design to render a ledger page against"))
    }
    let found: DesignAtSha.Found?
    do {
      found = try await DesignAtSha.find(designSha: designSha, path: planDesign.design, git: git)
    } catch {
      return .failure(
        Refusal(
          message: "plan `\(slug)`: can't walk the history of `\(planDesign.design)`: \(error)"))
    }
    guard let found else {
      return .failure(
        Refusal(
          message: "plan `\(slug)`: no committed revision of `\(planDesign.design)` has "
            + "designSha \(designSha)"))
    }
    return .success(.design(DesignDocument(markdown: .parse(found.text)), designSha: designSha))
  }

  /// The spec page in the plan's directory, only when its bytes still hash to the `pageSha` its
  /// confirmation names: the page is never committed, so the sha is the only trace of what was
  /// confirmed.
  private static func specPageSource(
    slug: String, pageSource: PlanFile.SpecPageSource, store: PlanStateStore
  ) -> Result<LedgerRender.Source, Refusal> {
    guard let approval = pageSource.approval else {
      return .failure(
        Refusal(
          message: "plan `\(slug)`'s spec page isn't confirmed yet, so no pageSha names the page "
            + "to render: confirm it with `swiftgate plan confirm \(slug)` first"))
    }
    let path = store.specPageFile(pageSource)
    let bytes: Data
    do {
      bytes = try Data(contentsOf: URL(filePath: path))
    } catch {
      return .failure(
        Refusal(
          message: "plan `\(slug)`: can't read its spec page `\(path)`: "
            + error.localizedDescription))
    }
    let pageSha = SpecPageCheck.pageSha(bytes)
    guard pageSha == approval.pageSha else {
      return .failure(
        Refusal(
          message: "plan `\(slug)`: its spec page has pageSha \(pageSha), but the confirmed "
            + "pageSha is \(approval.pageSha); the page changed after its confirmation. Confirm "
            + "it again with `swiftgate plan confirm \(slug)`"))
    }
    guard let text = String(data: bytes, encoding: .utf8) else {
      return .failure(Refusal(message: "plan `\(slug)`: its spec page `\(path)` isn't UTF-8"))
    }
    switch SpecPage.parse(text) {
    case .parsed(let page):
      return .success(.specPage(page, pageSha: pageSha))
    case .malformed(let problems):
      let listed = problems.map { problem in
        problem.line.map { "line \($0): \(problem.message)" } ?? problem.message
      }
      return .failure(
        Refusal(
          message: "plan `\(slug)`: its spec page `\(path)` doesn't parse: "
            + listed.joined(separator: "; ")))
    }
  }

  /// The plan's newest build run, as the page shows it: `nil` before any run. A run that can't be
  /// read renders the page without it and says why in `notes`, since the plan itself still is.
  private static func buildView(
    slug: String, ledger: Ledger, root: URL, git: any Git, notes: inout [String]
  ) async -> (view: LedgerRender.BuildView, metrics: BuildMetrics.Report)? {
    let store: BuildRunStore
    let record: BuildRunRecord
    let log: BuildEventLog
    do throws(BuildRunStoreError) {
      guard let latest = try await BuildRunStore.latest(plan: slug, git: git) else { return nil }
      store = latest
      record = try store.record()
      log = try store.events()
    } catch {
      notes.append("build run not shown: \(error)")
      return nil
    }
    var taskGates: [String: TaskReturn.Gate] = [:]
    for task in ledger.tasks {
      let file = URL(filePath: store.layout.directory + "/returns/\(task.id).json")
      guard FileManager.default.fileExists(atPath: file.path) else { continue }
      do {
        taskGates[task.id] = try TaskReturnJSON.decode(Data(contentsOf: file)).gate
      } catch {
        notes.append("task `\(task.id)`'s stored return is unreadable: \(error)")
      }
    }
    let required: LedgerRender.BuildView.Required
    switch AppTargetPackages.required(ledger: ledger, root: root) {
    case .success(let found): required = .known(found)
    case .failure(let error):
      notes.append("tasks the app target needs not shown: \(error)")
      required = .unknown(reason: error.description)
    }
    let metrics = BuildMetrics.compute(record: record, log: log)
    let view = LedgerRender.BuildView(
      runID: record.runID, presetName: record.presetName,
      timeBudgetMin: record.preset.timeBudgetMin,
      totalWallMilliseconds: metrics.totalWallMilliseconds, taskGates: taskGates, log: log,
      required: required)
    return (view, metrics)
  }

  private static func describe(_ error: PlanStateStoreError) -> String {
    switch error {
    case .commonDirectory(let detail): "can't find the git common dir: \(detail)"
    case .invalidPlanName(let name): "invalid plan name `\(name)`"
    case .missing(let path): "`\(path)` doesn't exist"
    case .unreadable(let path, let detail): "can't read `\(path)`: \(detail)"
    case .malformed(let path, let detail): "`\(path)` is malformed: \(detail)"
    }
  }

  static func render(_ outcome: Outcome, slug: String, format: OutputFormat) -> String {
    switch format {
    case .json:
      var json = LedgerRenderJSON(plan: slug)
      switch outcome {
      case .written(let path, let designSha, let capabilities, let notes):
        json.verdict = Verdict.green.rawValue
        json.output = path
        json.designSha = designSha
        json.capabilities = capabilities
        json.notes = notes
      case .writtenFromSpecPage(let path, let pageSha, let capabilities, let notes):
        json.verdict = Verdict.green.rawValue
        json.output = path
        json.pageSha = pageSha
        json.capabilities = capabilities
        json.notes = notes
      case .blocked(let message):
        json.verdict = Verdict.blocked.rawValue
        json.message = message
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return (try? encoder.encode(json)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    case .human:
      switch outcome {
      case .written(let path, let designSha, let capabilities, let notes):
        let lines = [
          "design-render: \(Verdict.green.rawValue) wrote \(path)", "  designSha \(designSha)",
          "  publish with capabilities \(capabilities)",
        ]
        return (lines + notes.map { "  note: \($0)" }).joined(separator: "\n")
      case .writtenFromSpecPage(let path, let pageSha, let capabilities, let notes):
        let lines = [
          "design-render: \(Verdict.green.rawValue) wrote \(path)", "  pageSha \(pageSha)",
          "  publish with capabilities \(capabilities)",
        ]
        return (lines + notes.map { "  note: \($0)" }).joined(separator: "\n")
      case .blocked(let message):
        return "design-render: \(Verdict.blocked.rawValue) \(message)"
      }
    }
  }

  static func exitCode(_ outcome: Outcome) -> Int32 {
    switch outcome {
    case .written, .writtenFromSpecPage: Verdict.green.exitCode
    case .blocked: Verdict.blocked.exitCode
    }
  }
}

/// `--json` shape for `--ledger`. Keys absent for an outcome are omitted.
struct LedgerRenderJSON: Encodable {
  var command = "design-render"
  var verdict = ""
  var plan: String
  var output: String?
  var designSha: String?
  var pageSha: String?
  var capabilities: String?
  var notes: [String]?
  var message: String?

  init(plan: String) {
    self.plan = plan
  }
}
