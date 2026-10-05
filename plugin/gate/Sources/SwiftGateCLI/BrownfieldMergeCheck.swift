import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// The `merge` tier after each merge, and `final`, which is `merge` for every area plus each
/// area's `e2e`.
enum BrownfieldMergeCheck {
  struct Dependencies: Sendable {
    let config: BrownfieldConfig
    let layout: BrownfieldStateLayout
    let git: any Git
    let runner: any AreaCommandRunning
    let baseline: BaselineStore
    let prove: BrownfieldProve.Dependencies
    /// The tracked files, for each area's shared cache variables.
    let trackedTree: TrackedTreeSnapshot
    /// `git rev-parse <commit>^{tree}`: the baseline file's name.
    let tree: @Sendable (_ commit: String) async throws -> String
    /// Whether `slice` only builds the area, so its changed tests and their prove run here.
    let sliceBuildsOnly: @Sendable (BrownfieldArea) -> Bool
    /// Per command run.
    let deadline: Duration
    /// Reads each test step's totals for the run's `report.json`.
    var testCounts = AreaTestCountReader()

    /// An area command may run as long as the area's own tests take.
    static let liveDeadline: Duration = .seconds(3600)

    /// The clone's config and state, live git, scratch trees under the worktree's git dir and
    /// `/bin/sh` commands. `slice` builds only the areas whose warm test time, as the warm-up
    /// measured it at the merge base with `base`, doesn't fit the slice budget; with no `base`,
    /// every area.
    static func live(root: URL, base: String? = nil) async throws(BrownfieldCheckSetupError)
      -> Dependencies
    {
      let process = LiveProcessRunner()
      let tracked = GitTrackedTree(runner: process, directory: root)
      let layout: BrownfieldStateLayout
      let snapshot: TrackedTreeSnapshot
      do {
        layout = try await tracked.stateLayout()
        snapshot = try await tracked.snapshot()
      } catch {
        throw BrownfieldCheckSetupError(reason: error.message)
      }
      let config: BrownfieldConfig
      do {
        guard
          case .brownfield(let loaded)? = try ConfigLoader().loadProfile(
            repositoryRoot: root, commonDir: layout.commonDir)
        else {
          throw BrownfieldCheckSetupError(
            reason:
              "\(layout.config.path) holds no brownfield config; run swiftgate discover --apply")
        }
        config = loaded
      } catch let error as BrownfieldCheckSetupError {
        throw error
      } catch {
        throw BrownfieldCheckSetupError(reason: "\(error)")
      }
      let runner = LeasedDeviceAreaRunner(
        base: LiveAreaCommandRunner(processRunner: process),
        leases: LiveTestDeviceLeases(runner: process))
      let prove = BrownfieldProve.Dependencies.live(
        root: root, layout: layout, runner: runner, deadline: liveDeadline)
      let tree: @Sendable (String) async throws -> String = { commit in
        let output = try await process.run(
          ProcessInvocation(
            executable: "git", arguments: ["rev-parse", "--verify", "\(commit)^{tree}"],
            workingDirectory: root.path, timeout: .seconds(60)))
        let tree = output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status.isSuccess, !tree.isEmpty else {
          throw BrownfieldCheckSetupError(
            reason: "git rev-parse \(commit)^{tree}: \(output.stderr.text)")
        }
        return tree
      }
      // With no merge base or no warm-up there, no area is known to have run its changed tests
      // at `slice`, so every touched area proves again here.
      var times = WarmupTimesFile(tree: "")
      if let base, let mergeBase = try? await prove.git.mergeBase("HEAD", base),
        let baseTree = try? await tree(mergeBase)
      {
        times = WarmupTimesStore(layout: layout).load(tree: baseTree).file
      }
      let budget = config.brownfield.sliceBudgetSeconds
      return Dependencies(
        config: config, layout: layout, git: prove.git, runner: runner,
        baseline: BaselineStore(layout: layout, runner: runner, scratch: prove.scratch),
        prove: prove, trackedTree: snapshot, tree: tree,
        sliceBuildsOnly: { [times] area in times.buildsOnly(area.name, budgetSeconds: budget) },
        deadline: liveDeadline)
    }
  }

  static func run(root: URL, tier: CheckTier, base: String, context: GateRun.Context)
    async throws -> GateRunParts
  {
    let dependencies: Dependencies
    do {
      dependencies = try await .live(root: root, base: base)
    } catch {
      return try BrownfieldCheck.notRun(tier, because: error.reason)
    }
    return try await run(
      root: root, tier: tier, base: base, context: context, dependencies: dependencies)
  }

  static func run(
    root: URL, tier: CheckTier, base: String, context: GateRun.Context,
    dependencies: Dependencies
  ) async throws -> GateRunParts {
    let (parts, milliseconds) = try await GateRun.timed {
      try await steps(
        root: root, tier: tier, base: base, context: context, dependencies: dependencies)
    }
    let gating = parts.findings.contains { $0.severity.failsGate }
    let verdict: Verdict = gating ? .red : parts.blocked ? .blocked : .green
    return GateRunParts(
      tiers: [
        try TierResult(
          tier: .t1, verdict: verdict, durationMilliseconds: milliseconds, testCounts: nil)
      ],
      findings: parts.findings, baselineCount: parts.baselineCount)
  }

  /// What the steps found, and whether one couldn't answer.
  private struct Outcome {
    var findings: [Finding] = []
    var blocked = false
    /// The failures the baseline absorbed; `nil` when the steps stopped before any ran.
    var baselineCount: Int?
  }

  /// 1 command an area ran at the head.
  private struct StepRun: Sendable {
    let area: BrownfieldArea
    let step: AreaStep
    let template: String
    let selection: [String]
    let request: AreaCommandRequest
    let outcome: AreaCommandOutcome
    /// Lint output whose failure the parser could place on no line: it goes to the baseline
    /// like a test failure, as `area.lint-failed`.
    let lintFindings: [Finding]
    let lintUnread: Bool
  }

  private static func steps(
    root: URL, tier: CheckTier, base: String, context: GateRun.Context,
    dependencies: Dependencies
  ) async throws -> Outcome {
    let git = dependencies.git
    let mergeBase: String
    let changed: [String]
    let added: [AddedLines]
    do throws(GitError) {
      guard let found = try await git.mergeBase("HEAD", base) else {
        return blocked("HEAD and \(base) share no history, so there is no baseline to compare")
      }
      mergeBase = found
      changed = try await git.changedFiles(since: mergeBase)
      added = try await git.addedLines(since: mergeBase)
    } catch {
      return blocked("git: \(error)")
    }
    let areas = dependencies.config.areas
    let touched = AreaGating.touched(by: changed, in: areas)
    let gated = tier == .final ? areas : touched

    var outcome = Outcome(baselineCount: 0)
    let runs = await withTaskGroup(of: (findings: [Finding], runs: [StepRun]).self) { group in
      for area in gated {
        let files = added.map(\.path).filter { owner(of: $0, in: areas)?.name == area.name }
        group.addTask {
          await run(
            area, tier: tier, files: files, added: added, root: root, context: context,
            dependencies: dependencies)
        }
      }
      var all: [(findings: [Finding], runs: [StepRun])] = []
      for await result in group { all.append(result) }
      return all.sorted { ($0.runs.first?.area.name ?? "") < ($1.runs.first?.area.name ?? "") }
    }
    outcome.findings += runs.flatMap(\.findings)
    let stepRuns = runs.flatMap(\.runs)

    let failing = stepRuns.filter { run in
      switch run.outcome {
      case .passed: false
      default: run.step != .lint || run.lintUnread || run.outcome.toolNotInstalled
      }
    }
    if !failing.isEmpty {
      let tree: String
      do {
        tree = try await dependencies.tree(mergeBase)
      } catch {
        return blocked("can't read the tree of the merge base \(mergeBase): \(error)")
      }
      // The merge base's rerun of a step writes its reports where the head's run did.
      let evidence = context.directory.appending(path: "baseline-evidence")
      let queries = failing.map { run in
        let key = BaselineStepKey(
          area: run.area.name, step: run.step, command: run.template, selection: run.selection)
        let headEvidence = StepEvidence.keep(
          run.outcome, of: run.request, named: "\(run.area.name).\(run.step.rawValue)",
          in: evidence)
        return BaselineQuery(key: key, head: run.outcome, headEvidence: headEvidence) { scratch in
          // The failing step was prepared from this area, so preparing it again can't be `nil`.
          prepare(
            run.area, step: run.step, repositoryRoot: scratch.path(percentEncoded: false),
            files: run.selection, dependencies: dependencies)?.request
            ?? AreaCommandRequest(
              area: run.area.name, step: run.step, command: "false",
              workingDirectory: scratch.path(percentEncoded: false),
              deadline: dependencies.deadline, environment: [:], junitPath: nil)
        }
      }
      let (lookup, milliseconds) = await GateRun.timed {
        await dependencies.baseline.lookupOrRerun(
          queries, base: BaselineBase(commit: mergeBase, tree: tree),
          attributingTests: tier == .final)
      }
      let remaining = lookup.verdict.remaining
      outcome.baselineCount = lookup.verdict.baselineCount
      context.steps.record(
        .baseline, tier: nil, milliseconds: milliseconds,
        verdict: remaining.isEmpty && lookup.unattributed.isEmpty ? .green : .red)
      outcome.findings += lookup.notes + lookup.unattributed
      for failure in remaining {
        guard
          let run = failing.first(where: {
            $0.area.name == failure.key.area && $0.step == failure.key.step
          })
        else { continue }
        outcome.findings.append(try finding(failure, run: run))
      }
    }
    outcome.findings += stepRuns.flatMap(\.lintFindings)

    let proved = touched.filter(dependencies.sliceBuildsOnly)
    if !proved.isEmpty {
      let proofBase: String
      do throws(GitError) {
        proofBase = try await Self.proofBase(tier: tier, base: base, git: git)
      } catch {
        return blocked("git: \(error)")
      }
      let config = BrownfieldConfig(
        brownfield: dependencies.config.brownfield, areas: proved,
        allow: dependencies.config.allow, buildPresets: dependencies.config.buildPresets,
        judge: dependencies.config.judge)
      let (judgement, milliseconds) = await GateRun.timed {
        await BrownfieldProve.run(
          root: root, base: proofBase, config: config,
          junitDirectory: dependencies.layout.worktreeRoot.appending(
            path: "junit", directoryHint: .isDirectory),
          proofs: context.proofs, dependencies: dependencies.prove)
      }
      context.steps.record(
        .prove, tier: nil, milliseconds: milliseconds, verdict: judgement.verdict)
      outcome.findings += judgement.findings
      outcome.blocked = outcome.blocked || judgement.verdict == .blocked
    }
    return outcome
  }

  /// Where `tier`'s prove measures changed tests from and reverts the source to. At `merge` on a
  /// merge commit, that's its first parent, the plan branch's tip before this merge, so a test an
  /// earlier merge brought isn't counted again. `final`, a head that isn't a merge, or a first
  /// parent from before `base`'s fork point, keeps `base`.
  static func proofBase(tier: CheckTier, base: String, git: any Git) async throws(GitError)
    -> String
  {
    guard tier == .merge, try await git.revision("HEAD^2") != nil,
      let parent = try await git.revision("HEAD^1"),
      let fork = try await git.mergeBase("HEAD", base),
      try await git.isAncestor(fork, of: parent)
    else { return base }
    return parent
  }

  /// `area`'s `build`, `test` and `lint`, then `e2e` at `final`, 1 after another so they never
  /// share a build directory at once. The clone a test step runs on is leased as the area
  /// starts, so it boots while the build runs, and goes back once the area is done.
  private static func run(
    _ area: BrownfieldArea, tier: CheckTier, files: [String], added: [AddedLines], root: URL,
    context: GateRun.Context, dependencies: Dependencies
  ) async -> (findings: [Finding], runs: [StepRun]) {
    let steps: [AreaStep] = tier == .final ? [.build, .test, .lint, .e2e] : [.build, .test, .lint]
    guard let warming = dependencies.runner as? any TestDeviceWarming else {
      return await run(
        area, steps: steps, files: files, added: added, root: root, context: context,
        dependencies: dependencies, runner: dependencies.runner)
    }
    let tests = [AreaStep.test, .e2e].filter(steps.contains).compactMap { step in
      prepare(
        area, step: step, repositoryRoot: root.path(percentEncoded: false), files: [],
        dependencies: dependencies)?.request.command
    }
    let warmed = await warming.warmed(for: tests)
    let result = await run(
      area, steps: steps, files: files, added: added, root: root, context: context,
      dependencies: dependencies, runner: warmed)
    await warmed.release()
    return result
  }

  private static func run(
    _ area: BrownfieldArea, steps: [AreaStep], files: [String], added: [AddedLines], root: URL,
    context: GateRun.Context, dependencies: Dependencies, runner: any AreaCommandRunning
  ) async -> (findings: [Finding], runs: [StepRun]) {
    var findings: [Finding] = []
    var runs: [StepRun] = []
    for step in steps {
      guard let template = AreaCommandExpansion.template(for: step, in: area) else {
        // `e2e` is optional: discovery proposes it only where it found one.
        if step != .e2e, let dropped = dropped(area, step: step) { findings.append(dropped) }
        continue
      }
      let selection = step == .lint ? files : []
      if step == .lint, template.contains(AreaCommandExpansion.filesPlaceholder), files.isEmpty {
        continue
      }
      guard
        let prepared = prepare(
          area, step: step, repositoryRoot: root.path(percentEncoded: false), files: selection,
          dependencies: dependencies)
      else { continue }
      let (outcome, milliseconds) = await GateRun.timed {
        await runner.run(XcodeDerivedData.request(prepared.request, layout: dependencies.layout))
      }
      var lintFindings: [Finding] = []
      var lintUnread = false
      if step == .lint, case .failed(let exit, let tail, _) = outcome {
        let reading = LintOutputParser.read(
          LintRunOutput(
            area: area.name, areaRoot: area.root,
            repositoryRoot: root.path(percentEncoded: false), exitStatus: exit, streams: [tail]),
          added: added)
        lintFindings = reading.findings.compactMap { try? $0.finding(severity: .major) }
        lintUnread = reading.findings.isEmpty && !reading.notes.isEmpty
      }
      context.steps.record(
        gateStep(step), tier: nil, milliseconds: milliseconds,
        verdict: outcome == .passed ? .green : .red, area: area.name)
      runs.append(
        StepRun(
          area: area, step: step, template: template, selection: selection,
          request: prepared.request, outcome: outcome,
          lintFindings: lintFindings, lintUnread: lintUnread))
    }
    return (findings, runs)
  }

  private static func prepare(
    _ area: BrownfieldArea, step: AreaStep, repositoryRoot: String, files: [String],
    dependencies: Dependencies
  ) -> PreparedAreaCommand? {
    AreaCommandExpansion.prepare(
      area: area, step: step, repositoryRoot: repositoryRoot, files: files, tests: [],
      junitPath: AreaCommandExpansion.junitPath(
        layout: dependencies.layout, area: area.name, step: step),
      deadline: dependencies.deadline,
      environment: AreaCacheEnvironment.make(
        area: area, layout: dependencies.layout, tree: dependencies.trackedTree
      ).variables)
  }

  static func owner(of path: String, in areas: [BrownfieldArea]) -> BrownfieldArea? {
    AreaGating.owner(of: path, in: areas)
  }

  private static func gateStep(_ step: AreaStep) -> GateStep {
    switch step {
    case .build, .generate: .areaBuild
    case .lint: .areaLint
    case .test, .testFiles, .e2e: .areaTest
    }
  }

  private static func finding(_ failure: BaselineFailure, run: StepRun) throws -> Finding {
    let rule: BrownfieldRuleID =
      switch run.step {
      case .build, .generate: .buildFailed
      case .lint: .lintFailed
      case .test, .testFiles, .e2e: .testFailed
      }
    let what = failure.test.map { "\($0) fails" } ?? "\(run.step.rawValue) failed"
    let tail: String =
      switch run.outcome {
      case .passed: ""
      case .failed(let exit, let tail, _): "exit \(exit):\n\(tail)"
      case .crashed(let signal, let tail):
        "crashed\(signal.map { " with signal \($0)" } ?? ""):\n\(tail)"
      case .timedOut(let tail): "timed out:\n\(tail)"
      }
    return try Finding(
      ruleID: rule.rawValue, severity: .major, file: run.area.root, line: nil,
      message:
        "\(run.area.name) \(what) at the head and not at the merge base (`\(run.template)`), "
        + tail,
      failureScenario: nil)
  }

  private static func dropped(_ area: BrownfieldArea, step: AreaStep) -> Finding? {
    try? Finding(
      ruleID: BrownfieldRuleID.stepDropped.rawValue, severity: .nit, file: area.root, line: nil,
      message: "\(area.name) has no \(step.rawValue) command, so this tier doesn't run it",
      failureScenario: nil)
  }

  /// A BLOCKED outcome: the verdict says so even if the finding naming why can't be made.
  private static func blocked(_ reason: String) -> Outcome {
    let finding = try? Finding(
      ruleID: CheckRun.notRunRuleID, severity: .minor, file: ".", line: nil,
      message: "merge: \(reason)", failureScenario: nil)
    return Outcome(findings: finding.map { [$0] } ?? [], blocked: true)
  }
}

/// Why a brownfield tier couldn't start: no config, no git, no state paths.
struct BrownfieldCheckSetupError: Error, Sendable {
  let reason: String
}
