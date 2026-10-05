import ArgumentParser
import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// `qa run`'s behaviour, apart from argument parsing so tests drive it against a temp repository.
enum QARunRun {
  static let command = "qa run"
  /// How long 1 check may run before it is stopped and reads `red`.
  static let checkTimeout: Duration = .seconds(600)

  struct Options: Sendable, Equatable {
    var plan: String?
    var after: String?
    var atBase = false
    /// Every ready row, with each flow recorded and its logs saved.
    var final = false
    /// With `atBase`, only the rows this task writes, read from the checkout's prepared
    /// `.harness/qa/<plan>/` folder before `qa adopt` copies it into plan state.
    var preparedBy: String?
    /// With `preparedBy`, only this requirement's rows: a repair worker's red run of the checks
    /// it rewrote.
    var requirement: String?
    /// With `after`, run its rows in a scratch tree where the task's branch is merged into main's
    /// tip, before `build merge` lands it.
    var beforeMerge = false
    /// With `beforeMerge`, merge `after`'s fixer's branch in place of the task's.
    var fix = false
    /// With `beforeMerge`, more tasks whose branches merge after `after`'s, each counting as
    /// merged: a run over every task a row waits on, before the first of them merges.
    var alongside: [String] = []
    /// Where the JSON report goes, alone: no start line or other output reaches that file.
    var output: String?
  }

  struct Dependencies: Sendable {
    var checks: any QACheckRunning
    var ports: any QAPortAssigning
    /// `nil` makes scratch trees beside the repository, as `prove` does.
    var scratch: (any ScratchWorktrees)?
    /// `nil` writes through the checkout's telemetry setting.
    var events: (any HarnessEventWriting)?
    var now: @Sendable () -> Date
    var runIDSuffix: @Sendable () -> UInt32
    var newEventID: @Sendable () -> String
    var timeout: Duration = QARunRun.checkTimeout
    /// The device flow rows run on; `nil` leaves every flow row `unverified`.
    var flows: (any QAFlowSimulating)?
    /// The plugin root `qa lint` reads the pinned step schemas from.
    var pluginRoot: URL?
    /// What `--final` adds around each flow.
    var finalPass: QAFinalPass?
    /// Reads the result bundle an `xcode` area's `test:` row writes.
    var xcresults: any XcresultReader = LiveXcresultReader(runner: LiveProcessRunner())
    /// Clones of the simulator a `test:` row's `xcodebuild test` names; `nil` runs the command on
    /// the device as written.
    var testDevices: (any TestDeviceLeasing)?
    /// When the `swiftgate run` going on needs this run done; `nil` outside a box.
    var deadline: QARunDeadline?
    /// Merges the branch a `--before-merge` run checks into its scratch tree.
    var merger: any MergeRunner = LiveMergeRunner(runner: LiveProcessRunner())
    /// Told the run's id and where its report will be written, once its run directory exists
    /// and before any row runs, so a caller can wait on that file.
    var started: (@Sendable (_ runID: String, _ report: URL) -> Void)? = nil
    /// The build run's device the flow rows borrow; `nil`, or a refused loan, holds the run's own.
    var devices: (any QADeviceLending)?
    /// Where the run records itself while it runs, so `run checkout remove` stops it before its
    /// tree goes; `nil` leaves it unrecorded.
    var running: RunningGateRegistry? = nil
  }

  /// How long the scratch tree `tree` took since `asked`, and whether its app build is warm.
  static func treeStep(_ tree: URL, since asked: ContinuousClock.Instant) -> QASetupStep {
    let elapsed = ContinuousClock.now - asked
    return QASetupStep(
      step: .tree,
      milliseconds: Int(elapsed.components.seconds * 1000)
        + Int(elapsed.components.attoseconds / 1_000_000_000_000_000),
      reused: FileManager.default.fileExists(
        atPath: SimUpCommand.derivedDataDirectory(root: tree).path))
  }

  /// The trees a trial merge and the merge-base rows run in: pooled slots in a brownfield clone,
  /// where the app `sim up` builds stays warm from run to run, else throwaway trees beside the
  /// repository, as `prove` makes.
  static func scratchTrees(root: URL, common: String, plan: String) -> any ScratchWorktrees {
    let runner = LiveProcessRunner()
    let throwaway = LiveScratchWorktrees(runner: runner, repositoryRoot: root.path)
    guard BuildPresetCatalog.profile(root: root) == .brownfield else { return throwaway }
    return PooledScratchWorktrees(
      pool: WorktreePool(commonDirectory: common, plan: plan),
      workspace: LiveGitWorkspace(runner: runner, repositoryRoot: root.path),
      fallback: throwaway,
      prefer: { slot in
        FileManager.default.fileExists(
          atPath: SimUpCommand.derivedDataDirectory(
            root: URL(filePath: slot, directoryHint: .isDirectory)
          ).path)
      }, isAlive: SimulatorClones.processIsAlive)
  }

  /// Reads the plan's `validation.json` and ledger from the git common dir, runs the rows the
  /// plan picks in `root` (or, with `--at-base`, in a scratch tree at the merge base), and writes
  /// `qa/report.json` under a new run and 1 `qa.check` event per row.
  static func run(root: URL, options: Options, git: any Git, dependencies: Dependencies) async
    -> QAReport
  {
    func blocked(_ message: String, plan: String? = options.plan) -> QAReport {
      .blocked(
        message, plan: plan, after: options.after, atBase: options.atBase, final: options.final)
    }
    if options.final, options.atBase || options.after != nil {
      return blocked(
        "--final runs every ready row on the checkout, so it takes neither --at-base nor --after")
    }
    if options.preparedBy != nil, !options.atBase || options.after != nil || options.final {
      return blocked(
        "--prepared-by runs a validation task's checks at the merge base before `qa adopt`, so "
          + "it needs --at-base and takes neither --after nor --final")
    }
    if options.requirement != nil, options.preparedBy == nil {
      return blocked(
        "--requirement runs 1 requirement's rows of a repair worker's prepared folder, so it "
          + "needs --prepared-by")
    }
    if options.beforeMerge, options.after == nil || options.atBase || options.final {
      return blocked(
        "--before-merge runs the rows --after names on a trial merge of that task's branch, so "
          + "it needs --after and takes neither --at-base nor --final")
    }
    if options.fix, !options.beforeMerge {
      return blocked("--fix names the branch --before-merge merges, so it needs --before-merge")
    }
    if !options.alongside.isEmpty, !options.beforeMerge {
      return blocked(
        "more than 1 --after task merges their branches together in a trial merge, so it needs "
          + "--before-merge")
    }
    if options.final, dependencies.flows != nil, dependencies.finalPass == nil {
      return blocked("--final has no recorder to record its flows with")
    }
    let common: String
    let layout: PlanStateLayout
    do {
      common = try await git.commonDirectory()
      layout = try PlanStateLayout(commonDirectory: common)
    } catch {
      return blocked("resolving the plan state directory: \(error)")
    }
    let files = FileManager.default

    let slug: String
    if let named = options.plan {
      slug = named
    } else {
      let candidates: [String]
      do {
        candidates = try QAFiles.subdirectories(of: URL(filePath: layout.root)).filter {
          files.fileExists(atPath: "\(layout.root)/\($0)/\(ValidationTable.fileName)")
        }
      } catch {
        return blocked("listing the plans in \(layout.root): \(error)")
      }
      switch candidates.count {
      case 0:
        return .nothingToRun(
          "no plan under \(layout.root) holds a \(ValidationTable.fileName), so no row runs",
          plan: nil, after: options.after, atBase: options.atBase, final: options.final)
      case 1:
        slug = candidates[0]
      default:
        return blocked(
          "\(candidates.count) plans hold a \(ValidationTable.fileName): "
            + candidates.joined(separator: ", ") + "; name 1 with --plan")
      }
    }
    let plan: PlanStateLayout.Plan
    do {
      plan = try layout.plan(slug)
    } catch {
      return blocked("`\(slug)` is not a plan name")
    }
    guard files.fileExists(atPath: plan.directory) else {
      return blocked("no plan `\(slug)` under \(layout.root)", plan: slug)
    }
    let tablePath = plan.directory + "/" + ValidationTable.fileName
    guard let tableData = files.contents(atPath: tablePath) else {
      return .nothingToRun(
        "\(tablePath) is missing: the plan has no validation table, so no row runs", plan: slug,
        after: options.after, atBase: options.atBase, final: options.final)
    }
    let table: ValidationTable
    do throws(ValidationTableJSONError) {
      table = try ValidationTableJSON.decode(tableData)
    } catch {
      return blocked("\(tablePath) doesn't read: \(error)", plan: slug)
    }

    var notes: [String] = []
    var merged: Set<String>?
    var ended: [String: TaskStatus]?
    if !options.atBase || options.after != nil {
      let progress: LedgerProgress
      do throws(PlanStateStoreError) {
        progress = try PlanStateStore(plan: plan).ledgerProgress()
      } catch {
        return blocked("reading \(plan.ledgerFile): \(error)", plan: slug)
      }
      for after in (options.after.map { [$0] } ?? []) + options.alongside
      where !progress.contains(after) {
        return blocked(
          "--after `\(after)` names no task in \(plan.ledgerFile); no row ran", plan: slug)
      }
      if !options.atBase {
        let build = await buildEvents(slug: slug, git: git, notes: &notes)
        var mergedTasks = progress.merged(per: build)
        if options.after == nil, options.final || build?.finalGated == true {
          ended = progress.statuses
          let landed = await landedUnmerged(
            progress: progress, merged: mergedTasks, log: build, slug: slug, git: git)
          mergedTasks.formUnion(landed.map(\.task))
          notes += landed.map { landing in
            "\(landing.task) is \(landing.status.rawValue) in the ledger, but its branch tip "
              + "\(landing.tip.prefix(12)) is in HEAD, landed by another merge: its rows run"
          }
        }
        merged = mergedTasks
      }
    }
    // A task alongside that merged since the run was asked for is already on the branch the
    // trial merge starts from, and `build merge` deleted its branch.
    var alongsideTasks = options.alongside
    if let merged {
      let landed = alongsideTasks.filter { merged.contains($0) }
      alongsideTasks.removeAll { landed.contains($0) }
      for task in landed {
        notes.append(
          "`\(task)` has merged, so the trial merge starts from a branch that already holds it")
      }
    }
    var runPlan = QARunPlan.make(
      table: table, merged: merged, after: options.after, ended: ended, alongside: alongsideTasks)
    var prepared: String?
    if let writer = options.preparedBy {
      let relative = "\(QAAdoptRun.preparedDirectory)/\(slug)"
      let folder = root.appending(path: relative, directoryHint: .isDirectory).path
      var isDirectory: ObjCBool = false
      guard files.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue
      else {
        return blocked(
          "this checkout has no \(relative)/ folder, so --prepared-by has no checks to run",
          plan: slug)
      }
      runPlan = QARunPlan(
        entries: runPlan.entries.filter { $0.validation.writer == writer }, ended: runPlan.ended,
        leftUnverified: runPlan.leftUnverified)
      guard !runPlan.entries.isEmpty else {
        return blocked(
          "no row of \(tablePath) names `\(writer)` as its writer; no row ran", plan: slug)
      }
      if let requirement = options.requirement {
        runPlan = QARunPlan(
          entries: runPlan.entries.filter { $0.validation.requirement == requirement },
          ended: runPlan.ended, leftUnverified: runPlan.leftUnverified)
        guard !runPlan.entries.isEmpty else {
          return blocked(
            "no row of \(tablePath) that `\(writer)` writes checks `\(requirement)`; no row ran",
            plan: slug)
        }
      }
      prepared = folder
      notes.append(
        "checks read from \(relative)/ before qa adopt: only the \(runPlan.entries.count) rows "
          + "`\(writer)` writes"
          + (options.requirement.map { " for `\($0)`" } ?? "") + " ran")
    }

    let digests = Dictionary(
      uniqueKeysWithValues: runPlan.entries.map { entry in
        let check = entry.validation.check
        let file = Checks.checkFile(
          check, preparedDirectory: prepared, planDirectory: plan.directory)
        var isDirectory: ObjCBool = false
        let bytes =
          files.fileExists(atPath: file.path, isDirectory: &isDirectory) && !isDirectory.boolValue
          ? files.contents(atPath: file.path) : nil
        return (
          entry.row, QAAtBaseRun.digest(layer: entry.validation.layer, check: check, file: bytes)
        )
      })
    var reused: [Int: QACheckOutcome] = [:]
    if options.atBase, prepared == nil {
      let recordFile = "\(plan.directory)/\(QAReport.directory)/\(QAAtBaseRun.fileName)"
      if let data = files.contents(atPath: recordFile) {
        do {
          let record = try QAAtBaseRunJSON.decode(data)
          let reuse = record.reuse(in: runPlan, digests: digests)
          reused = reuse.outcomes
          notes += reuseNotes(record: record, reuse: reuse)
        } catch {
          notes.append("\(recordFile) doesn't read, so every row ran: \(error)")
        }
      }
    }

    // What each row took at the merge base, which a box's deadline measures it against.
    var expected: [Int: Int] = [:]
    if dependencies.deadline != nil,
      let data = files.contents(
        atPath: "\(plan.directory)/\(QAReport.directory)/\(QAAtBaseRun.fileName)"),
      let record = try? QAAtBaseRunJSON.decode(data)
    {
      for entry in runPlan.entries {
        let validation = entry.validation
        expected[entry.row] =
          record.rows.first {
            $0.requirement == validation.requirement && $0.layer == validation.layer
              && $0.check == validation.check
          }?.milliseconds
      }
    }

    let runID = RunID.make(startedAt: dependencies.now(), suffix: dependencies.runIDSuffix())
    let qaDirectory: URL
    do {
      qaDirectory = try RunStore(worktreeRoot: root).runDirectory(for: runID)
        .appending(path: QAReport.directory, directoryHint: .isDirectory)
      try files.createDirectory(at: qaDirectory, withIntermediateDirectories: true)
    } catch {
      return blocked("making the run directory for \(runID): \(error)", plan: slug)
    }
    dependencies.started?(runID, qaDirectory.appending(path: QAReport.fileName))
    let running = dependencies.running
    let record = running?.register(
      pid: getpid(), toplevel: root.path(percentEncoded: false),
      kind: RunningGateRegistry.qaRunKind, now: dependencies.now())
    defer { if let record { running?.unregister(record) } }
    let events = dependencies.events ?? TelemetryOptIn.writer(root: root)
    // A build run's device stays booted across its qa runs, each queueing for it in turn; a run
    // outside a build holds its own for its rows. A run no flow row of which drives the device
    // never queues behind another run's rows for it.
    let loan: QADeviceLoan =
      dependencies.flows == nil || !runPlan.drivesDevice(reused: Set(reused.keys))
      ? .own
      : await dependencies.devices?.borrow(
        plan: slug, until: dependencies.deadline,
        waiting: {
          // Written as the wait starts, so a watcher sees the run queued, not stalled.
          try? events?.append(
            contentsOf: [
              HarnessEvent(
                eventID: dependencies.newEventID(), time: dependencies.now(), runID: runID,
                head: nil, source: HarnessEventSource(route: nil),
                payload: .qaSetup(
                  QASetupEvent(
                    plan: slug, row: nil, atBase: options.atBase,
                    setup: QASetupStep(step: .deviceWait, milliseconds: 0))))
            ])
        }) ?? .own
    let borrowed: BorrowedDevice?
    var deviceWait: QASetupStep?
    var deviceRefused: String?
    switch loan {
    case .borrowed(let device, let waited):
      borrowed = device
      deviceWait = waited.map { QASetupStep(step: .deviceWait, milliseconds: $0) }
    case .own:
      borrowed = nil
    case .refused(let message, let waited):
      borrowed = nil
      deviceWait = QASetupStep(step: .deviceWait, milliseconds: waited)
      deviceRefused = message
    }
    defer { borrowed?.release() }
    let hold =
      borrowed?.hold
      ?? QAFlowDeviceHold(
        runID: "\(runID)-device",
        directory: qaDirectory.appending(path: "device", directoryHint: .isDirectory),
        slotDeadline: dependencies.deadline)
    let checks = Checks(
      planDirectory: plan.directory, preparedDirectory: prepared, qaDirectory: qaDirectory,
      dependencies: dependencies,
      runID: runID, plan: runPlan, atBase: options.atBase, reused: reused, expected: expected,
      areas: testAreas(root: root, common: common, table: table),
      testDevices: dependencies.testDevices.map(HeldTestDevices.init(leases:)),
      deviceRefused: deviceRefused,
      flows: dependencies.flows.map { simulator in
        // An --after run's flows pass or fail before a merge or cutoff the final pass may not
        // reach, so each is recorded too, when the recorder is free at once.
        QAFlowRunner(
          simulator: simulator, finalPass: options.final ? dependencies.finalPass : nil,
          recorder: options.after != nil && !options.atBase
            ? dependencies.finalPass?.recorder.withoutWaiting() : nil,
          hold: hold)
      })

    // Each row's qa.setup, qa.flow and qa.check go out as the row ends, so a watcher sees the
    // run's progress; a row whose events couldn't be written goes again with the run's last events.
    let written = Mutex<Set<Int>>([])
    let rowEnded: @Sendable (QARow, String?) async -> Void = {
      [
        newEventID = dependencies.newEventID, now = dependencies.now, atBase = options.atBase,
        repairProof = options.preparedBy != nil && options.requirement != nil, checks
      ] row, head in
      guard let events else { return }
      let time = now()
      func event(_ payload: HarnessEventPayload) -> HarnessEvent {
        HarnessEvent(
          eventID: newEventID(), time: time, runID: runID, head: head,
          source: HarnessEventSource(route: nil), payload: payload)
      }
      let setup = (await checks.setupSteps())[row.row] ?? []
      let flow = (await checks.flowRecords())[row.row]
      do {
        try events.append(
          contentsOf: setup.map {
            event(.qaSetup(QASetupEvent(plan: slug, row: row.row, atBase: atBase, setup: $0)))
          }
            + (flow.map {
              [
                event(
                  .qaFlow(
                    QAFlowEvent(
                      plan: slug, row: row.row, requirement: row.requirement, atBase: atBase,
                      record: $0)))
              ]
            } ?? [])
            + [
              event(
                .qaCheck(
                  QACheckEvent(plan: slug, row: row, atBase: atBase, repairProof: repairProof)))
            ])
        written.withLock { _ = $0.insert(row.row) }
      } catch {
        return
      }
    }

    let rows: [QARow]
    let commit: String?
    var atBaseRecord: String?
    var trialMerge: QATrialMerge?
    /// The scratch tree's setup, when the rows ran in one.
    var treeSetup: QASetupStep?
    if options.beforeMerge, let after = options.after {
      let names: TaskWorktree
      let tip: String
      let base: String
      var alongside: [QATrialMerge.Branch] = []
      do {
        let profile = BuildPresetCatalog.profile(root: root)
        names = try TaskWorktree(
          commonDirectory: common, plan: slug, task: options.fix ? "fix-\(after)" : after,
          profile: profile)
        guard let found = try await git.revision("refs/heads/\(names.branch)") else {
          return blocked(
            "branch \(names.branch) doesn't exist, so there is nothing to merge", plan: slug)
        }
        tip = found
        let checked =
          alongsideTasks.isEmpty ? nil : await standingChecks(slug: slug, root: root, git: git)
        if !alongsideTasks.isEmpty, checked == nil {
          notes.append(
            "the plan has no build run whose events read, so each branch alongside is taken at "
              + "its tip")
        }
        for task in alongsideTasks {
          let other = try TaskWorktree(
            commonDirectory: common, plan: slug, task: task, profile: profile)
          guard let found = try await git.revision("refs/heads/\(other.branch)") else {
            return blocked(
              "branch \(other.branch) doesn't exist, so there is nothing to merge", plan: slug)
          }
          // A branch alongside lands only through its own merge, which needs its checked return.
          var taken = found
          if let checked {
            guard let commit = checked.commits[task] else {
              return blocked(
                "`\(task)` has no return checked ready to merge that still stands in build run "
                  + "\(checked.runID): it is still at work, or its return went back to work, so "
                  + "no trial merge takes \(other.branch); run without it", plan: slug)
            }
            if commit != found {
              notes.append(
                "\(other.branch) is at \(found.prefix(12)), past the commit its return was checked "
                  + "at; the trial merge took \(commit.prefix(12))")
            }
            taken = commit
          }
          alongside.append(QATrialMerge.Branch(task: task, branch: other.branch, tip: taken))
        }
        guard let main = try await git.revision("refs/heads/\(names.baseBranch)") else {
          return blocked("branch \(names.baseBranch) doesn't exist to merge into", plan: slug)
        }
        base = main
      } catch {
        return blocked("reading the branch to merge: \(error)", plan: slug)
      }
      let scratch =
        dependencies.scratch ?? scratchTrees(root: root, common: common, plan: slug)
      let merger = dependencies.merger
      let ran: TrialMergeRun
      let asked = ContinuousClock.now
      do throws(ScratchWorktreeError) {
        // The rows' shared device goes back while the tree its holder runs in still exists.
        ran = try await scratch.withScratchTree(
          ScratchTreeRequest(revision: base, revertTo: base, copiedPaths: [], revertedPaths: [])
        ) { tree in
          treeSetup = Self.treeStep(tree, since: asked)
          var commit = base
          var into = names.baseBranch
          // Each branch merges on top of the ones before it, so the rows see them all at once,
          // each at the commit read above, whatever its branch has moved to since.
          for (merging, revision) in [(names.branch, tip)] + alongside.map({ ($0.branch, $0.tip) })
          {
            let outcome: MergeOutcome
            do throws(GitWorkspaceError) {
              outcome = try await merger.merge(
                revision, message: "Merge: \(merging) before build merge", in: tree.path)
            } catch {
              return .failed("\(error)")
            }
            switch outcome {
            case .merged(let made):
              commit = made
              into += " and \(merging)"
            case .conflicted(let files):
              let rows = await runPlan.execute(
                atBase: false,
                check: { _ in
                  QACheckOutcome(
                    result: .unverified,
                    message: "not run: \(merging) conflicts with \(into) in "
                      + files.joined(separator: ", ") + "; build merge cuts the fix worktree")
                }, rowEnded: { await rowEnded($0, nil) })
              return .conflicted(files: files, rows: rows)
            }
          }
          // A run whose trial merge made this same tree already proved the rows it passed.
          var onTree = checks
          var treeNotes: [String] = []
          let merged: String?
          do throws(GitWorkspaceError) {
            merged = try await merger.tree(of: commit, in: tree.path)
          } catch {
            merged = nil
            treeNotes.append("no earlier run's rows reused: reading the merge's tree: \(error)")
          }
          if let merged,
            let record = QAMergedTreeRun.newest(
              on: merged, in: QARunHistory.mergedTreeRuns(worktree: root))
          {
            let reuse = record.run.reuse(in: runPlan, digests: digests, results: [.pass])
            onTree.reused.merge(reuse.outcomes) { kept, _ in kept }
            treeNotes.append(
              "qa run \(record.run.runID) ran on the same merged tree \(merged.prefix(12))")
            treeNotes += reuseNotes(record: record.run, reuse: reuse)
          }
          let rows = await runPlan.execute(
            atBase: false, check: { await onTree.run($0, in: tree.path) },
            rowEnded: { [commit] in await rowEnded($0, commit) })
          return .merged(
            commit: commit, tree: merged, rows: rows, notes: treeNotes,
            released: await onTree.finishFlows())
        }
      } catch {
        return blocked("making a scratch worktree at \(base): \(error)", plan: slug)
      }
      switch ran {
      case .failed(let message):
        return blocked(
          "merging \(names.branch) into \(base) in a scratch tree: \(message)", plan: slug)
      case .conflicted(let files, let ran):
        rows = ran
        commit = nil
        trialMerge = QATrialMerge(
          branch: names.branch, tip: tip, base: base, conflicts: files, alongside: alongside)
      case .merged(let merged, let tree, let ran, let treeNotes, let released):
        rows = ran
        commit = merged
        notes += treeNotes + released
        trialMerge = QATrialMerge(
          branch: names.branch, tip: tip, base: base, alongside: alongside)
        if let tree {
          let record = QAMergedTreeRun(
            tree: tree,
            run: QAAtBaseRun(
              runID: runID, preparedBy: after, commit: merged, rows: ran, digests: digests))
          let file = qaDirectory.appending(path: QAMergedTreeRun.fileName)
          do {
            try QAFiles.write(try record.encoded(), to: file)
          } catch {
            notes.append(
              "\(QAMergedTreeRun.fileName) not written, so a later run on this tree runs every "
                + "row again: \(error)")
          }
        }
      }
    } else if options.atBase {
      let main =
        BuildPresetCatalog.profile(root: root) == .brownfield
        ? BrownfieldRunReport.planBranch(slug: slug) : TaskWorktree.base
      let base: String
      do {
        guard let found = try await git.mergeBase("HEAD", main) else {
          return blocked("HEAD and \(main) share no commit, so there is no merge base", plan: slug)
        }
        base = found
      } catch {
        return blocked("finding the merge base of HEAD and \(main): \(error)", plan: slug)
      }
      let scratch =
        dependencies.scratch ?? scratchTrees(root: root, common: common, plan: slug)
      if runPlan.entries.allSatisfy({ reused[$0.row] != nil || !$0.waitingOn.isEmpty }) {
        rows = await runPlan.execute(
          atBase: true, check: { await checks.run($0, in: root.path) },
          rowEnded: { await rowEnded($0, base) })
      } else {
        let asked = ContinuousClock.now
        do throws(ScratchWorktreeError) {
          // The rows' shared device goes back while the tree its holder runs in still exists.
          let ran = try await scratch.withScratchTree(
            ScratchTreeRequest(revision: base, revertTo: base, copiedPaths: [], revertedPaths: [])
          ) { tree in
            treeSetup = Self.treeStep(tree, since: asked)
            let rows = await runPlan.execute(
              atBase: true, check: { await checks.run($0, in: tree.path) },
              rowEnded: { await rowEnded($0, base) })
            return (rows: rows, released: await checks.finishFlows())
          }
          rows = ran.rows
          notes += ran.released
        } catch {
          return blocked("making a scratch worktree at \(base): \(error)", plan: slug)
        }
      }
      commit = base
      if let writer = options.preparedBy, let prepared {
        let record = QAAtBaseRun(
          runID: runID, preparedBy: writer, commit: base, rows: rows, digests: digests)
        let file = URL(filePath: prepared).appending(path: QAAtBaseRun.fileName)
        do {
          let data: Data
          do {
            data = try QAAtBaseRunJSON.encode(record)
          } catch {
            throw QAFilesError(path: file.path, reason: "encoding: \(error)")
          }
          try QAFiles.write(data, to: file)
          atBaseRecord = file.path
        } catch {
          notes.append(
            "\(QAAtBaseRun.fileName) not written, so the at-base run after qa adopt runs "
              + "every row again: \(error)")
        }
      }
    } else {
      do {
        commit = try await git.revision("HEAD")
      } catch {
        commit = nil
        notes.append("the report names no commit: reading HEAD failed: \(error)")
      }
      // A trial merge that made this same tree already proved the rows it passed.
      var onHead = checks
      if options.final, commit != nil {
        do throws(GitWorkspaceError) {
          let tree = try await dependencies.merger.tree(of: "HEAD", in: root.path)
          if let record = QAMergedTreeRun.newest(
            on: tree, in: QARunHistory.mergedTreeRuns(worktree: root))
          {
            let reuse = record.run.reuse(in: runPlan, digests: digests, results: [.pass])
            onHead.reused.merge(reuse.outcomes) { kept, _ in kept }
            notes.append(
              "qa run \(record.run.runID) ran on this same tree \(tree.prefix(12)) in a trial "
                + "merge")
            notes += reuseNotes(record: record.run, reuse: reuse)
          }
        } catch {
          notes.append("no earlier run's rows reused: reading HEAD's tree: \(error)")
        }
      }
      rows = await runPlan.execute(
        atBase: false, check: { await onHead.run($0, in: root.path) },
        rowEnded: { [commit] in await rowEnded($0, commit) })
    }
    notes += await checks.finishFlows()
    await checks.testDevices?.releaseAll()
    let flowRecords = await checks.flowRecords()
    let gaps = await checks.gaps()
    let rowSetup = await checks.setupSteps()
    let unwritten = written.withLock { written in rows.filter { !written.contains($0.row) } }
    let setupEvents: [QASetupEvent] =
      ([deviceWait, treeSetup].compactMap { $0 }.map {
        QASetupEvent(plan: slug, row: nil, atBase: options.atBase, setup: $0)
      })
      + unwritten.flatMap { row -> [QASetupEvent] in
        (rowSetup[row.row] ?? []).map {
          QASetupEvent(plan: slug, row: row.row, atBase: options.atBase, setup: $0)
        }
      }

    if let events {
      let time = dependencies.now()
      do {
        try events.append(
          contentsOf: unwritten.map { row in
            HarnessEvent(
              eventID: dependencies.newEventID(), time: time, runID: runID, head: commit,
              source: HarnessEventSource(route: nil),
              payload: .qaCheck(
                QACheckEvent(
                  plan: slug, row: row, atBase: options.atBase,
                  repairProof: options.preparedBy != nil && options.requirement != nil)))
          }
            + unwritten.compactMap { row in
              flowRecords[row.row].map { record in
                HarnessEvent(
                  eventID: dependencies.newEventID(), time: time, runID: runID, head: commit,
                  source: HarnessEventSource(route: nil),
                  payload: .qaFlow(
                    QAFlowEvent(
                      plan: slug, row: row.row, requirement: row.requirement,
                      atBase: options.atBase, record: record)))
              }
            }
            + setupEvents.map { event in
              HarnessEvent(
                eventID: dependencies.newEventID(), time: time, runID: runID, head: commit,
                source: HarnessEventSource(route: nil), payload: .qaSetup(event))
            })
      } catch {
        notes.append("qa.check, qa.flow and qa.setup events not written: \(error)")
      }
    } else {
      notes.append("qa.check events not written: \(root.path) has no config that loads")
    }

    let report = QAReport(
      runID: runID, plan: slug, after: options.after, atBase: options.atBase,
      final: options.final, settled: ended != nil, commit: commit, rows: rows, gaps: gaps,
      notes: notes, reasonOnly: table.unitOnly.count, checkableRows: table.rows.count,
      atBaseRecord: atBaseRecord, trialMerge: trialMerge)
    let reportFile = qaDirectory.appending(path: QAReport.fileName)
    do {
      let data: Data
      do {
        data = try QAReportJSON.encode(report)
      } catch {
        throw QAFilesError(path: reportFile.path, reason: "encoding: \(error)")
      }
      try QAFiles.write(data, to: reportFile)
    } catch {
      return report.adding(notes: ["\(QAReport.fileName) not written: \(error)"])
    }
    return report
  }

  /// What a `--before-merge` run's scratch tree came to.
  private enum TrialMergeRun: Sendable {
    /// The merge commit, its tree when it read, the rows run on it, what was reused, and the
    /// shared device's release notes.
    case merged(
      commit: String, tree: String?, rows: [QARow], notes: [String], released: [String])
    /// The files the merge conflicted in, and the ready rows read unverified.
    case conflicted(files: [String], rows: [QARow])
    case failed(String)
  }

  /// The plan's newest build run's events; `nil`, with a note when reading failed, when it has
  /// none, so only the ledger says what merged.
  /// The commit each task's standing return check names in the plan's newest build run, as
  /// ``BuildEventLog/standingCheck(task:retriedAt:)`` reads it with the run's halts answered
  /// retry; `nil` when the plan has no build run, or its events don't read.
  static func standingChecks(slug: String, root: URL, git: any Git) async
    -> (runID: String, commits: [String: String])?
  {
    guard let store = try? await BuildRunStore.latest(plan: slug, git: git),
      let log = try? store.events()
    else { return nil }
    let retried = BuildHalts.retried(
      in: (try? BuildHaltLog(root: root).events()) ?? [], buildRun: store.runID)
    var commits: [String: String] = [:]
    for task in Set(log.events.compactMap(\.task)) {
      if let commit = log.standingCheck(task: task, retriedAt: retried[task])?.commit {
        commits[task] = commit
      }
    }
    return (store.runID, commits)
  }

  private static func buildEvents(slug: String, git: any Git, notes: inout [String]) async
    -> BuildEventLog?
  {
    do throws(BuildRunStoreError) {
      guard let store = try await BuildRunStore.latest(plan: slug, git: git) else { return nil }
      let log = try store.events()
      if !log.damage.isEmpty {
        notes.append(
          "build run \(store.runID)'s events have \(log.damage.count) unreadable line(s); "
            + "a merge on them isn't counted")
      }
      return log
    } catch {
      notes.append(
        "the build run's events didn't read, so only the ledger says what merged: \(error)")
      return nil
    }
  }

  /// A task the ledger doesn't count as merged whose branch tip `HEAD` holds anyway: another
  /// task's merge landed it, as a fixer's branch that took it in does.
  struct Landing: Sendable, Equatable {
    let task: String
    let status: TaskStatus
    let tip: String
  }

  /// The tasks outside `merged` whose branch tip is in `HEAD` and is no commit the plan branch
  /// itself stood at in `log`: a branch with no commits of its own points at one of those, and
  /// landed nothing. With no build events, none.
  private static func landedUnmerged(
    progress: LedgerProgress, merged: Set<String>, log: BuildEventLog?, slug: String,
    git: any Git
  ) async -> [Landing] {
    guard let log else { return [] }
    var planCommits: Set<String> = []
    for event in log.events {
      switch event {
      case .merge(let merge): planCommits.formUnion([merge.preCommit, merge.postCommit])
      case .undo(let undo): planCommits.formUnion([undo.fromCommit, undo.toCommit])
      case .transition, .gate, .returnCheck, .finish, .rowsUnverified: continue
      }
    }
    var landed: [Landing] = []
    for task in progress.tasks where !merged.contains(task.id) {
      guard let tip = try? await git.revision("refs/heads/\(slug)/\(task.id)"),
        !planCommits.contains(tip),
        (try? await git.isAncestor(tip, of: "HEAD")) == true
      else { continue }
      landed.append(Landing(task: task.id, status: task.status, tip: tip))
    }
    return landed
  }

  /// 1 note naming the rows taken from `record`, and 1 per ready row that ran instead.
  private static func reuseNotes(record: QAAtBaseRun, reuse: QAAtBaseRun.Reuse) -> [String] {
    let taken = reuse.outcomes.keys.sorted()
    let named = taken.map(String.init).joined(separator: ", ")
    var notes: [String] = []
    if !taken.isEmpty {
      notes.append(
        "\(taken.count) \(taken.count == 1 ? "row" : "rows") (\(named)) reused from qa run "
          + "\(record.runID) by \(record.preparedBy): each check is byte-identical to the one "
          + "it ran")
    }
    notes += reuse.reasons.keys.sorted().compactMap { row in
      reuse.reasons[row].map { "row \(row) ran: \($0)" }
    }
    return notes
  }

  /// The areas a `test:` acceptance row resolves in: the brownfield config's, read only when a
  /// row is in that form.
  private static func testAreas(root: URL, common: String, table: ValidationTable)
    -> Result<[BrownfieldArea], AcceptanceTestUnresolved>
  {
    guard
      table.rows.contains(where: {
        $0.layer == .acceptance && AcceptanceTestReference.parse($0.check) != nil
      })
    else { return .success([]) }
    let loaded: LoadedConfig?
    do {
      loaded = try ConfigLoader().loadProfile(
        repositoryRoot: root, commonDir: URL(filePath: common, directoryHint: .isDirectory))
    } catch {
      return .failure(AcceptanceTestUnresolved(reason: "the config doesn't load: \(error)"))
    }
    guard case .brownfield(let config)? = loaded else {
      return .failure(
        AcceptanceTestUnresolved(
          reason:
            "a `test:` check runs through a brownfield area's test command, and this "
            + "repository has no brownfield config"))
    }
    return .success(config.areas)
  }

  /// Runs 1 row's check and saves what it printed: an acceptance or state row's command or
  /// script, or a flow row through ``QAFlowRunner``.
  private struct Checks: Sendable {
    let planDirectory: String
    /// The checkout's `.harness/qa/<plan>/` a `--prepared-by` run reads checks from, which holds
    /// what plan state's `qa/` holds once adopted.
    let preparedDirectory: String?
    let qaDirectory: URL
    let dependencies: Dependencies
    let runID: String
    let plan: QARunPlan
    let atBase: Bool
    /// The recorded outcomes of the rows a prepared at-base run, or a before-merge run on the
    /// same merged tree, proved, by row.
    var reused: [Int: QACheckOutcome]
    /// What each row took in the recorded at-base run, in milliseconds, by row.
    let expected: [Int: Int]
    /// What a `test:` acceptance row resolves in.
    let areas: Result<[BrownfieldArea], AcceptanceTestUnresolved>
    /// The clones `test:` rows run on, held across the acceptance rows and given back before the
    /// first flow row brings its own device up.
    let testDevices: HeldTestDevices?
    /// Why the flow rows have no device: the build run's stayed borrowed past the deadline.
    let deviceRefused: String?
    let flows: QAFlowRunner?
    /// State rows a flow row already ran on its device, by row.
    let stateResults = StateResults()

    final class StateResults: Sendable {
      private let results = Mutex<[Int: QACheckOutcome]>([:])

      func store(_ outcome: QACheckOutcome, row: Int) {
        results.withLock { $0[row] = outcome }
      }

      func take(row: Int) -> QACheckOutcome? {
        results.withLock { $0.removeValue(forKey: row) }
      }
    }

    /// Where a row's `qa/<name>` check is read from.
    func checkFile(_ check: String) -> URL {
      Self.checkFile(check, preparedDirectory: preparedDirectory, planDirectory: planDirectory)
    }

    static func checkFile(_ check: String, preparedDirectory: String?, planDirectory: String)
      -> URL
    {
      if let preparedDirectory, check.hasPrefix("qa/") {
        return URL(filePath: preparedDirectory).appending(path: String(check.dropFirst(3)))
      }
      return URL(filePath: planDirectory).appending(path: check)
    }

    /// Gives back the device the flow rows shared, if they took one.
    func finishFlows() async -> [String] {
      await flows?.finish() ?? []
    }

    func flowRecords() async -> [Int: QAFlowRecord] {
      await flows?.records ?? [:]
    }

    func setupSteps() async -> [Int: [QASetupStep]] {
      await flows?.setup ?? [:]
    }

    func gaps() async -> [QAEvidenceGap] {
      await flows?.gaps ?? []
    }

    func run(_ entry: QARunPlan.Entry, in workingDirectory: String) async -> QACheckOutcome {
      if let outcome = reused[entry.row] { return outcome }
      let row = entry.validation
      if row.layer != .acceptance { await testDevices?.releaseAll() }
      if row.layer == .flow {
        return await flow(entry, in: workingDirectory)
      }
      if row.layer == .state, let ran = stateResults.take(row: entry.row) {
        return ran
      }
      if let deadline = dependencies.deadline,
        case .refuse(let message) = deadline.admit(
          layer: row.layer, expectedMilliseconds: expected[entry.row], now: dependencies.now())
      {
        return QACheckOutcome(result: .unverified, message: message)
      }
      // A state check reads what its flow left on the device; with none up, its exit means nothing.
      if row.layer == .state,
        let flow = plan.entries.last(where: {
          $0.validation.layer == .flow && $0.validation.requirement == row.requirement
        })
      {
        return QACheckOutcome(
          result: .unverified,
          message: "not run: flow row \(flow.row) `\(flow.validation.check)` for "
            + "\(row.requirement) brought no device up")
      }
      return await command(entry, in: workingDirectory, device: [:])
    }

    /// The ready state rows the flow row `entry` runs on its device: its requirement's, when no
    /// later flow row has the same requirement.
    private func stateRows(of entry: QARunPlan.Entry) -> [QARunPlan.Entry] {
      let requirement = entry.validation.requirement
      let later = plan.entries.drop { $0.row != entry.row }.dropFirst()
        .filter { $0.validation.requirement == requirement }
      guard !later.contains(where: { $0.validation.layer == .flow }) else { return [] }
      return later.filter { $0.validation.layer == .state && $0.waitingOn.isEmpty }
    }

    private func flow(_ entry: QARunPlan.Entry, in workingDirectory: String) async
      -> QACheckOutcome
    {
      guard let flows else {
        return QACheckOutcome(result: .unverified, message: QARunPlan.flowRunnerMissing)
      }
      if let deviceRefused {
        return QACheckOutcome(result: .unverified, message: "not run: \(deviceRefused)")
      }
      let row = entry.validation
      let stepsFile = checkFile(row.check)
      let worktree = URL(filePath: workingDirectory, directoryHint: .isDirectory)
      let lint = QALintRun.run(
        files: [stepsFile.path], root: worktree, pluginRoot: dependencies.pluginRoot)
      let name = String(Self.evidenceName(entry).dropLast(".txt".count))
      let states = stateRows(of: entry)
      return await flows.run(
        QAFlowRow(
          row: entry.row, requirement: row.requirement, stepsFile: stepsFile, worktree: worktree,
          directory: qaDirectory.appending(path: name, directoryHint: .isDirectory),
          relativeDirectory: "\(QAReport.directory)/\(name)", runID: "\(runID)-row\(entry.row)",
          atBase: atBase),
        lint: lint
      ) { device in
        for state in states {
          stateResults.store(
            await command(state, in: workingDirectory, device: device), row: state.row)
        }
      }
    }

    /// Runs an acceptance row's command or a state row's script, with `device`'s variables
    /// when its flow's device is up.
    private func command(
      _ entry: QARunPlan.Entry, in workingDirectory: String, device: [String: String]
    ) async -> QACheckOutcome {
      let row = entry.validation
      let port: Int
      do {
        port = try dependencies.ports.assignPort()
      } catch {
        return QACheckOutcome(
          result: .unverified, message: "not run: no port for QA_PORT: \(error)")
      }
      let name = Self.evidenceName(entry)
      let program: QACheckRequest.Program
      var directory = workingDirectory
      var shown = row.check
      var reference = row.check
      // Where an acceptance check may write a test report, which must then show a test ran.
      let junit =
        row.layer == .acceptance
        ? qaDirectory.appending(path: name.dropLast(".txt".count) + ".junit.xml").path : nil
      var resultBundle: String?
      var notes: [String] = []
      if let junit, let test = AcceptanceTestReference.parse(row.check) {
        reference = test.id
        let bundle = qaDirectory.appending(path: name.dropLast(".txt".count) + ".xcresult").path
        switch areas.flatMap({ test.resolve(in: $0, junitPath: junit, resultBundlePath: bundle) })
        {
        case .success(let resolved):
          var command = resolved.command
          if let testDevices, let destination = XcodeTestDestination.simulator(in: command) {
            switch await testDevices.device(for: destination) {
            case .success(let device):
              command = XcodeTestDestination.leased(command, udid: device.udid) ?? command
            case .failure(let error):
              notes.append(
                "ran on the shared \(destination.device), with no clone to run on: \(error.reason)")
            }
          }
          program = .command(command)
          shown = command
          resultBundle = resolved.resultBundlePath
          if resolved.root != "." { directory += "/" + resolved.root }
        case .failure(let unresolved):
          return QACheckOutcome(result: .unverified, message: "not run: \(unresolved.reason)")
        }
      } else {
        let script = checkFile(row.check).path
        var isDirectory: ObjCBool = false
        program =
          !row.check.hasPrefix("/")
            && FileManager.default.fileExists(atPath: script, isDirectory: &isDirectory)
            && !isDirectory.boolValue
          ? .script(path: script) : .command(row.check)
      }
      var environment = [
        "QA_PORT": "\(port)", "QA_DIR": preparedDirectory ?? planDirectory + "/qa",
        "QA_EVIDENCE_DIR": qaDirectory.path,
      ]
      if let junit {
        JUnitReportFiles.clear(at: junit)
        environment[QACheckJudgement.reportVariable] = junit
      }
      let request = QACheckRequest(
        program: program, workingDirectory: directory,
        environment: environment.merging(device, uniquingKeysWith: { own, _ in own }),
        timeout: timeout())
      var output = await dependencies.checks.run(request)
      if case .exited(let code) = output.exit, code != 0,
        let launch = TestRunnerLaunchFailure.reason(in: output.stdout + "\n" + output.stderr)
      {
        // `xcodebuild` refuses to write over a result bundle, and the retry's report must be its own.
        if let resultBundle { try? FileManager.default.removeItem(atPath: resultBundle) }
        if let junit { JUnitReportFiles.clear(at: junit) }
        notes.append("retried once after \(launch)")
        output = await dependencies.checks.run(request)
      }

      var exitStatus: Int?
      let end: QACheckJudgement.End
      let status: String
      switch output.exit {
      case .exited(let code):
        exitStatus = Int(code)
        end = .exited(code)
        status = "\(code)"
      case .signaled(let signal):
        end = .signaled(signal)
        status = "killed by signal \(signal)"
      case .timedOut(let after):
        end = .timedOut(after)
        status = "timed out after \(after)"
      case .launchFailed(let reason):
        end = .launchFailed(reason)
        status = "not started: \(reason)"
      }
      var bundle: QACheckJudgement.ResultBundle?
      if let resultBundle {
        do {
          let contents = try await dependencies.xcresults.read(bundlePath: resultBundle)
          bundle = .tests(contents.testResults)
        } catch {
          bundle = .unread(error.message)
        }
      }
      let judgement = QACheckJudgement.judge(
        QACheckJudgement.Input(
          end: end, stdout: output.stdout, stderr: output.stderr,
          report: junit.flatMap(JUnitReportFiles.read(at:)), resultBundle: bundle,
          reference: reference, atBase: atBase,
          roots: [directory, workingDirectory, qaDirectory.path, planDirectory]
            + (preparedDirectory.map { [$0] } ?? [])))
      let result = judgement.result
      let text =
        "$ \(shown)\nQA_PORT=\(port)\nexit: \(status)\n"
        + notes.map { "note: \($0)\n" }.joined()
        + "--- stdout ---\n\(output.stdout)\n--- stderr ---\n\(output.stderr)\n"
      var message = ([judgement.message] + notes).joined(separator: "; ")
      var evidence: [String] = []
      do {
        try QAFiles.write(Data(text.utf8), to: qaDirectory.appending(path: name))
        evidence = ["\(QAReport.directory)/\(name)"]
      } catch {
        message += "; its output wasn't saved: \(error)"
      }
      // The run view reads a red row's evidence as text output, so only a row that isn't red
      // lists the bundle and report files beside its output.
      if result != .red {
        var written = junit.map(JUnitReportFiles.files(at:)) ?? []
        if case .tests(let tests) = bundle, let resultBundle {
          written.append(resultBundle)
          // A report copies this small summary, never the bundle.
          if let summary = QAReport.testSummary(ofBundle: resultBundle),
            (try? QAFiles.write(tests, to: URL(filePath: summary))) != nil
          {
            written.append(summary)
          }
        }
        let prefix = qaDirectory.path + "/"
        evidence += written.filter { $0.hasPrefix(prefix) }.map {
          "\(QAReport.directory)/\($0.dropFirst(prefix.count))"
        }
      }
      return QACheckOutcome(
        result: result, message: message, exitStatus: exitStatus,
        milliseconds: Self.milliseconds(output.elapsed), evidence: evidence)
    }

    /// The check timeout, cut to the time left before the box's deadline.
    private func timeout() -> Duration {
      guard let deadline = dependencies.deadline,
        case .run(let left) = deadline.admit(
          layer: .acceptance, expectedMilliseconds: nil, now: dependencies.now())
      else { return dependencies.timeout }
      return min(dependencies.timeout, left)
    }

    /// `<NN>-<requirement>.<layer>.txt`, with any character a file name shouldn't hold as `-`.
    static func evidenceName(_ entry: QARunPlan.Entry) -> String {
      let number = entry.row < 10 ? "0\(entry.row)" : "\(entry.row)"
      let requirement = String(
        entry.validation.requirement.map { character in
          character.isASCII
            && (character.isLetter || character.isNumber || "-_".contains(character))
            ? character : "-"
        })
      return "\(number)-\(requirement).\(entry.validation.layer.rawValue).txt"
    }

    static func milliseconds(_ duration: Duration) -> Int {
      let parts = duration.components
      return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
  }

  /// The deadline of the `swiftgate run` whose box is running in `root`'s clone, its cutoff
  /// moved to leave the clone's measured `final` its time; `nil` outside a box.
  static func deadline(root: URL, runner: any ProcessRunner, final: Bool) async -> QARunDeadline? {
    guard let layout = try? await GitTrackedTree(runner: runner, directory: root).stateLayout(),
      let box = ActiveRunTimeBox.find(
        layout: layout, now: Date(), finalSeconds: MeasuredFinalGateReader.seconds(worktree: root))
    else { return nil }
    return QARunDeadline.of(box, final: final)
  }

  /// The line a run prints once its run directory exists, naming where its report is written
  /// and, when that is a worktree's own state, where the clone keeps it once the checkout is
  /// removed.
  static func startedLine(runID: String, reportFile: String, keptReportFile: String?) -> String {
    "\(command): run \(runID) started; its report will be written to \(reportFile)"
      + kept(keptReportFile) + "\n"
  }

  /// Where the clone keeps run `runID`'s `qa/report.json` once the checkout at `root` is
  /// removed; `nil` when that is where the run writes it.
  static func keptReportFile(runID: String, root: URL) -> String? {
    guard case .gitDir(let gitDir) = StateRootResolver.resolve(worktree: root),
      case .gitDir(let common) = StateRootResolver.eventStore(worktree: root),
      let kept = StateRootResolver.keptRuns(commonDir: common),
      kept != .gitDir(gitDir.standardizedFileURL)
    else { return nil }
    return kept.url(RunLayout.runDirectory(for: runID), directoryHint: .isDirectory)
      .appending(path: "\(QAReport.directory)/\(QAReport.fileName)", directoryHint: .notDirectory)
      .path(percentEncoded: false)
  }

  private static func kept(_ file: String?) -> String {
    file.map { ", and kept at \($0) once the checkout is removed" } ?? ""
  }

  /// 1 line naming the verdict, the run and the report file, printed last so a cut output keeps
  /// it; empty when `reportFile` is `nil`.
  static func summary(_ report: QAReport, reportFile: String?, keptReportFile: String? = nil)
    -> String
  {
    guard let reportFile else { return "" }
    return
      "\(command): \(report.verdict.rawValue) \(report.message); run \(report.runID ?? "none"), "
      + "report \(reportFile)"
      + (keptReportFile.map { ", kept at \($0) once the checkout is removed" } ?? "")
  }

  /// `path` relative to `root` unless absolute.
  private static func outputFile(_ path: String, root: URL) -> URL {
    path.hasPrefix("/")
      ? URL(filePath: path, directoryHint: .notDirectory)
      : root.appending(path: path, directoryHint: .notDirectory)
  }

  /// Makes `path` a new empty file as the run starts, so `build gate-wait --qa` dates the run by
  /// its creation and never reads an earlier run's report left there.
  static func startOutput(at path: String, root: URL) throws(QAFilesError) {
    let file = outputFile(path, root: root)
    try? FileManager.default.removeItem(at: file)
    try QAFiles.write(Data(), to: file)
  }

  /// Writes `report`'s JSON, as `--json` prints it, to `path` alone, relative to `root` unless
  /// absolute, keeping the creation time ``startOutput(at:root:)`` gave it.
  static func writeOutput(
    _ report: QAReport, reportFile: String?, keptReportFile: String? = nil, to path: String,
    root: URL
  ) throws(QAFilesError) {
    let file = outputFile(path, root: root)
    let created = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.creationDate]
    try QAFiles.write(
      Data(
        render(report, json: true, reportFile: reportFile, keptReportFile: keptReportFile).utf8),
      to: file)
    if let created {
      try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: file.path)
    }
  }

  /// - Parameter reportFile: where the run wrote `report.json`, named in the last line.
  /// - Parameter keptReportFile: where the clone keeps that report once the checkout is removed.
  static func render(
    _ report: QAReport, json: Bool, reportFile: String? = nil, keptReportFile: String? = nil
  ) -> String {
    let summary = summary(report, reportFile: reportFile, keptReportFile: keptReportFile)
    guard !json else {
      let encoded = String(decoding: (try? QAReportJSON.encode(report)) ?? Data(), as: UTF8.self)
      // The summary goes in as the object's last member, so the JSON still reads.
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.withoutEscapingSlashes]
      guard !summary.isEmpty, encoded.hasSuffix("\n}\n"),
        let quoted = try? encoder.encode(summary)
      else { return encoded }
      return encoded.dropLast("\n}\n".count) + ",\n  \"summary\" : "
        + String(decoding: quoted, as: UTF8.self) + "\n}\n"
    }
    var lines = ["\(command): \(report.verdict.rawValue) \(report.message)"]
    for row in report.rows {
      lines.append(
        "  row \(row.row) \(row.requirement) \(row.layer.rawValue): \(row.result.rawValue), "
          + row.message)
    }
    if let runID = report.runID { lines.append("  run: \(runID)") }
    if let record = report.atBaseRecord { lines.append("  at-base record: \(record)") }
    lines += report.notes.map { "  note: \($0)" }
    if !summary.isEmpty { lines.append(summary) }
    return lines.joined(separator: "\n")
  }
}

/// `swiftgate qa run [--plan <slug>] [--after <task>[,<task>...] [--before-merge [--fix]]]
/// [--at-base [--prepared-by <task> [--requirement <id>]]] [--final] [--json]`.
struct QARunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Run the validation rows whose tasks have merged: acceptance, then flow, then state.")

  @Option(help: "The plan's slug; defaults to the 1 plan holding a validation.json.")
  var plan: String?

  @Option(
    help: ArgumentHelp(
      "Run only the rows that name this task in Runs after, taking it as merged, recording each "
        + "flow when the recorder is free. With --before-merge, a comma-separated list merges "
        + "every task's branch, in order, and runs the rows that name any of them."))
  var after: String?

  @Flag(help: "Run every row at the merge base in a scratch worktree and record why each fails.")
  var atBase = false

  @Flag(help: "Run every ready row, recording each flow and saving its logs: the final pass.")
  var final = false

  @Option(
    help:
      "With --at-base, run only the rows this task writes, from this checkout's .harness/qa/<plan>/."
  )
  var preparedBy: String?

  @Option(
    help:
      "With --prepared-by, run only this requirement's rows: a repaired flow's red run at the base."
  )
  var requirement: String?

  @Flag(
    help: ArgumentHelp(
      "With --after, run its rows where the task's branch is merged into main's tip in a scratch "
        + "worktree, before build merge lands it."))
  var beforeMerge = false

  @Flag(help: "With --before-merge, merge the task's fixer's branch in place of the task's.")
  var fix = false

  @Flag(help: "Print JSON.")
  var json = false

  @Option(
    help: ArgumentHelp(
      "Write the JSON report to this file, alone: the start line and every other output stay "
        + "on the terminal. The file is made new and empty as the run starts and holds the "
        + "whole report once it ends, which `build gate-wait --qa` watches."))
  var output: String?

  @Option(
    help: ArgumentHelp(
      "Stop by this time, an ISO 8601 time or whole seconds from now: the wait for the device "
        + "and every row end by then, and a row that can't is unverified naming why. Use it "
        + "in place of wrapping the run in `timeout`, which kills it with no report."))
  var deadline: String?

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    if let output {
      do throws(QAFilesError) {
        try QARunRun.startOutput(at: output, root: root)
      } catch {
        FileHandle.standardError.write(Data("\(QARunRun.command): --output: \(error)\n".utf8))
        throw ExitCode(Verdict.blocked.exitCode)
      }
    }
    let runner = LiveProcessRunner()
    let agentDevice = LiveAgentDevice(runner: runner)
    var bound: QARunDeadline?
    if let deadline {
      let now = Date()  // swiftgate:allow det.date-init — a --deadline counts from now
      guard let parsed = QARunDeadline.parse(deadline, now: now) else {
        throw ValidationError(
          "--deadline `\(deadline)` is neither a time after now in ISO 8601 nor whole seconds "
            + "from now")
      }
      bound = parsed
    }
    let tasks =
      after.map { list in
        list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
      } ?? []
    let report = await QARunRun.run(
      root: root,
      options: QARunRun.Options(
        plan: plan, after: tasks.first, atBase: atBase, final: final, preparedBy: preparedBy,
        requirement: requirement, beforeMerge: beforeMerge, fix: fix,
        alongside: Array(tasks.dropFirst())),
      git: LiveGit(runner: runner, repositoryRoot: root.path),
      dependencies: QARunRun.Dependencies(
        checks: QACommandRunner(runner: runner), ports: LiveQAPorts(), scratch: nil, events: nil,
        now: { Date() },  // swiftgate:allow det.date-init — the CLI edge stamps when the run ran
        runIDSuffix: {
          UInt32.random(in: .min ... .max)  // swiftgate:allow det.random — a unique run id
        },
        newEventID: {
          UUID().uuidString  // swiftgate:allow det.uuid-init — an event id need only be unique
        }, flows: LiveQAFlowSimulator(runner: runner, agentDevice: agentDevice),
        pluginRoot: ProcessInfo.processInfo.environment[QALintRun.harnessRootVariable].map {
          URL(filePath: $0, directoryHint: .isDirectory)
        },
        finalPass: QAFinalPass(
          recorder: FinalPassRecorder(
            dependencies: FinalPassRecorder.Dependencies(
              agentDevice: agentDevice,
              lock: FileCountingLock(name: FinalPassRecorder.lockName, capacity: 1),
              clock: .continuous())),
          evidence: EvidenceCollector(agentDevice: agentDevice, runner: runner)),
        testDevices: LiveTestDeviceLeases(runner: runner),
        deadline: QARunDeadline.earlier(
          await QARunRun.deadline(root: root, runner: runner, final: final), bound),
        started: { runID, report in
          // Before any row runs, so a caller that backgrounds the run waits on this file.
          let line = QARunRun.startedLine(
            runID: runID, reportFile: report.path,
            keptReportFile: QARunRun.keptReportFile(runID: runID, root: root))
          FileHandle.standardError.write(Data(line.utf8))
        },
        devices: LiveQADeviceLender(
          root: root, git: LiveGit(runner: runner, repositoryRoot: root.path)),
        running: await (try? GitTrackedTree(runner: runner, directory: root).stateLayout())
          .map { RunningGateRegistry(layout: $0) }))
    let reportFile = report.runID.flatMap { runID in
      (try? RunStore(worktreeRoot: root).runDirectory(for: runID))?
        .appending(path: "\(QAReport.directory)/\(QAReport.fileName)").path
    }.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    let keptReportFile = report.runID.flatMap { QARunRun.keptReportFile(runID: $0, root: root) }
    if let output {
      do throws(QAFilesError) {
        try QARunRun.writeOutput(
          report, reportFile: reportFile, keptReportFile: keptReportFile, to: output, root: root)
      } catch {
        FileHandle.standardError.write(Data("\(QARunRun.command): --output: \(error)\n".utf8))
        throw ExitCode(Verdict.blocked.exitCode)
      }
      Console.write(
        QARunRun.summary(report, reportFile: reportFile, keptReportFile: keptReportFile))
    } else {
      Console.write(
        QARunRun.render(
          report, json: json, reportFile: reportFile, keptReportFile: keptReportFile))
    }
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

/// Lends a brownfield `qa run` the device of the time-boxed build run going on for its plan. Its
/// holder lasts to the box's end, at least the default session timeout, unless `build finish` or
/// `run checkout remove` releases it first.
struct LiveQADeviceLender: QADeviceLending {
  let root: URL
  let git: any Git

  func borrow(
    plan: String, until deadline: QARunDeadline?, waiting: @escaping @Sendable () -> Void
  ) async -> QADeviceLoan {
    guard BuildPresetCatalog.profile(root: root) == .brownfield,
      let store = try? await BuildRunStore.latest(plan: plan, git: git),
      let box = try? store.record().timeBox,
      let common = try? await git.commonDirectory()
    else { return .own }
    let now = Date()  // swiftgate:allow det.date-init — the CLI edge reads the clock
    let left = box.deadlines.endsAt.timeIntervalSince(now) / 60
    let minutes = min(
      QAConfig.sessionTimeoutMinutesRange.upperBound,
      max(QAConfig.defaultSessionTimeoutMinutes, Int(left.rounded(.up)) + 5))
    // Queued rather than given up on: a gate's test step borrows it for about 30 s, and a run
    // that fell back to a device of its own would wait for a `sim` slot instead.
    let queue = BuildRunDeviceQueue.live(
      buildRunID: store.runID, lockDirectory: FileCountingLock.defaultDirectory())
    switch await queue.take(until: deadline, waiting: waiting) {
    case .taken(let lease, let waited):
      return .borrowed(
        BorrowedDevice(
          hold: QAFlowDeviceHold(
            runID: BuildRunDevice.holdRunID(buildRunID: store.runID),
            directory: BuildRunDevice.logDirectory(
              commonDirectory: common, buildRunID: store.runID),
            keptAfterRun: true, timeoutMinutes: minutes, slotDeadline: deadline),
          lease: lease), waitedMilliseconds: waited)
    case .timedOut(let message, let waited):
      return .refused(message, waitedMilliseconds: waited)
    }
  }
}

/// `sim up`, `sim verify` and `sim down` as their commands run them, for the tree a flow row runs
/// in: the checkout, or a scratch tree at the merge base.
struct LiveQAFlowSimulator: QAFlowSimulating {
  let runner: any ProcessRunner
  let agentDevice: any AgentDevice

  init(runner: any ProcessRunner, agentDevice: (any AgentDevice)? = nil) {
    self.runner = runner
    self.agentDevice = agentDevice ?? LiveAgentDevice(runner: runner)
  }

  /// `qa run` starts each holder itself and outlives it, so a holder that exited stays a zombie
  /// child, which `kill(pid, 0)` still finds, until it is reaped here.
  @Sendable static func isAlive(_ pid: Int32) -> Bool {
    var status: Int32 = 0
    if waitpid(pid, &status, WNOHANG) == pid { return false }
    return SimulatorClones.processIsAlive(pid)
  }

  func up(_ request: QAFlowSimulatorRequest) async -> Result<SimUpStarted, SimUpFailure> {
    let root = request.worktree
    let target: SimTarget
    switch SimTargetLoader.load(worktree: root) {
    case .success(let loaded): target = loaded
    case .failure(let failure): return .failure(failure)
    }
    let maxConcurrent = target.maxConcurrent
    let device: SimUpDevice =
      request.hold.map { hold in
        .shared(
          SimSharedHold(
            runID: hold.runID, ownerPID: hold.keptAfterRun ? nil : getpid(),
            logFile: hold.directory.appending(path: SimSession.logFileName),
            timeoutMinutes: hold.timeoutMinutes))
      } ?? .own
    let dependencies = SimUp.Dependencies(
      agentDevice: agentDevice,
      leases: SimLeaseStore(directory: SimLeaseStore.defaultDirectory()),
      launcher: DetachedLauncher(), xcodebuild: LiveXcodebuild(runner: runner),
      simctl: LiveSimctl(
        runner: runner,
        timeouts: LiveSimctl.Timeouts(quick: .seconds(target.simctlTimeoutSeconds))),
      bundles: AppBundleReader(), git: LiveGit(runner: runner, repositoryRoot: root.path),
      isAlive: Self.isAlive, terminate: { _ = kill($0, SIGTERM) },
      slotHolders: {
        SimUp.liveSlotHolders(
          lockDirectory: FileCountingLock.defaultDirectory(), capacity: maxConcurrent)
      }, clock: .continuous(),
      now: { Date() })  // swiftgate:allow det.date-init — the CLI edge stamps when the run started
    return await SimUp(dependencies: dependencies).run(
      SimUp.Request(
        worktree: root, target: target, scenario: request.scenario, runID: request.runID,
        simDirectory: request.simDirectory,
        derivedDataPath: SimUpCommand.derivedDataDirectory(root: root).path,
        swiftgateExecutable: Bundle.main.executablePath ?? CommandLine.arguments[0],
        device: device, slotDeadline: request.hold?.slotDeadline,
        launchArguments: request.launchArguments))
  }

  func verify(_ request: QAFlowSimulatorRequest) async -> Result<SimVerified, SimVerifyFailure> {
    let root = request.worktree
    let checkoutHead: SimCheckoutHead
    do {
      let sha = try await LiveGit(runner: runner, repositoryRoot: root.path).revision("HEAD")
      checkoutHead = sha.map { .commit($0) } ?? .unreadable("HEAD names no commit yet")
    } catch {
      checkoutHead = .unreadable(String(describing: error))
    }
    let simDirectory = request.simDirectory
    return SimVerify(
      dependencies: SimVerify.Dependencies(
        leases: SimLeaseStore(directory: SimLeaseStore.defaultDirectory()),
        isAlive: Self.isAlive, clock: .continuous(),
        now: { Date() })  // swiftgate:allow det.date-init — the history line's finish time
    ).run(
      SimVerify.Request(
        worktree: CanonicalPath.of(root), runID: request.runID, checkoutHead: checkoutHead,
        simDirectory: { _ in simDirectory },
        historyFile: StateRootResolver.resolve(worktree: root)
          .url(RunLayout.historyFile, directoryHint: .notDirectory), audit: request.audit))
  }

  func down(_ request: QAFlowSimulatorRequest) async -> Result<SimDowned, SimDownFailure> {
    let simDirectory = request.simDirectory
    return await SimDown(
      dependencies: SimDown.Dependencies(
        agentDevice: agentDevice,
        leases: SimLeaseStore(directory: SimLeaseStore.defaultDirectory()),
        simctl: LiveSimctl(runner: runner),
        crashReports: CrashReportReader(directory: CrashReportReader.defaultDirectory()),
        isAlive: Self.isAlive, clock: .continuous())
    ).run(
      SimDown.Request(
        worktree: CanonicalPath.of(request.worktree), runID: request.runID,
        simDirectory: { _ in simDirectory }))
  }
}
