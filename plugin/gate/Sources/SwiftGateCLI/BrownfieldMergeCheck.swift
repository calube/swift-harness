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
    /// Whether `slice` may have left the area's changed tests unproved, so their prove runs here.
    let sliceBuildsOnly: @Sendable (BrownfieldArea) -> Bool
    /// Per command run, when ``bound`` is `nil`.
    let deadline: Duration
    /// Reads each test step's totals for the run's `report.json`.
    var testCounts = AreaTestCountReader()
    /// Each command's bound, from the area's warm-up times and the run's time box.
    var bound:
      (@Sendable (_ area: String, _ step: AreaStep, _ tree: AreaCommandTree) -> AreaCommandBound)? =
        nil
    /// Area commands that passed under the same inputs, which this tier takes without running;
    /// `nil` runs every command.
    var reuse: AreaStepReuse? = nil

    /// An area command may run as long as the area's own tests take.
    static let liveDeadline: Duration = .seconds(3600)

    /// `area`'s bound for `step` in `tree` now, or the flat ``deadline`` with no ``bound``.
    func bound(_ area: String, _ step: AreaStep, _ tree: AreaCommandTree) -> AreaCommandBound {
      bound?(area, step, tree)
        ?? AreaCommandBound(
          duration: deadline, reason: "the flat \(deadline.components.seconds) s")
    }

    /// The clone's config and state, live git, scratch trees under the worktree's git dir and
    /// `/bin/sh` commands. `slice` runs and proves the changed tests of every area whose
    /// `test_files` narrows a run to them, whatever its warm test time; any other area's it may
    /// leave to this tier, which proves them again. Each command's bound comes from the warm-up
    /// times at the merge base with `base` and the time box of the `swiftgate run` going on, read
    /// as `tier` runs; with no `base`, from the box alone.
    static func live(root: URL, base: String? = nil, tier: CheckTier = .merge)
      async throws(BrownfieldCheckSetupError) -> Dependencies
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
      let unbounded = BrownfieldProve.Dependencies.live(
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
      var times = WarmupTimesFile(tree: "")
      if let base, let mergeBase = try? await unbounded.git.mergeBase("HEAD", base),
        let baseTree = try? await tree(mergeBase)
      {
        times = WarmupTimesStore(layout: layout).load(tree: baseTree).file
      }
      let box = ActiveRunTimeBox.find(
        layout: layout, now: Date(), finalSeconds: MeasuredFinalGateReader.seconds(worktree: root))
      let bounds = AreaCommandBounds(times: times, box: box, tier: tier, fallback: liveDeadline)
      // Each bound is taken as its command starts, so the box's time left is current.
      let bound: @Sendable (String, AreaStep, AreaCommandTree) -> AreaCommandBound = {
        area, step, tree in
        bounds.bound(area: area, step: step, tree: tree, now: Date())
      }
      let prove = BrownfieldProve.Dependencies(
        git: unbounded.git, scratch: unbounded.scratch, runner: runner, deadline: liveDeadline,
        layout: layout,
        bound: { area, step in bound(area, step, .scratch) })
      return Dependencies(
        config: config, layout: layout, git: prove.git, runner: runner,
        baseline: BaselineStore(layout: layout, runner: runner, scratch: prove.scratch),
        prove: prove, trackedTree: snapshot, tree: tree,
        sliceBuildsOnly: { !$0.selectsChangedTests },
        deadline: liveDeadline, bound: bound)
    }
  }

  static func run(root: URL, tier: CheckTier, base: String, context: GateRun.Context)
    async throws -> GateRunParts
  {
    var dependencies: Dependencies
    do {
      dependencies = try await .live(root: root, base: base, tier: tier)
    } catch {
      return try BrownfieldCheck.notRun(tier, because: error.reason)
    }
    // Only a clean tree with every input known has a key; anything else runs every command.
    if let reader = await BrownfieldGateReuseReader.live(
      root: root, runner: LiveProcessRunner(), sourceHash: GateBinaryScope.current?.sourceHash),
      let inputs = await reader.inputs(tier: tier, base: base)
    {
      dependencies.reuse = AreaStepReuse(
        inputs: inputs, store: AreaStepResults(layout: dependencies.layout),
        runID: context.runID)
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
    /// What the command was given before the gate would kill it.
    let bound: AreaCommandBound
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
    let runs = await withTaskGroup(of: AreaSteps.self) { group in
      for area in gated {
        let files = added.map(\.path).filter { owner(of: $0, in: areas)?.name == area.name }
        group.addTask {
          await run(
            area, tier: tier, files: files, added: added, root: root, context: context,
            dependencies: dependencies)
        }
      }
      var all: [AreaSteps] = []
      for await result in group { all.append(result) }
      return all.sorted { $0.area < $1.area }
    }
    outcome.findings += runs.flatMap(\.findings)
    outcome.blocked = runs.contains(where: \.refused)
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
          let deadline = dependencies.bound(run.area.name, run.step, .scratch).duration
          return prepare(
            run.area, step: run.step, repositoryRoot: scratch.path(percentEncoded: false),
            files: run.selection, deadline: deadline, dependencies: dependencies
          ).map {
            ScratchTreeBuild.request($0.request, kind: run.area.kind, layout: dependencies.layout)
          }
            ?? AreaCommandRequest(
              area: run.area.name, step: run.step, command: "false",
              workingDirectory: scratch.path(percentEncoded: false),
              deadline: deadline, environment: [:], junitPath: nil)
        }
      }
      // Read before the reruns: whether their scratch-tree builds start warm.
      let derivedData = BrownfieldProve.derivedData(
        failing.map(\.area), layout: dependencies.layout)
      let (lookup, milliseconds) = await GateRun.timed {
        await dependencies.baseline.lookupOrRerun(
          queries, base: BaselineBase(commit: mergeBase, tree: tree),
          attributingTests: tier == .final)
      }
      let remaining = lookup.verdict.remaining
      outcome.baselineCount = lookup.verdict.baselineCount
      context.steps.record(
        .baseline, tier: nil, milliseconds: milliseconds,
        verdict: remaining.isEmpty && lookup.unattributed.isEmpty ? .green : .red,
        derivedData: derivedData)
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
    let provedAtSlice = touched.filter { area in
      !dependencies.sliceBuildsOnly(area)
        && changed.contains { ChangedTestIDs.isTestFile($0, of: area) }
    }
    if !provedAtSlice.isEmpty {
      let names = provedAtSlice.map(\.name).joined(separator: ", ")
      outcome.findings += summary(
        "prove: \(names)'s new or changed tests aren't proven again here: slice runs and proves "
          + "them in each task's own gate, and \(tier.rawValue) proves only the areas whose slice "
          + "builds without running them")
    }
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
      let (ran, milliseconds) = await GateRun.timed {
        await BrownfieldProve.prove(
          root: root, base: proofBase, config: config,
          junitDirectory: dependencies.layout.worktreeRoot.appending(
            path: "junit", directoryHint: .isDirectory),
          proofs: context.proofs, dependencies: dependencies.prove, layout: dependencies.layout)
      }
      let judgement = ran.judgement
      context.steps.record(
        .prove, tier: nil, milliseconds: milliseconds, verdict: judgement.verdict,
        derivedData: ran.derivedData)
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

  /// What 1 area's steps did.
  private struct AreaSteps: Sendable {
    let area: String
    var findings: [Finding] = []
    var runs: [StepRun] = []
    /// A step wasn't started: the box left it less than its measured time.
    var refused = false
  }

  /// `area`'s `build`, `test` and `lint`, then `e2e` at `final`, 1 after another so they never
  /// share a build directory at once. The clone a test step runs on is leased as the area
  /// starts, so it boots while the build runs, and goes back once the area is done. A step the
  /// box leaves too little time isn't started, and neither is any after it.
  private static func run(
    _ area: BrownfieldArea, tier: CheckTier, files: [String], added: [AddedLines], root: URL,
    context: GateRun.Context, dependencies: Dependencies
  ) async -> AreaSteps {
    let steps: [AreaStep] = tier == .final ? [.build, .test, .lint, .e2e] : [.build, .test, .lint]
    guard let warming = dependencies.runner as? any TestDeviceWarming else {
      return await run(
        area, tier: tier, steps: steps, files: files, added: added, root: root,
        context: context, dependencies: dependencies, runner: dependencies.runner)
    }
    let tests = [AreaStep.test, .e2e].filter(steps.contains).compactMap { step in
      prepare(
        area, step: step, repositoryRoot: root.path(percentEncoded: false), files: [],
        deadline: dependencies.deadline, dependencies: dependencies)?.request.command
    }
    let warmed = await warming.warmed(for: tests)
    let result = await run(
      area, tier: tier, steps: steps, files: files, added: added, root: root, context: context,
      dependencies: dependencies, runner: warmed)
    await warmed.release()
    return result
  }

  private static func run(
    _ area: BrownfieldArea, tier: CheckTier, steps: [AreaStep], files: [String],
    added: [AddedLines], root: URL, context: GateRun.Context, dependencies: Dependencies,
    runner: any AreaCommandRunning
  ) async -> AreaSteps {
    var result = AreaSteps(area: area.name)
    for step in steps {
      guard let template = AreaCommandExpansion.template(for: step, in: area) else {
        // `e2e` is optional: discovery proposes it only where it found one.
        if step != .e2e, let dropped = dropped(area, step: step) {
          result.findings.append(dropped)
        }
        continue
      }
      let selection = step == .lint ? files : []
      if step == .lint, template.contains(AreaCommandExpansion.filesPlaceholder), files.isEmpty {
        continue
      }
      let bound = dependencies.bound(area.name, step, .checkout)
      if bound.cannotFinish {
        result.refused = true
        if let refusal = notStarted(area, step: step, bound: bound) {
          result.findings.append(refusal)
        }
        break
      }
      guard
        let prepared = prepare(
          area, step: step, repositoryRoot: root.path(percentEncoded: false), files: selection,
          deadline: bound.duration, dependencies: dependencies)
      else { continue }
      let key = dependencies.reuse.map {
        GateReuse.areaStepKey(
          $0.inputs, area: area.name, step: step, command: prepared.request.command)
      }
      if let key, let pass = dependencies.reuse?.store.pass(key) {
        context.steps.record(
          gateStep(step), tier: nil, milliseconds: 0, verdict: .green, derivedData: .reused,
          area: area.name)
        if let tests = pass.tests { context.areaTests.record(tests.reused(from: pass.runID)) }
        if let note = reused(area, step: step, pass: pass) { result.findings.append(note) }
        continue
      }
      let request = XcodeDerivedData.request(prepared.request, layout: dependencies.layout)
      let derivedData = GateStepCollector.derivedData(
        buildDirectories: XcodeDerivedData.buildDirectories(
          request, kind: area.kind, layout: dependencies.layout
        ).map { URL(filePath: $0, directoryHint: .isDirectory) })
      let (outcome, milliseconds) = await GateRun.timed { await runner.run(request) }
      var tests: AreaTestCounts?
      if [.test, .testFiles, .e2e].contains(step),
        let counts = await dependencies.testCounts.counts(of: request)
      {
        let counted = AreaTestCounts(area: area.name, step: step, counts: counts)
        context.areaTests.record(counted)
        tests = counted
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
        verdict: outcome == .passed ? .green : .red,
        derivedData: step == .lint ? .none : derivedData, area: area.name)
      if outcome == .passed, let key, let reuse = dependencies.reuse {
        reuse.store.record(
          AreaStepPass(runID: reuse.runID, tier: tier.rawValue, tests: tests), key: key)
      }
      result.runs.append(
        StepRun(
          area: area, step: step, template: template, selection: selection,
          request: prepared.request, outcome: outcome, bound: bound,
          lintFindings: lintFindings, lintUnread: lintUnread))
    }
    return result
  }

  private static func prepare(
    _ area: BrownfieldArea, step: AreaStep, repositoryRoot: String, files: [String],
    deadline: Duration, dependencies: Dependencies
  ) -> PreparedAreaCommand? {
    AreaCommandExpansion.prepare(
      area: area, step: step, repositoryRoot: repositoryRoot, files: files, tests: [],
      junitPath: AreaCommandExpansion.junitPath(
        layout: dependencies.layout, area: area.name, step: step),
      deadline: deadline,
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
    let what: String
    if case .timedOut = run.outcome {
      what = "\(failure.test.map { "\($0) in " } ?? "")\(run.step.rawValue) hung"
    } else {
      what = failure.test.map { "\($0) fails" } ?? "\(run.step.rawValue) failed"
    }
    let tail: String =
      switch run.outcome {
      case .passed: ""
      case .failed(let exit, let tail, _): "exit \(exit):\n\(tail)"
      case .crashed(let signal, let tail):
        "crashed\(signal.map { " with signal \($0)" } ?? ""):\n\(tail)"
      case .timedOut(let tail):
        "hit its \(run.bound.seconds) s bound (\(run.bound.reason)), so the gate killed its "
          + "process tree:\n\(tail)"
      }
    return try Finding(
      ruleID: rule.rawValue, severity: .major, file: run.area.root, line: nil,
      message:
        "\(run.area.name) \(what) at the head and not at the merge base (`\(run.template)`), "
        + tail,
      failureScenario: nil)
  }

  /// A step taken from an earlier pass, named so the run says what it didn't run.
  private static func reused(_ area: BrownfieldArea, step: AreaStep, pass: AreaStepPass)
    -> Finding?
  {
    try? Finding(
      ruleID: GateReuse.ruleID, severity: .nit, file: area.root, line: nil,
      message:
        "\(area.name) \(step.rawValue) passed in \(pass.tier) gate run \(pass.runID) on the same "
        + "tree, merge base, binary and state, so it didn't run again",
      failureScenario: nil)
  }

  /// Why a step wasn't started: a BLOCKED tier, never a RED one, since nothing ran.
  private static func notStarted(_ area: BrownfieldArea, step: AreaStep, bound: AreaCommandBound)
    -> Finding?
  {
    let expected = bound.expected.map { " its measured \($0.components.seconds) s" } ?? ""
    return try? Finding(
      ruleID: CheckRun.notRunRuleID, severity: .minor, file: area.root, line: nil,
      message:
        "merge: \(area.name) \(step.rawValue) not started: \(bound.reason) can't hold"
        + "\(expected), so it would only be killed",
      failureScenario: nil)
  }

  private static func dropped(_ area: BrownfieldArea, step: AreaStep) -> Finding? {
    try? Finding(
      ruleID: BrownfieldRuleID.stepDropped.rawValue, severity: .nit, file: area.root, line: nil,
      message: "\(area.name) has no \(step.rawValue) command, so this tier doesn't run it",
      failureScenario: nil)
  }

  /// A BLOCKED outcome: the verdict says so even if the finding naming why can't be made.
  /// A `prove.summary` nit, which never gates.
  private static func summary(_ message: String) -> [Finding] {
    let finding = try? Finding(
      ruleID: ProofRules.summaryRuleID, severity: .nit, file: ".", line: nil, message: message,
      failureScenario: nil)
    return finding.map { [$0] } ?? []
  }

  private static func blocked(_ reason: String) -> Outcome {
    let finding = try? Finding(
      ruleID: CheckRun.notRunRuleID, severity: .minor, file: ".", line: nil,
      message: "merge: \(reason)", failureScenario: nil)
    return Outcome(findings: finding.map { [$0] } ?? [], blocked: true)
  }
}

/// What a merge or final tier needs to take an area command's earlier pass: the inputs every
/// key shares, the store, and the gate run recording new passes.
struct AreaStepReuse: Sendable {
  let inputs: GateReuse.Inputs
  let store: any AreaStepReusing
  let runID: String
}

/// Why a brownfield tier couldn't start: no config, no git, no state paths.
struct BrownfieldCheckSetupError: Error, Sendable {
  let reason: String
}
