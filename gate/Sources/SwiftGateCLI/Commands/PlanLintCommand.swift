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
    case .failure(let failure): return Result(outcome: failure.outcome, packFailures: [:])
    }
    let graph: ModuleGraph
    do {
      graph = try await ModuleGraphLoader(swiftPM: swiftPM, root: root).load(config: config)
    } catch {
      return blocked("can't load the module graph: \(error)")
    }

    var workerPacks: [String: ContextPack] = [:]
    var packFailures: [String: String] = [:]
    for task in ledger.tasks {
      // The same inputs `context-pack --role worker --design --ledger --task-id` builds from,
      // with the design read at designSha rather than from the working tree.
      let inputs = WorkerInputs(
        task: task, design: design, designSource: designSource,
        claims: ContextSource(label: "claims.jsonl", rawText: ""), citedClaimIDs: [],
        standards: ContextSource(label: "standards", rawText: ""), moduleKindAnchors: [])
      do {
        workerPacks[task.id] = try ContextPack.build(role: .worker, inputs: .worker(inputs))
      } catch {
        packFailures[task.id] = "\(error)"
      }
    }

    do throws(ReportContractViolation) {
      let findings = try PlanLintGraph.allFindings(
        design: design, designPath: plan.design, ledger: ledger,
        ledgerPath: store.plan.ledgerFile, graph: graph, workerPacks: workerPacks,
        bounds: config.plan)
      return Result(
        outcome: .checked(RuleRunResult(findings: findings, allowances: [])),
        packFailures: packFailures)
    } catch {
      return blocked("plan-lint: \(error)")
    }
  }

  private static func blocked(_ reason: String) -> Result {
    Result(outcome: .blocked(reason: reason), packFailures: [:])
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
      for (task, reason) in result.packFailures.sorted(by: { $0.key < $1.key }) {
        FileHandle.standardError.write(
          Data("swiftgate plan-lint: worker pack for `\(task)` not built: \(reason)\n".utf8))
      }
      return result.outcome
    }
  }
}
