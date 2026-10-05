import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `context-pack` in a brownfield clone, which has `config.toml` under its git common dir and no
/// `.swiftgate.toml`, design or module graph.
extension ContextPackRun {
  /// The flags a brownfield worker pack has no use for: it is cut from the plan's `PLAN.md` and
  /// `config.toml`, and carries the harness's brownfield rules in place of owned standards.
  private static let ownedWorkerFlags = [
    "--design", "--spec-page", "--standards", "--playbook", "--module-kind", "--claims",
    "--claim-id",
  ]

  /// The clone's brownfield config, or `nil` when its common dir holds none, which leaves every
  /// role to the owned profile as before.
  static func brownfieldConfig(root: URL) -> Result<BrownfieldConfig?, GatherFailure> {
    guard let common = ConfigLoader.commonDirectory(enclosing: root),
      FileManager.default.fileExists(
        atPath: common.appending(path: StateRootResolver.commonConfigFile).path)
    else { return .success(nil) }
    do throws(ProfileLoadError) {
      switch try ConfigLoader().loadProfile(repositoryRoot: root, commonDir: common) {
      case .brownfield(let config): return .success(config)
      case .owned, nil: return .success(nil)
      }
    } catch {
      return .failure(GatherFailure("can't tell this clone's profile: \(error)"))
    }
  }

  /// The worker's ledger entry, its `PLAN.md` section, its areas from `config.toml` and the
  /// harness's brownfield rules. `--ledger` may be absolute, since a brownfield plan lives under
  /// the git common dir; `PLAN.md` and the build run's returns are read beside it.
  static func gatherBrownfieldWorker(
    _ o: ContextPackGatherInputs, _ root: URL, _ config: BrownfieldConfig
  ) -> Result<Gathered, GatherFailure> {
    let given = [
      o.design != nil, o.specPage != nil, o.standards != nil, o.playbook != nil,
      !o.moduleKind.isEmpty, o.claims != nil, !o.claimID.isEmpty,
    ]
    let owned = zip(ownedWorkerFlags, given).filter(\.1).map(\.0)
    guard owned.isEmpty else {
      return .failure(
        GatherFailure(
          "\(owned.joined(separator: ", ")) don't apply in a brownfield clone: its worker pack "
            + "is cut from the plan's PLAN.md beside --ledger, config.toml's areas and the "
            + "harness's brownfield rules"))
    }
    guard let ledgerPath = o.ledger else {
      return .failure(GatherFailure("missing required option '--ledger <path>'"))
    }
    guard let taskID = o.taskID else {
      return .failure(GatherFailure("missing required option '--task-id <id>'"))
    }
    let ledgerFile =
      ledgerPath.hasPrefix("/") ? URL(filePath: ledgerPath) : root.appending(path: ledgerPath)
    let ledger: Ledger
    do {
      ledger = try LedgerJSON.decode(try Data(contentsOf: ledgerFile))
    } catch {
      return .failure(GatherFailure("can't read the ledger `\(ledgerPath)`: \(error)"))
    }
    guard let task = ledger.tasks.first(where: { $0.id == taskID }) else {
      return .failure(GatherFailure("task `\(taskID)` not found in `\(ledgerPath)`"))
    }

    let planDirectory = ledgerFile.deletingLastPathComponent()
    let planFile = planDirectory.appending(path: PlanFile.LivePlanSource.fileName)
    guard let planText = try? String(contentsOf: planFile, encoding: .utf8) else {
      return .failure(
        GatherFailure(
          "can't read \(PlanFile.LivePlanSource.fileName) beside `\(ledgerPath)`: a brownfield "
            + "worker pack is cut from the plan `plan import` read"))
    }

    guard let harnessRoot = o.harnessRoot else {
      return .failure(
        GatherFailure(
          "no harness root for the brownfield rules: run through the plugin's bin/swiftgate, "
            + "which sets SWIFTGATE_HARNESS_ROOT"))
    }
    let standardsFile = harnessRoot.appending(path: WorkerPackSources.standardsPath)
    guard let standardsText = try? String(contentsOf: standardsFile, encoding: .utf8) else {
      return .failure(
        GatherFailure("can't read the harness's \(WorkerPackSources.standardsPath)"))
    }

    var dependencyNotes: [DependencyReturnNotes] = []
    var deferred: [DeferredFinding] = []
    if let runID = o.buildRun {
      guard RunID.isValid(runID) else {
        return .failure(GatherFailure("--build-run `\(runID)` is not a valid run id"))
      }
      dependencyNotes = ContextPack.dependencyOrder(of: task.deps, in: ledger).map { dep in
        switch ContextPackTaskReturn.notes(
          forTask: dep, buildRun: runID, planDirectory: planDirectory)
        {
        case .success(let text): DependencyReturnNotes(taskID: dep, notes: text)
        case .failure: DependencyReturnNotes(taskID: dep, notes: nil)
        }
      }
      deferred = DeferredFinding.owned(
        by: task,
        in: ContextPackTaskReturn.deferrals(
          buildRun: runID, planDirectory: planDirectory, ledger: ledger))
    }

    let inputs = BrownfieldWorkerInputs(
      task: task,
      plan: ContextSource(label: PlanFile.LivePlanSource.fileName, rawText: planText),
      areas: config.areas,
      standards: ContextSource(
        label: "harness \(WorkerPackSources.standardsPath)", rawText: standardsText),
      dependencyNotes: dependencyNotes, deferred: deferred,
      layout: ConfigLoader.commonDirectory(enclosing: root).map {
        BrownfieldStateLayout(commonDir: $0, gitDir: $0)
      })
    return .success((.brownfieldWorker(inputs), [], o.key ?? taskID))
  }
}
