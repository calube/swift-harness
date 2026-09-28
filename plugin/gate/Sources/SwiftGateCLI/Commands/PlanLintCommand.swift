import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Gathers `plan-lint`'s inputs and hands them to ``PlanLintGraph/allFindings(design:designPath:ledger:ledgerPath:graph:workerPacks:bounds:)``
/// once; every rule lives there (spec §9.2, §9.3).
enum PlanLintRun {
  struct Result: Sendable, Equatable {
    let outcome: StaticCheckOutcome
    /// Why each task's worker pack couldn't be built, keyed by task id. Each one also reaches the
    /// report as the domain's `plan-lint.pack-missing` finding.
    let packFailures: [String: String]
    /// Inputs a worker pack would carry that don't exist here, so every pack was built without
    /// them.
    let notes: [String]
  }

  /// - Parameter harnessRoot: the plugin whose `docs/standards.md` worker packs fall back to
  ///   when the repository has none of its own.
  static func run(
    slug: String, root: URL, git: any Git, swiftPM: any SwiftPM, harnessRoot: URL? = nil
  ) async -> Result {
    let store: PlanStateStore
    let plan: PlanFile
    let ledger: Ledger
    do throws(PlanStateStoreError) {
      store = try await PlanStateStore.locate(slug: slug, git: git)
      plan = try store.planFile()
      ledger = try store.ledger()
    } catch {
      return blocked("plan `\(slug)`: \(describe(error))")
    }

    let planDesign: PlanFile.DesignSource
    switch plan.source {
    case .design(let source): planDesign = source
    case .specPage(let pageSource):
      return await runSpecPage(
        slug: slug, pageSource: pageSource, store: store, ledger: ledger, root: root,
        swiftPM: swiftPM, harnessRoot: harnessRoot)
    }
    guard let designSha = planDesign.designSha else {
      return blocked(
        "plan `\(slug)` has no designSha yet (claimed, not drafted): there is no design to lint "
          + "against")
    }
    let found: DesignAtSha.Found?
    do {
      found = try await DesignAtSha.find(designSha: designSha, path: planDesign.design, git: git)
    } catch {
      return blocked("plan `\(slug)`: can't walk the history of `\(planDesign.design)`: \(error)")
    }
    guard let found else {
      return blocked(
        "plan `\(slug)`: no committed revision of `\(planDesign.design)` has designSha \(designSha)"
      )
    }
    let moved: [Finding]
    do {
      moved = try await designMovedFindings(plan: planDesign, designSha: designSha, git: git)
    } catch let error as ReportContractViolation {
      return blocked("plan-lint: \(error)")
    } catch {
      return blocked("plan `\(slug)`: can't read `\(planDesign.design)` at HEAD: \(error)")
    }
    let designSource = ContextSource(label: planDesign.design, rawText: found.text)
    let design = DesignDocument(markdown: .parse(found.text))

    let config: Config
    let graph: ModuleGraph
    switch await loadGraph(root: root, swiftPM: swiftPM) {
    case .success(let loaded): (config, graph) = loaded
    case .failure(let refusal): return refusal.result
    }

    let sources = WorkerPackSources.gather(
      designPath: planDesign.design, root: root, harnessRoot: harnessRoot)
    var workerPacks: [String: ContextPack] = [:]
    var packFailures: [String: String] = [:]
    // A done task is never handed to a worker again, and its covers may name ids an amend has
    // since renamed, so its pack is neither needed nor buildable.
    for task in ledger.tasks where task.status != .done {
      switch sources.inputs(task: task, design: design, designSource: designSource, graph: graph) {
      case .failure(let reason): packFailures[task.id] = reason.message
      case .success(let inputs):
        do {
          workerPacks[task.id] = try ContextPack.build(role: .worker, inputs: .worker(inputs))
        } catch {
          packFailures[task.id] = "\(error)"
        }
      }
    }

    do throws(ReportContractViolation) {
      let findings = try PlanLintGraph.allFindings(
        design: design, designPath: planDesign.design, ledger: ledger,
        ledgerPath: store.plan.ledgerFile, graph: graph, workerPacks: workerPacks,
        bounds: config.plan)
      return Result(
        outcome: .checked(RuleRunResult(findings: moved + findings, allowances: [])),
        packFailures: packFailures, notes: sources.notes)
    } catch {
      return blocked("plan-lint: \(error)")
    }
  }

  /// Why plan-lint can't run; its result is the command's.
  private struct Refusal: Error {
    let result: Result
  }

  private static func loadGraph(root: URL, swiftPM: any SwiftPM) async
    -> Swift.Result<(Config, ModuleGraph), Refusal>
  {
    let config: Config
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let loaded?): config = loaded
    case .success(nil):
      return .failure(
        Refusal(result: blocked("no \(ConfigLoader.fileName): plan-lint needs the module graph")))
    case .failure(let failure):
      return .failure(
        Refusal(result: Result(outcome: failure.outcome, packFailures: [:], notes: [])))
    }
    do {
      return .success(
        (config, try await ModuleGraphLoader(swiftPM: swiftPM, root: root).load(config: config)))
    } catch {
      return .failure(Refusal(result: blocked("can't load the module graph: \(error)")))
    }
  }

  /// A spec-page plan, linted against the page in its plan directory. The page is never
  /// committed, so its confirmed pageSha is the only trace of what was confirmed: a page whose
  /// bytes hash to anything else is a gating `plan-lint.spec-page-moved`, and the rest of the
  /// lint reads the page as it now stands.
  private static func runSpecPage(
    slug: String, pageSource: PlanFile.SpecPageSource, store: PlanStateStore, ledger: Ledger,
    root: URL, swiftPM: any SwiftPM, harnessRoot: URL?
  ) async -> Result {
    guard let approval = pageSource.approval else {
      return blocked(
        "plan `\(slug)`'s spec page isn't confirmed yet, so no pageSha names the page to lint "
          + "against: confirm it with `swiftgate plan confirm \(slug)` first")
    }
    let path = store.specPageFile(pageSource)
    let bytes: Data
    do {
      bytes = try Data(contentsOf: URL(filePath: path))
    } catch {
      return blocked(
        "plan `\(slug)`: can't read its spec page `\(path)`: \(error.localizedDescription)")
    }
    guard let text = String(data: bytes, encoding: .utf8) else {
      return blocked("plan `\(slug)`: its spec page `\(path)` isn't UTF-8")
    }
    let page: SpecPage
    switch SpecPage.parse(text) {
    case .parsed(let parsed): page = parsed
    case .malformed(let problems):
      let listed = problems.map { problem in
        problem.line.map { "line \($0): \(problem.message)" } ?? problem.message
      }
      return blocked(
        "plan `\(slug)`: its spec page `\(path)` doesn't parse (run `swiftgate spec-page check` "
          + "on it): " + listed.joined(separator: "; "))
    }

    let config: Config
    let graph: ModuleGraph
    switch await loadGraph(root: root, swiftPM: swiftPM) {
    case .success(let loaded): (config, graph) = loaded
    case .failure(let refusal): return refusal.result
    }

    let sources = WorkerPackSources.gatherForSpecPage(root: root, harnessRoot: harnessRoot)
    let pageContext = SpecPageSource(page: page, source: ContextSource(label: path, rawText: text))
    var workerPacks: [String: ContextPack] = [:]
    var packFailures: [String: String] = [:]
    for task in ledger.tasks where task.status != .done {
      switch sources.inputs(task: task, specPage: pageContext, graph: graph) {
      case .failure(let reason): packFailures[task.id] = reason.message
      case .success(let inputs):
        do {
          workerPacks[task.id] = try ContextPack.build(
            role: .worker, inputs: .specPageWorker(inputs))
        } catch {
          packFailures[task.id] = "\(error)"
        }
      }
    }

    do throws(ReportContractViolation) {
      let moved = try PlanLintGraph.specPageMovedFindings(
        pagePath: path, pageSha: SpecPageCheck.pageSha(bytes), confirmedPageSha: approval.pageSha)
      let findings = try PlanLintGraph.allFindings(
        specPage: page, pagePath: path, ledger: ledger, ledgerPath: store.plan.ledgerFile,
        graph: graph, workerPacks: workerPacks, bounds: config.plan)
      return Result(
        outcome: .checked(RuleRunResult(findings: moved + findings, allowances: [])),
        packFailures: packFailures, notes: sources.notes)
    } catch {
      return blocked("plan-lint: \(error)")
    }
  }

  /// The committed doc at HEAD against `designSha` (spec §5.4). HEAD, not the working tree: the
  /// verdict must not depend on uncommitted edits. The clarify chain is verified only when HEAD
  /// has moved, since it's the one thing that can still vouch for the new revision.
  private static func designMovedFindings(
    plan: PlanFile.DesignSource, designSha: String, git: any Git
  )
    async throws -> [Finding]
  {
    let headSha = try await git.contents(of: [plan.design], at: "HEAD")[plan.design].map(
      DesignSha.of)
    var chain: ClarifyChain.Verification?
    if headSha != designSha, !plan.clarifyChain.isEmpty {
      if let approval = plan.approval, approval.decision == .approve {
        var revisions: [String: String] = [:]
        for commit in try await git.revisions(of: plan.design) {
          guard let text = try await git.contents(of: [plan.design], at: commit)[plan.design]
          else { continue }
          revisions[DesignSha.of(text)] = text
        }
        chain = ClarifyChain.verify(
          approvedSha: approval.designSha,
          links: plan.clarifyChain.map { ClarifyChain.Link(fromSha: $0.fromSha, toSha: $0.toSha) },
          revisions: revisions)
      }
    }
    return try PlanLintGraph.designMovedFindings(
      designPath: plan.design, designSha: designSha, headDesignSha: headSha, clarifyChain: chain)
  }

  private static func blocked(_ reason: String) -> Result {
    Result(outcome: .blocked(reason: reason), packFailures: [:], notes: [])
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
}

/// What `context-pack --role worker` takes as flags, derived from the repository instead: the
/// design's `claims.jsonl` (every claim, since the ledger records no per-task citations), the
/// standards doc plus playbook, and the standards anchors for the kinds of the modules a task
/// touches (spec §5.10). Claims and standards come from the working tree, as `context-pack` reads
/// them; only the design is pinned to designSha. The standards are the repository's own
/// `docs/standards.md` when it has one, else the harness plugin's, as the skills read them.
struct WorkerPackSources: Sendable {
  static let standardsPath = "docs/standards.md"
  static let playbookPath = "docs/testing-playbook.md"

  struct Failure: Error, Sendable {
    let message: String
  }

  let claims: Swift.Result<(source: ContextSource, ids: [String]), Failure>
  let standards: Swift.Result<ContextSource?, Failure>
  let notes: [String]

  static func gather(designPath: String, root: URL, harnessRoot: URL? = nil) -> WorkerPackSources {
    var notes: [String] = []
    let claimsPath = EvidenceLayout(designDocPath: designPath).claimsFile
    let claims: Swift.Result<(source: ContextSource, ids: [String]), Failure>
    if !exists(claimsPath, root: root) {
      notes.append("no `\(claimsPath)`: worker packs carry no claims")
      claims = .success((ContextSource(label: "claims.jsonl", rawText: ""), []))
    } else {
      switch ContextPackFiles.read(label: claimsPath, path: claimsPath, root: root) {
      case .failure(.unreadable(let path)):
        claims = .failure(Failure(message: "can't read `\(path)`"))
      case .success(let source):
        let decoded = ClaimJSON.decode(Data(source.rawText.utf8))
        claims =
          decoded.invalidLines > 0
          ? .failure(
            Failure(message: "`\(claimsPath)` has \(decoded.invalidLines) malformed line(s)"))
          : .success((source, decoded.claims.map(\.id)))
      }
    }

    return WorkerPackSources(
      claims: claims, standards: gatherStandards(root: root, harnessRoot: harnessRoot),
      notes: notes)
  }

  /// A spec-page plan's sources: the standards as ``gather(designPath:root:harnessRoot:)`` finds
  /// them, and no claims, since a spec page has no evidence lane.
  static func gatherForSpecPage(root: URL, harnessRoot: URL? = nil) -> WorkerPackSources {
    WorkerPackSources(
      claims: .success((ContextSource(label: "claims.jsonl", rawText: ""), [])),
      standards: gatherStandards(root: root, harnessRoot: harnessRoot), notes: [])
  }

  private static func gatherStandards(root: URL, harnessRoot: URL?)
    -> Swift.Result<ContextSource?, Failure>
  {
    let standards: Swift.Result<ContextSource?, Failure>
    if exists(standardsPath, root: root) {
      standards = readStandards(root: root, labelPrefix: "")
    } else if let harnessRoot, exists(standardsPath, root: harnessRoot) {
      standards = readStandards(root: harnessRoot, labelPrefix: "harness ")
    } else {
      let harness =
        harnessRoot.map { "`\($0.appending(path: standardsPath).path)`" }
        ?? "the harness plugin's (no harness root: run through the plugin's bin/swiftgate, "
        + "which sets SWIFTGATE_HARNESS_ROOT)"
      standards = .failure(
        Failure(
          message: "no standards doc for worker packs: neither this repository's "
            + "`\(standardsPath)` nor \(harness) exists"))
    }
    return standards
  }

  /// A spec-page worker's inputs, its module kinds resolved through the page's Modules table as
  /// `context-pack --spec-page` resolves them.
  func inputs(task: LedgerTask, specPage: SpecPageSource, graph: ModuleGraph)
    -> Swift.Result<SpecPageWorkerInputs, Failure>
  {
    let claimsSource: ContextSource
    let claimIDs: [String]
    switch claims {
    case .failure(let failure): return .failure(failure)
    case .success(let value): (claimsSource, claimIDs) = value
    }
    let standardsSource: ContextSource?
    switch standards {
    case .failure(let failure): return .failure(failure)
    case .success(let value): standardsSource = value
    }
    let resolution = SpecPageWriteSet.resolve(
      task.writeSet, graph: graph, page: specPage.page,
      packageDirectories: graph.packages.map(\.path))
    return .success(
      SpecPageWorkerInputs(
        task: task, specPage: specPage, claims: claimsSource, citedClaimIDs: claimIDs,
        standards: standardsSource ?? ContextSource(label: "standards", rawText: ""),
        moduleKindAnchors: standardsSource == nil
          ? [] : ContextPackModuleKindAnchors.anchors(for: resolution.kinds),
        touchedModules: resolution.moduleNames))
  }

  func inputs(
    task: LedgerTask, design: DesignDocument, designSource: ContextSource, graph: ModuleGraph
  ) -> Swift.Result<WorkerInputs, Failure> {
    let claimsSource: ContextSource
    let claimIDs: [String]
    switch claims {
    case .failure(let failure): return .failure(failure)
    case .success(let value): (claimsSource, claimIDs) = value
    }
    let standardsSource: ContextSource?
    switch standards {
    case .failure(let failure): return .failure(failure)
    case .success(let value): standardsSource = value
    }
    let kinds = PlanLintGraph.resolveWriteSet(
      task.writeSet, graph: graph, design: design, packageDirectories: graph.packages.map(\.path)
    ).kinds
    return .success(
      WorkerInputs(
        task: task, design: design, designSource: designSource, claims: claimsSource,
        citedClaimIDs: claimIDs,
        standards: standardsSource ?? ContextSource(label: "standards", rawText: ""),
        moduleKindAnchors: standardsSource == nil
          ? [] : ContextPackModuleKindAnchors.anchors(for: kinds)))
  }

  private static func exists(_ path: String, root: URL) -> Bool {
    FileManager.default.fileExists(atPath: ContextPackFiles.resolve(path, root: root).path)
  }

  /// The standards doc with the playbook appended when there is one, labelled as `context-pack`
  /// labels `--standards` plus `--playbook`.
  private static func readStandards(root: URL, labelPrefix: String)
    -> Swift.Result<ContextSource?, Failure>
  {
    let standards: ContextSource
    switch ContextPackFiles.read(
      label: labelPrefix + standardsPath, path: standardsPath, root: root)
    {
    case .failure(.unreadable(let path)): return .failure(Failure(message: "can't read `\(path)`"))
    case .success(let source): standards = source
    }
    guard exists(playbookPath, root: root) else { return .success(standards) }
    switch ContextPackFiles.read(label: playbookPath, path: playbookPath, root: root) {
    case .failure(.unreadable(let path)): return .failure(Failure(message: "can't read `\(path)`"))
    case .success(let playbook):
      return .success(
        ContextSource(
          label: "\(labelPrefix)\(standardsPath) + \(playbookPath)",
          rawText: standards.rawText + "\n" + playbook.rawText))
    }
  }
}

struct PlanLintCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "plan-lint",
    abstract:
      "Lint plan.json and ledger.json against the design at designSha, or the confirmed spec "
      + "page (spec §9.2).",
    discussion:
      "Reads the plan's shared state under the git common dir, the design revision whose "
      + "designSha plan.json records (walked from committed history, never the working tree), "
      + "the module graph and a worker context pack per task. A spec-page plan reads its "
      + "spec-page.md instead: each slice is a coverage item at its tier, and a page whose sha "
      + "differs from the confirmed pageSha is plan-lint.spec-page-moved. Exit 0 clean, 1 on a "
      + "gating finding, 2 when the plan state, the design at designSha, the spec page or the "
      + "module graph can't be read (including a plan with no designSha yet, or a spec page not "
      + "confirmed yet).")

  @Argument(help: "The plan's slug.")
  var slug: String

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let swiftPM = ScopeResolution.liveSwiftPM(root: root)
    try await StaticCheckRun.execute(root: root, format: output.format) {
      let result = await PlanLintRun.run(
        slug: slug, root: root, git: git, swiftPM: swiftPM,
        harnessRoot: ProcessInfo.processInfo.environment[SelfTestCommand.harnessRootVariable].map {
          URL(filePath: $0, directoryHint: .isDirectory)
        })
      for note in result.notes {
        FileHandle.standardError.write(Data("swiftgate plan-lint: \(note)\n".utf8))
      }
      for (task, reason) in result.packFailures.sorted(by: { $0.key < $1.key }) {
        FileHandle.standardError.write(
          Data("swiftgate plan-lint: worker pack for `\(task)` not built: \(reason)\n".utf8))
      }
      return result.outcome
    }
  }
}
