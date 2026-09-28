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

    guard let planDesign = plan.designSource else {
      return blocked(
        "plan `\(slug)` is a spec-page plan: plan-lint reads a design's test plan, and this plan "
          + "has no design")
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
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let loaded?): config = loaded
    case .success(nil):
      return blocked("no \(ConfigLoader.fileName): plan-lint needs the module graph")
    case .failure(let failure):
      return Result(outcome: failure.outcome, packFailures: [:], notes: [])
    }
    let graph: ModuleGraph
    do {
      graph = try await ModuleGraphLoader(swiftPM: swiftPM, root: root).load(config: config)
    } catch {
      return blocked("can't load the module graph: \(error)")
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
    return WorkerPackSources(claims: claims, standards: standards, notes: notes)
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
    abstract: "Lint plan.json and ledger.json against the design at designSha (spec §9.2).",
    discussion:
      "Reads the plan's shared state under the git common dir, the design revision whose "
      + "designSha plan.json records (walked from committed history, never the working tree), "
      + "the module graph and a worker context pack per task. Exit 0 clean, 1 on a gating "
      + "finding, 2 when the plan state, the design at designSha or the module graph can't be "
      + "read (including a plan with no designSha yet).")

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
