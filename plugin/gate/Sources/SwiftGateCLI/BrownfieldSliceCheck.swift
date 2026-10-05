import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// The `slice` tier: each task's gate and the Stop hook.
enum BrownfieldSliceCheck {
  /// What the judge cascade made of a test the assertion table found nothing in.
  enum AssertionJudgement: Sendable, Equatable {
    /// A helper the test calls checks an outcome.
    case asserts
    case assertsNothing
    /// No judge answered, and why.
    case unanswered(String)
  }

  struct Dependencies: Sendable {
    let config: BrownfieldConfig
    let layout: BrownfieldStateLayout
    let git: any Git
    let runner: any AreaCommandRunning
    let baseline: BaselineStore
    /// Also reads the changed files the neutral rules and the Xcode check look at.
    var prove: BrownfieldProve.Dependencies
    /// The tracked files, for each area's shared cache variables.
    let trackedTree: TrackedTreeSnapshot
    /// `git rev-parse <commit>^{tree}`: the baseline and warm-up files' name.
    let tree: @Sendable (_ commit: String) async throws -> String
    /// What the warm-up at the base tree `tree` measured of the area; `nil` when none did.
    let warmup: @Sendable (_ area: BrownfieldArea, _ tree: String) async -> WarmupAreaRecord?
    /// `commit`'s first-parent history with each tree, `commit` first, at most
    /// ``WarmReuse/historyDepth`` entries.
    let history: @Sendable (_ commit: String) async throws -> [CommitTree]
    /// The paths that differ between 2 commits.
    let changedBetween: @Sendable (_ from: String, _ to: String) async throws -> [String]
    /// The judge cascade for 1 candidate, given its file's text.
    let judgeAssertion:
      @Sendable (_ candidate: AssertionCandidate, _ source: String) async -> AssertionJudgement
    /// Per command run.
    let deadline: Duration
    /// Reads each test step's totals for the run's `report.json`.
    var testCounts = AreaTestCountReader()
    /// The running `swiftgate run`'s box, which caps each command's bound; `nil` outside one.
    var box: RunTimeBox? = nil
    /// The clock each bound is taken on as its command starts.
    var now: @Sendable () -> Date = { Date() }
    /// Each command's bound, set from the warm-up times the run resolves; `nil` gives the flat
    /// ``deadline``.
    var bound:
      (@Sendable (_ area: String, _ step: AreaStep, _ tree: AreaCommandTree) -> AreaCommandBound)? =
        nil

    /// `area`'s bound for `step` in `tree` now.
    func bound(_ area: String, _ step: AreaStep, _ tree: AreaCommandTree) -> AreaCommandBound {
      bound?(area, step, tree)
        ?? AreaCommandBound(
          duration: deadline, reason: "the flat \(deadline.components.seconds) s")
    }

    /// A selected test run that fits the budget warm still gets room on a cold store.
    static let liveDeadline: Duration = .seconds(600)

    /// The clone's config and state, live git, scratch trees under the worktree's git dir,
    /// `/bin/sh` commands, and the box of the `swiftgate run` going on.
    static func live(root: URL) async throws(BrownfieldCheckSetupError) -> Dependencies {
      let merge = try await BrownfieldMergeCheck.Dependencies.live(root: root)
      var dependencies = Dependencies(
        config: merge.config, layout: merge.layout, git: merge.git, runner: merge.runner,
        baseline: merge.baseline,
        prove: BrownfieldProve.Dependencies.live(
          root: root, layout: merge.layout, runner: merge.runner, deadline: liveDeadline),
        trackedTree: merge.trackedTree, tree: merge.tree,
        warmup: { [layout = merge.layout] area, tree in
          WarmupTimesStore(layout: layout).load(tree: tree).file.areas[area.name]
        },
        history: { commit in try await firstParentHistory(of: commit, root: root) },
        changedBetween: { [git = merge.git] from, to in
          try await git.changedFiles(from: from, to: to)
        },
        judgeAssertion: BrownfieldJudge.assertionJudge(
          BrownfieldJudge.live(merge.config.judge, root: root)),
        deadline: liveDeadline)
      dependencies.box = ActiveRunTimeBox.find(
        layout: merge.layout, now: Date(),
        finalSeconds: MeasuredFinalGateReader.seconds(worktree: root))
      return dependencies
    }
  }

  /// `git log --first-parent` from `commit`, each line `<commit> <tree>`.
  static func firstParentHistory(of commit: String, root: URL) async throws
    -> [CommitTree]
  {
    let output = try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: "git",
        arguments: [
          "log", "--first-parent", "--format=%H %T", "-n", "\(WarmReuse.historyDepth)", commit,
        ],
        workingDirectory: root.path(percentEncoded: false), timeout: .seconds(60)))
    guard output.status.isSuccess else {
      throw BrownfieldCheckSetupError(
        reason: "git log --first-parent \(commit): \(output.stderr.text)")
    }
    return try output.stdout.text.split(separator: "\n").map { line in
      let fields = line.split(separator: " ")
      guard fields.count == 2 else {
        throw BrownfieldCheckSetupError(
          reason: "git log --first-parent \(commit) printed `\(line)`, not a commit and a tree")
      }
      return CommitTree(commit: String(fields[0]), tree: String(fields[1]))
    }
  }

  static func run(root: URL, base: String, context: GateRun.Context) async throws -> GateRunParts {
    let dependencies: Dependencies
    do {
      dependencies = try await .live(root: root)
    } catch {
      return try BrownfieldCheck.notRun(.slice, because: error.reason)
    }
    return try await run(root: root, base: base, context: context, dependencies: dependencies)
  }

  static func run(
    root: URL, base: String, context: GateRun.Context, dependencies: Dependencies
  ) async throws -> GateRunParts {
    let (outcome, milliseconds) = try await GateRun.timed {
      try await steps(root: root, base: base, context: context, dependencies: dependencies)
    }
    let gating = outcome.findings.contains { $0.severity.failsGate }
    let verdict: Verdict = gating ? .red : outcome.blocked ? .blocked : .green
    return GateRunParts(
      tiers: [
        try TierResult(
          tier: .t1, verdict: verdict, durationMilliseconds: milliseconds, testCounts: nil)
      ],
      findings: outcome.findings, baselineCount: outcome.baselineCount)
  }

  /// What the steps found, and whether one couldn't answer.
  private struct Outcome: Sendable {
    var findings: [Finding] = []
    var blocked = false
    var baselineCount = 0
  }

  /// 1 command an area ran at the head.
  private struct StepRun: Sendable {
    let area: BrownfieldArea
    let step: AreaStep
    let template: String
    let selection: [String]
    let outcome: AreaCommandOutcome
    /// What the command was given before the gate would kill it.
    let bound: AreaCommandBound
    /// The same command at the merge base, in the scratch tree at `scratch`; `nil` when the
    /// merge base can't answer for it, so its failure gates as it stands.
    let rerun: (@Sendable (_ scratch: URL) -> AreaCommandRequest)?
    /// Lint output the parser placed on no line: it goes to the baseline like a test failure.
    let lintUnread: Bool

    /// A lint whose tool isn't installed goes to the baseline too, which reports it.
    var failing: Bool {
      switch outcome {
      case .passed: false
      default: step != .lint || lintUnread || outcome.toolNotInstalled
      }
    }
  }

  /// What 1 area's steps found.
  private struct AreaResult: Sendable {
    var findings: [Finding] = []
    var runs: [StepRun] = []
    var blocked = false
    /// A changed test can only hang, so the area runs nothing more.
    var refused = false

    mutating func add(_ other: AreaResult) {
      findings += other.findings
      runs += other.runs
      blocked = blocked || other.blocked
      refused = refused || other.refused
    }
  }

  /// The change as the steps see it: what it touched since the merge base.
  private struct Change: Sendable {
    let mergeBase: String
    /// The merge base's tree: the baseline and warm-up files' name.
    let tree: String
    let added: [AddedLines]
    /// Changed paths the merge base doesn't hold.
    let new: Set<String>
  }

  private static func steps(
    root: URL, base: String, context: GateRun.Context, dependencies: Dependencies
  ) async throws -> Outcome {
    let git = dependencies.git
    let areas = dependencies.config.areas
    let mergeBase: String
    let changed: [String]
    let added: [AddedLines]
    do throws(GitError) {
      guard let found = try await git.mergeBase("HEAD", base) else {
        return blocked("HEAD and \(base) share no history, so there is no change to gate")
      }
      mergeBase = found
      changed = try await git.changedFiles(since: mergeBase)
      added = try await git.addedLines(since: mergeBase)
    } catch {
      return blocked("git: \(error)")
    }
    guard !changed.isEmpty else { return Outcome() }

    var outcome = Outcome()
    let unowned = added.filter { BrownfieldMergeCheck.owner(of: $0.path, in: areas) == nil }
    if !unowned.isEmpty {
      let (result, milliseconds) = await GateRun.timed {
        await neutral(unowned, globs: [], root: root, dependencies: dependencies)
      }
      context.steps.record(
        .neutral, tier: nil, milliseconds: milliseconds, verdict: verdict(of: result))
      outcome.findings += result.findings
      outcome.blocked = outcome.blocked || result.blocked
    }

    let touched = AreaGating.touched(by: changed, in: areas)
    guard !touched.isEmpty else { return outcome }
    let change: Change
    do {
      let atBase = try await git.contents(of: changed, at: mergeBase)
      change = Change(
        mergeBase: mergeBase, tree: try await dependencies.tree(mergeBase), added: added,
        new: Set(changed).subtracting(atBase.keys))
    } catch {
      return blocked("can't read the merge base \(mergeBase): \(error)")
    }

    let (warm, warmNotes) = await warmTimes(touched, change: change, dependencies: dependencies)
    outcome.findings += warmNotes
    let dependencies = await bounded(dependencies, warm: warm)
    let results = await withTaskGroup(of: AreaResult.self) { group in
      for area in touched {
        group.addTask {
          await run(
            area, warm: warm[area.name] ?? .unmeasured, change: change, root: root, base: base,
            context: context, dependencies: dependencies)
        }
      }
      var all: [AreaResult] = []
      for await result in group { all.append(result) }
      return all.sorted { ($0.runs.first?.area.name ?? "") < ($1.runs.first?.area.name ?? "") }
    }
    for result in results {
      outcome.findings += result.findings
      outcome.blocked = outcome.blocked || result.blocked
    }

    let failing = results.flatMap(\.runs).filter(\.failing)
    let layout = dependencies.layout
    let queries = failing.compactMap { run -> BaselineQuery? in
      guard let rerun = run.rerun else { return nil }
      return BaselineQuery(
        key: BaselineStepKey(
          area: run.area.name, step: run.step, command: run.template, selection: run.selection),
        head: run.outcome,
        request: { scratch in
          ScratchTreeBuild.request(rerun(scratch), kind: run.area.kind, layout: layout)
        })
    }
    // Read before the reruns: whether their scratch-tree builds start warm.
    let baselineDerivedData = BrownfieldProve.derivedData(
      failing.filter { $0.rerun != nil }.map(\.area), layout: layout)
    for run in failing where run.rerun == nil {
      outcome.findings.append(
        try finding(
          run, what: "\(run.step.rawValue) failed",
          because: "a changed test file is new, so the merge base can't hold the failure"))
    }
    if !queries.isEmpty {
      let (lookup, milliseconds) = await GateRun.timed {
        await dependencies.baseline.lookupOrRerun(
          queries, base: BaselineBase(commit: change.mergeBase, tree: change.tree))
      }
      let remaining = lookup.verdict.remaining
      context.steps.record(
        .baseline, tier: nil, milliseconds: milliseconds,
        verdict: remaining.isEmpty ? .green : .red, derivedData: baselineDerivedData)
      outcome.findings += lookup.notes
      outcome.baselineCount = lookup.verdict.baselineCount
      for failure in remaining {
        guard
          let run = failing.first(where: {
            $0.area.name == failure.key.area && $0.step == failure.key.step
          })
        else { continue }
        outcome.findings.append(
          try finding(
            run, what: failure.test.map { "\($0) fails" } ?? "\(run.step.rawValue) failed",
            because: "the merge base doesn't fail it"))
      }
    }
    return outcome
  }

  /// Each touched area's warm test time, from the nearest warm-up on the merge base's
  /// first-parent history: a task branched from a plan branch sits on its contract or a merge,
  /// which no warm-up measured.
  private static func warmTimes(
    _ touched: [BrownfieldArea], change: Change, dependencies: Dependencies
  ) async -> (times: [String: WarmTestTime], notes: [Finding]) {
    var notes: [Finding] = []
    let history: [CommitTree]
    do {
      history = try await dependencies.history(change.mergeBase)
    } catch {
      history = [CommitTree(commit: change.mergeBase, tree: change.tree)]
      notes += note(
        "can't read the first-parent history of \(change.mergeBase), so only a warm-up at its own "
          + "tree counts: \(error)")
    }
    let areas = dependencies.config.areas
    let resolution = await WarmReuse.resolve(
      touched, mergeBase: change.mergeBase, history: history,
      owner: { BrownfieldMergeCheck.owner(of: $0, in: areas)?.name },
      warmTest: { await dependencies.warmup($0, $1)?.warmTestMilliseconds },
      changed: dependencies.changedBetween)
    return (resolution.times, notes + resolution.notes.flatMap { note($0) })
  }

  /// `dependencies` with each command held to the bound the touched areas' warm-ups give, read on
  /// the dependencies' clock as the command starts, and prove's scratch-tree runs held to theirs.
  private static func bounded(_ dependencies: Dependencies, warm: [String: WarmTestTime]) async
    -> Dependencies
  {
    var records: [String: WarmupAreaRecord] = [:]
    for area in dependencies.config.areas {
      let at: CommitTree
      switch warm[area.name] {
      case .current(_, let found)?, .stale(_, let found, _)?: at = found
      case .unmeasured?, nil: continue
      }
      records[area.name] = await dependencies.warmup(area, at.tree)
    }
    let bounds = AreaCommandBounds(
      times: WarmupTimesFile(tree: "", areas: records), box: dependencies.box, tier: .slice,
      fallback: dependencies.deadline)
    let now = dependencies.now
    let areas = dependencies.config.areas
    let layout = dependencies.layout
    let bound: @Sendable (String, AreaStep, AreaCommandTree) -> AreaCommandBound = {
      area, step, tree in
      bounds.bound(
        area: area, step: step,
        tree: BrownfieldProve.pricedTree(tree, area: area, areas: areas, layout: layout),
        now: now())
    }
    var copy = dependencies
    copy.bound = bound
    copy.prove = dependencies.prove.bounded { area, step in bound(area, step, .scratch) }
    return copy
  }

  /// 1 touched area: the neutral rules, Xcode membership and lint on its changed files, then its
  /// changed tests and their prove when a warm test run fits the budget, else its build. An area
  /// changed since the warm-up that measured it builds first, so its tests never run on caches
  /// the warm-up left behind its code. An area whose `test_files` narrows a run to the changed
  /// tests runs and proves them whatever its whole suite takes: over the budget means not running
  /// the whole suite, never running no test. A change that selects no test builds instead, so its
  /// code still compiles.
  private static func run(
    _ area: BrownfieldArea, warm: WarmTestTime, change: Change, root: URL, base: String,
    context: GateRun.Context, dependencies: Dependencies
  ) async -> AreaResult {
    let areas = dependencies.config.areas
    let added = change.added.filter {
      BrownfieldMergeCheck.owner(of: $0.path, in: areas)?.name == area.name
    }
    var result = AreaResult()

    let (neutralResult, neutralMilliseconds) = await GateRun.timed {
      await neutral(added, globs: area.testGlobs, root: root, dependencies: dependencies)
    }
    context.steps.record(
      .neutral, tier: nil, milliseconds: neutralMilliseconds, verdict: verdict(of: neutralResult),
      area: area.name)
    result.findings += neutralResult.findings
    result.blocked = result.blocked || neutralResult.blocked

    if let xcode = area.xcode {
      let newSwift = added.map(\.path).filter { change.new.contains($0) && $0.hasSuffix(".swift") }
      if !newSwift.isEmpty {
        let (membership, milliseconds) = await GateRun.timed {
          membershipFindings(newSwift, xcode: xcode, area: area, root: root, dependencies)
        }
        context.steps.record(
          .xcodeMembership, tier: nil, milliseconds: milliseconds,
          verdict: membership.contains { $0.severity.failsGate } ? .red : .green, area: area.name)
        result.findings += membership
      }
    }

    if let lint = await lint(
      area, files: added.map(\.path), added: change.added, root: root, context: context,
      dependencies: dependencies)
    {
      result.findings += lint.findings
      result.runs += lint.runs
    }

    let budget = dependencies.config.brownfield.sliceBudgetSeconds * 1000
    // A step that ends build-only still compiles the area's tests where it can, so a test that
    // doesn't compile fails here rather than first at merge.
    let testable = XcodeBuildForTesting.area(area) ?? area
    let why: String
    switch warm {
    case .current(let milliseconds, _) where milliseconds <= budget:
      let tested = await tests(
        area, change: change, root: root, base: base, context: context,
        dependencies: dependencies)
      result.add(tested)
      guard tested.runs.isEmpty, !tested.refused else { return result }
      if let build = await build(area, root: root, context: context, dependencies: dependencies) {
        result.runs.append(build.run)
      } else {
        result.findings += stepDropped(area)
      }
      return result
    case .stale(let milliseconds, let at, _) where milliseconds <= budget:
      guard
        let build = await build(
          testable, root: root, context: context, dependencies: dependencies)
      else {
        result.findings += buildOnly(
          testable,
          because: "its files changed since the warm-up at \(at.commit) measured its tests, and it "
            + "has no build command to bring its build up to date")
        result.findings += stepDropped(area)
        return result
      }
      result.runs.append(build.run)
      if build.run.outcome != .passed {
        why =
          "its build failed, and its files changed since the warm-up at \(at.commit) measured its "
          + "tests, so no test runs on the stale build"
      } else if build.milliseconds + milliseconds > budget {
        if area.selectsChangedTests {
          result.add(
            await tests(
              area, change: change, root: root, base: base, context: context,
              dependencies: dependencies))
          return result
        }
        why =
          "its build took \(seconds(build.milliseconds)) s and its warm test run, measured at "
          + "\(at.commit) before its files changed, takes \(seconds(milliseconds)) s: together "
          + "over the \(budget / 1000) s slice budget"
      } else {
        result.add(
          await tests(
            area, change: change, root: root, base: base, context: context,
            dependencies: dependencies))
        return result
      }
      result.findings += buildOnly(testable, because: why)
      return result
    case .current(let milliseconds, let at), .stale(let milliseconds, let at, _):
      let measured = at.commit == change.mergeBase ? "" : ", measured at \(at.commit),"
      why =
        "its warm test run\(measured) takes \(seconds(milliseconds)) s, over the "
        + "\(budget / 1000) s slice budget"
    case .unmeasured:
      why =
        "no warm-up on the first-parent history of the merge base \(change.mergeBase) measured "
        + "its tests"
    }
    if area.selectsChangedTests {
      let tested = await tests(
        area, change: change, root: root, base: base, context: context,
        dependencies: dependencies)
      result.add(tested)
      guard tested.runs.isEmpty, !tested.refused else { return result }
      if let build = await build(area, root: root, context: context, dependencies: dependencies) {
        result.runs.append(build.run)
      } else {
        result.findings += stepDropped(area)
      }
      return result
    }
    result.findings += buildOnly(testable, because: why)
    if let build = await build(testable, root: root, context: context, dependencies: dependencies) {
      result.runs.append(build.run)
    } else {
      result.findings += stepDropped(area)
    }
    return result
  }

  private static func buildOnly(_ area: BrownfieldArea, because why: String) -> [Finding] {
    let compiles =
      area.build?.contains(XcodeBuildForTesting.action) == true
      ? "only builds it and compiles its tests (`\(XcodeBuildForTesting.action)`)"
      : "only builds it"
    return
      (try? Finding(
        ruleID: BrownfieldRuleID.buildOnly.rawValue, severity: .nit, file: area.root, line: nil,
        message:
          "\(area.name): \(why), so slice \(compiles); its changed tests and their prove run "
          + "at merge",
        failureScenario: nil)).map { [$0] } ?? []
  }

  private static func stepDropped(_ area: BrownfieldArea) -> [Finding] {
    (try? Finding(
      ruleID: BrownfieldRuleID.stepDropped.rawValue, severity: .nit, file: area.root, line: nil,
      message: "\(area.name) has no build command, so slice runs nothing for it",
      failureScenario: nil)).map { [$0] } ?? []
  }

  /// The neutral rules over `added`, with each judge candidate sent through the cascade.
  private static func neutral(
    _ added: [AddedLines], globs: [String], root: URL, dependencies: Dependencies
  ) async -> AreaResult {
    var result = AreaResult()
    for change in added {
      guard let language = NeutralRules.language(forPath: change.path) else { continue }
      guard let text = dependencies.prove.readFile(root.appending(path: change.path)) else {
        result.findings += note("can't read \(change.path), so the neutral rules skip it")
        result.blocked = true
        continue
      }
      let source = NeutralSource(
        path: change.path, language: language,
        isTest: NeutralRules.isTestPath(change.path, language: language, globs: globs),
        text: text)
      do throws(ReportContractViolation) {
        let checked = try NeutralRules.check(
          source, added: change, allow: dependencies.config.allow)
        result.findings += checked.findings
        for candidate in checked.judgeCandidates {
          switch await dependencies.judgeAssertion(candidate, text) {
          case .asserts: continue
          case .assertsNothing:
            result.findings.append(try NeutralRules.noAssertionFinding(for: candidate))
          case .unanswered(let why):
            result.findings.append(
              try Finding(
                ruleID: BrownfieldRuleID.noAssertion.rawValue, severity: .minor,
                file: candidate.path, line: candidate.line,
                message:
                  "test `\(candidate.testName)` holds no assertion the table knows, and no judge "
                  + "answered whether a helper it calls asserts (\(why)), so it doesn't gate",
                failureScenario: nil))
          }
        }
      } catch {
        result.findings += note("the neutral rules couldn't report on \(change.path): \(error)")
        result.blocked = true
      }
    }
    return result
  }

  /// `xcode.file-not-in-target` for the new Swift files, from the area's tracked project.
  private static func membershipFindings(
    _ newSwift: [String], xcode: XcodeAreaConfig, area: BrownfieldArea, root: URL,
    _ dependencies: Dependencies
  ) -> [Finding] {
    guard let project = xcode.project else {
      return note(
        "\(area.name) records no project, so slice can't check that its new Swift files join a "
          + "target", severity: .nit)
    }
    let pbxproj = project + "/project.pbxproj"
    let file = root.appending(path: pbxproj)
    guard let text = dependencies.prove.readFile(file) else {
      return note(
        "can't read \(pbxproj), so slice can't check that \(area.name)'s new Swift "
          + "files join a target", severity: .nit)
    }
    do {
      return try TargetMembership(project: try PBXProject(parsing: text), projectPath: project)
        .newFileFindings(newSwift, inclusion: xcode.inclusion)
    } catch {
      return note(
        "\(pbxproj) doesn't parse, so slice can't check that \(area.name)'s new "
          + "Swift files join a target: \(error)", severity: .nit)
    }
  }

  /// The area's `lint` on its changed files; `nil` when it has none or nothing to lint.
  private static func lint(
    _ area: BrownfieldArea, files: [String], added: [AddedLines], root: URL,
    context: GateRun.Context, dependencies: Dependencies
  ) async -> AreaResult? {
    guard let template = area.lint, !files.isEmpty,
      let prepared = prepare(
        area, step: .lint, repositoryRoot: root.path(percentEncoded: false), files: files,
        tree: .checkout, dependencies: dependencies)
    else { return nil }
    let (outcome, milliseconds) = await GateRun.timed {
      await dependencies.runner.run(atHead(prepared.request, kind: area.kind, dependencies))
    }
    var result = AreaResult()
    var unread = false
    if case .failed(let exit, let tail, _) = outcome {
      let reading = LintOutputParser.read(
        LintRunOutput(
          area: area.name, areaRoot: area.root,
          repositoryRoot: root.path(percentEncoded: false), exitStatus: exit, streams: [tail]),
        added: added)
      result.findings = reading.findings.compactMap { try? $0.finding(severity: .major) }
      unread = reading.findings.isEmpty && !reading.notes.isEmpty
    }
    context.steps.record(
      .areaLint, tier: nil, milliseconds: milliseconds,
      verdict: outcome == .passed ? .green : .red, area: area.name)
    result.runs = [
      StepRun(
        area: area, step: .lint, template: template, selection: files, outcome: outcome,
        bound: dependencies.bound(area.name, .lint, .checkout),
        rerun: { scratch in
          rerunRequest(
            area, step: .lint, scratch: scratch, files: files, dependencies: dependencies)
        }, lintUnread: unread)
    ]
    return result
  }

  /// The area's `build` and how long it took; `nil` when it has none.
  private static func build(
    _ area: BrownfieldArea, root: URL, context: GateRun.Context, dependencies: Dependencies
  ) async -> (run: StepRun, milliseconds: Int)? {
    guard let template = area.build,
      let prepared = prepare(
        area, step: .build, repositoryRoot: root.path(percentEncoded: false), files: [],
        tree: .checkout, dependencies: dependencies)
    else { return nil }
    let request = atHead(prepared.request, kind: area.kind, dependencies)
    let derivedData = Self.derivedData(request, kind: area.kind, dependencies)
    let (outcome, milliseconds) = await GateRun.timed { await dependencies.runner.run(request) }
    context.steps.record(
      .areaBuild, tier: nil, milliseconds: milliseconds,
      verdict: outcome == .passed ? .green : .red, derivedData: derivedData, area: area.name)
    let run = StepRun(
      area: area, step: .build, template: template, selection: [], outcome: outcome,
      bound: dependencies.bound(area.name, .build, .checkout),
      rerun: { scratch in
        rerunRequest(area, step: .build, scratch: scratch, files: [], dependencies: dependencies)
      }, lintUnread: false)
    return (run, milliseconds)
  }

  /// The area's changed tests at the head, then their prove.
  private static func tests(
    _ area: BrownfieldArea, change: Change, root: URL, base: String, context: GateRun.Context,
    dependencies: Dependencies
  ) async -> AreaResult {
    var result = AreaResult()
    var files: [ChangedTestFile] = []
    for added in change.added where ChangedTestIDs.isTestFile(added.path, of: area) {
      guard let content = dependencies.prove.readFile(root.appending(path: added.path)) else {
        result.findings += note("can't read \(added.path), so slice can't run its tests")
        result.blocked = true
        continue
      }
      files.append(ChangedTestFile(path: added.path, content: content, added: added))
    }
    guard !files.isEmpty else { return result }
    let (waits, lintMilliseconds) = await GateRun.timed { ChangedTestWaits.findings(files) }
    context.steps.record(
      .testlint, tier: nil, milliseconds: lintMilliseconds,
      verdict: waits.isEmpty ? .green : .red, area: area.name)
    // A loop with no bound can only spin until the command's bound kills it.
    guard waits.isEmpty else {
      result.findings += waits
      result.refused = true
      return result
    }
    let plan: BrownfieldProve.AreaPlan
    switch BrownfieldProve.plan(area, files: files) {
    case .run(let found): plan = found
    case .nothing: return result
    case .cannot(let reason):
      result.findings += reason.findings
      result.blocked = result.blocked || reason.verdict == .blocked
      return result
    }

    let (template, step): (String, AreaStep) =
      switch plan.command {
      case .selected(let template): (template, .testFiles)
      case .whole(let template): (template, .test)
      }
    let request = { @Sendable (repositoryRoot: URL, bound: AreaCommandBound) in
      testRequest(
        plan, template: template, step: step, repositoryRoot: repositoryRoot,
        deadline: bound.duration, dependencies: dependencies)
    }
    let rerun: @Sendable (URL) -> AreaCommandRequest = { scratch in
      request(scratch, dependencies.bound(area.name, step, .scratch))
    }
    let derivedData = Self.derivedData(
      atHead(
        request(root, dependencies.bound(area.name, step, .checkout)), kind: area.kind,
        dependencies),
      kind: area.kind, dependencies)
    // The command builds what it runs, so with no build the harness can see it starts cold.
    let bound = dependencies.bound(
      area.name, step, derivedData == .warm ? .checkout : .unbuiltCheckout)
    let head = atHead(request(root, bound), kind: area.kind, dependencies)
    let (outcome, milliseconds) = await GateRun.timed { await dependencies.runner.run(head) }
    if let counts = await dependencies.testCounts.counts(of: head) {
      context.areaTests.record(AreaTestCounts(area: area.name, step: step, counts: counts))
    }
    context.steps.record(
      .areaTest, tier: nil, milliseconds: milliseconds,
      verdict: outcome == .passed ? .green : .red, derivedData: derivedData, area: area.name)
    // A test file the merge base lacks fails there for being missing, which would read as the
    // same whole-step failure and hide the head's.
    let rerunnable = !files.contains { change.new.contains($0.path) }
    result.runs.append(
      StepRun(
        area: area, step: step, template: template, selection: plan.ids.map(\.selector),
        outcome: outcome, bound: bound, rerun: rerunnable ? rerun : nil, lintUnread: false))
    // A test that hung at the head would only hang again with the source reverted.
    if case .timedOut = outcome { return result }

    let config = BrownfieldConfig(
      brownfield: dependencies.config.brownfield, areas: [area],
      allow: dependencies.config.allow, buildPresets: dependencies.config.buildPresets,
      judge: dependencies.config.judge)
    let (proved, proveMilliseconds) = await GateRun.timed {
      await BrownfieldProve.prove(
        root: root, base: base, config: config,
        junitDirectory: dependencies.layout.worktreeRoot.appending(
          path: "junit/\(area.name)", directoryHint: .isDirectory),
        proofs: context.proofs, dependencies: dependencies.prove, layout: dependencies.layout)
    }
    let judgement = proved.judgement
    context.steps.record(
      .prove, tier: nil, milliseconds: proveMilliseconds, verdict: judgement.verdict,
      derivedData: proved.derivedData, area: area.name,
      lockWaitMilliseconds: proved.lockWaitMilliseconds)
    result.findings += judgement.findings
    result.blocked = result.blocked || judgement.verdict == .blocked
    return result
  }

  private static func testRequest(
    _ plan: BrownfieldProve.AreaPlan, template: String, step: AreaStep, repositoryRoot: URL,
    deadline: Duration, dependencies: Dependencies
  ) -> AreaCommandRequest {
    let area = plan.area
    let junit =
      template.contains(AreaCommandExpansion.junitPlaceholder)
      ? AreaCommandExpansion.junitPath(layout: dependencies.layout, area: area.name, step: step)
      : nil
    let command = ChangedTestIDs.expand(
      template, tests: ChangedTestIDs.testsArgument(kind: area.kind, ids: plan.ids),
      files: ChangedTestIDs.filesArgument(areaRoot: area.root, ids: plan.ids),
      junit: junit.map(ChangedTestIDs.shellQuoted))
    let directory = area.root == "." ? repositoryRoot : repositoryRoot.appending(path: area.root)
    return AreaCommandRequest(
      area: area.name, step: step, command: command,
      workingDirectory: directory.path(percentEncoded: false), deadline: deadline,
      environment: environment(area, dependencies), junitPath: junit)
  }

  private static func prepare(
    _ area: BrownfieldArea, step: AreaStep, repositoryRoot: String, files: [String],
    tree: AreaCommandTree, dependencies: Dependencies
  ) -> PreparedAreaCommand? {
    AreaCommandExpansion.prepare(
      area: area, step: step, repositoryRoot: repositoryRoot, files: files, tests: [],
      junitPath: AreaCommandExpansion.junitPath(
        layout: dependencies.layout, area: area.name, step: step),
      deadline: dependencies.bound(area.name, step, tree).duration,
      environment: environment(area, dependencies))
  }

  /// The step prepared again in the merge base's scratch tree. It was prepared once at the head
  /// from the same area, so it can't come back `nil`; `false` stands in so a rerun never passes.
  private static func rerunRequest(
    _ area: BrownfieldArea, step: AreaStep, scratch: URL, files: [String],
    dependencies: Dependencies
  ) -> AreaCommandRequest {
    let directory = scratch.path(percentEncoded: false)
    return prepare(
      area, step: step, repositoryRoot: directory, files: files, tree: .scratch,
      dependencies: dependencies)?
      .request
      ?? AreaCommandRequest(
        area: area.name, step: step, command: "false", workingDirectory: directory,
        deadline: dependencies.deadline, environment: [:], junitPath: nil)
  }

  /// A run in this worktree builds where ``AreaBuildPlacement`` puts it; a rerun in a scratch tree
  /// builds where ``ScratchTreeBuild`` puts it, so it never overwrites this worktree's build.
  private static func atHead(
    _ request: AreaCommandRequest, kind: AreaKind, _ dependencies: Dependencies
  ) -> AreaCommandRequest {
    AreaBuildPlacement.checkout(request, kind: kind, layout: dependencies.layout)
  }

  /// Whether the step's build directories already exist, read before it runs.
  private static func derivedData(
    _ request: AreaCommandRequest, kind: AreaKind, _ dependencies: Dependencies
  ) -> GateDerivedData {
    GateStepCollector.derivedData(
      buildDirectories: XcodeDerivedData.buildDirectories(
        request, kind: kind, layout: dependencies.layout
      ).map { URL(filePath: $0, directoryHint: .isDirectory) })
  }

  private static func environment(_ area: BrownfieldArea, _ dependencies: Dependencies)
    -> [String: String]
  {
    AreaCacheEnvironment.make(
      area: area, layout: dependencies.layout, tree: dependencies.trackedTree
    ).variables
  }

  private static func finding(_ run: StepRun, what: String, because reason: String) throws
    -> Finding
  {
    var what = what
    if case .timedOut = run.outcome { what = "\(run.step.rawValue) hung" }
    let rule: BrownfieldRuleID =
      switch run.step {
      case .build, .generate: .buildFailed
      case .lint: .lintFailed
      case .test, .testFiles, .e2e: .testFailed
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
      message: "\(run.area.name) \(what) at the head and \(reason) (`\(run.template)`), \(tail)",
      failureScenario: nil)
  }

  private static func verdict(of result: AreaResult) -> Verdict {
    result.findings.contains { $0.severity.failsGate } ? .red : result.blocked ? .blocked : .green
  }

  private static func seconds(_ milliseconds: Int) -> String {
    milliseconds % 1000 == 0
      ? "\(milliseconds / 1000)" : String(format: "%.1f", Double(milliseconds) / 1000)
  }

  private static func note(_ message: String, severity: Severity = .minor) -> [Finding] {
    (try? Finding(
      ruleID: CheckRun.notRunRuleID, severity: severity, file: ".", line: nil,
      message: "slice: \(message)", failureScenario: nil)).map { [$0] } ?? []
  }

  /// A BLOCKED outcome: the verdict says so even if the finding naming why can't be made.
  private static func blocked(_ reason: String) -> Outcome {
    Outcome(findings: note(reason), blocked: true)
  }
}
