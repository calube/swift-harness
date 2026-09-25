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

  static func run(slug: String, root: URL, git: any Git, swiftPM: any SwiftPM) async -> Result {
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

    guard let designSha = plan.designSha else {
      return blocked(
        "plan `\(slug)` has no designSha yet (claimed, not drafted): there is no design to lint "
          + "against")
    }
    let found: DesignAtSha.Found?
    do {
      found = try await DesignAtSha.find(designSha: designSha, path: plan.design, git: git)
    } catch {
      return blocked("plan `\(slug)`: can't walk the history of `\(plan.design)`: \(error)")
    }
    guard let found else {
      return blocked(
        "plan `\(slug)`: no committed revision of `\(plan.design)` has designSha \(designSha)")
    }
    let designSource = ContextSource(label: plan.design, rawText: found.text)
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

    let sources = WorkerPackSources.gather(designPath: plan.design, root: root)
    var workerPacks: [String: ContextPack] = [:]
    var packFailures: [String: String] = [:]
    for task in ledger.tasks {
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
        design: design, designPath: plan.design, ledger: ledger,
        ledgerPath: store.plan.ledgerFile, graph: graph, workerPacks: workerPacks,
        bounds: config.plan)
      return Result(
        outcome: .checked(RuleRunResult(findings: findings, allowances: [])),
        packFailures: packFailures, notes: sources.notes)
    } catch {
      return blocked("plan-lint: \(error)")
    }
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
/// them; only the design is pinned to designSha.
struct WorkerPackSources: Sendable {
  static let standardsPath = "docs/standards.md"
  static let playbookPath = "docs/testing-playbook.md"

  struct Failure: Error, Sendable {
    let message: String
  }

  let claims: Swift.Result<(source: ContextSource, ids: [String]), Failure>
  let standards: Swift.Result<ContextSource?, Failure>
  let notes: [String]

  static func gather(designPath: String, root: URL) -> WorkerPackSources {
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
    if !exists(standardsPath, root: root) {
      notes.append("no `\(standardsPath)`: worker packs carry no standards anchors")
      standards = .success(nil)
    } else {
      standards = readStandards(root: root)
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
    let touched = PlanLintGraph.modulesTouched(writeSet: task.writeSet, graph: graph)
    let kinds = graph.modules.filter { touched.contains($0.name) }.sorted { $0.name < $1.name }
      .map(\.kind)
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
  private static func readStandards(root: URL) -> Swift.Result<ContextSource?, Failure> {
    let standards: ContextSource
    switch ContextPackFiles.read(label: standardsPath, path: standardsPath, root: root) {
    case .failure(.unreadable(let path)): return .failure(Failure(message: "can't read `\(path)`"))
    case .success(let source): standards = source
    }
    guard exists(playbookPath, root: root) else { return .success(standards) }
    switch ContextPackFiles.read(label: playbookPath, path: playbookPath, root: root) {
    case .failure(.unreadable(let path)): return .failure(Failure(message: "can't read `\(path)`"))
    case .success(let playbook):
      return .success(
        ContextSource(
          label: "\(standardsPath) + \(playbookPath)",
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
      let result = await PlanLintRun.run(slug: slug, root: root, git: git, swiftPM: swiftPM)
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
