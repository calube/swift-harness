import Foundation
import SwiftGateAdapters
import SwiftGateDomain

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
    let prove: BrownfieldProve.Dependencies
    /// The tracked files, for each area's shared cache variables.
    let trackedTree: TrackedTreeSnapshot
    /// `git rev-parse <commit>^{tree}`: the baseline and warm-up files' name.
    let tree: @Sendable (_ commit: String) async throws -> String
    /// The area's warm test time at the base tree `tree`, in milliseconds; `nil` when no warm-up
    /// measured it.
    let warmTestMilliseconds: @Sendable (_ area: BrownfieldArea, _ tree: String) async -> Int?
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

    /// A selected test run that fits the budget warm still gets room on a cold store.
    static let liveDeadline: Duration = .seconds(600)

    /// The clone's config and state, live git, scratch trees under the worktree's git dir and
    /// `/bin/sh` commands.
    static func live(root: URL) async throws(BrownfieldCheckSetupError) -> Dependencies {
      let merge = try await BrownfieldMergeCheck.Dependencies.live(root: root)
      return Dependencies(
        config: merge.config, layout: merge.layout, git: merge.git, runner: merge.runner,
        baseline: merge.baseline,
        prove: BrownfieldProve.Dependencies.live(
          root: root, layout: merge.layout, runner: merge.runner, deadline: liveDeadline),
        trackedTree: merge.trackedTree, tree: merge.tree,
        warmTestMilliseconds: { [layout = merge.layout] area, tree in
          WarmupTimesStore(layout: layout).load(tree: tree).file.areas[area.name]?
            .warmTestMilliseconds
        },
        history: { commit in try await firstParentHistory(of: commit, root: root) },
        changedBetween: { [git = merge.git] from, to in
          try await git.changedFiles(from: from, to: to)
        },
        judgeAssertion: BrownfieldJudge.assertionJudge(
          BrownfieldJudge.live(merge.config.judge, root: root)),
        deadline: liveDeadline)
    }
  }

  /// `git log --first-parent` from `commit`, each line `<commit> <tree>`.
  private static func firstParentHistory(of commit: String, root: URL) async throws
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

    mutating func add(_ other: AreaResult) {
      findings += other.findings
      runs += other.runs
      blocked = blocked || other.blocked
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

    let touched = areas.filter { area in
      changed.contains { BrownfieldMergeCheck.owner(of: $0, in: areas)?.name == area.name }
    }
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
    let queries = failing.compactMap { run -> BaselineQuery? in
      guard let rerun = run.rerun else { return nil }
      return BaselineQuery(
        key: BaselineStepKey(
          area: run.area.name, step: run.step, command: run.template, selection: run.selection),
        head: run.outcome, request: rerun)
    }
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
        verdict: remaining.isEmpty ? .green : .red)
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
      warmTest: dependencies.warmTestMilliseconds, changed: dependencies.changedBetween)
    return (resolution.times, notes + resolution.notes.flatMap { note($0) })
  }

  /// 1 touched area: the neutral rules, Xcode membership and lint on its changed files, then its
  /// changed tests and their prove when a warm test run fits the budget, else its build. An area
  /// changed since the warm-up that measured it builds first, so its tests never run on caches
  /// the warm-up left behind its code. A change that selects no test builds instead, so its code
  /// still compiles.
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
    let why: String
    switch warm {
    case .current(let milliseconds, _) where milliseconds <= budget:
      let tested = await tests(
        area, change: change, root: root, base: base, context: context,
        dependencies: dependencies)
      result.add(tested)
      guard tested.runs.isEmpty else { return result }
      if let build = await build(area, root: root, context: context, dependencies: dependencies) {
        result.runs.append(build.run)
      } else {
        result.findings += stepDropped(area)
      }
      return result
    case .stale(let milliseconds, let at, _) where milliseconds <= budget:
      guard let build = await build(area, root: root, context: context, dependencies: dependencies)
      else {
        result.findings += buildOnly(
          area,
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
      result.findings += buildOnly(area, because: why)
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
    result.findings += buildOnly(area, because: why)
    if let build = await build(area, root: root, context: context, dependencies: dependencies) {
      result.runs.append(build.run)
    } else {
      result.findings += stepDropped(area)
    }
    return result
  }

  private static func buildOnly(_ area: BrownfieldArea, because why: String) -> [Finding] {
    (try? Finding(
      ruleID: BrownfieldRuleID.buildOnly.rawValue, severity: .nit, file: area.root, line: nil,
      message:
        "\(area.name): \(why), so slice only builds it; its changed tests and their prove run "
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
        dependencies: dependencies)
    else { return nil }
    let (outcome, milliseconds) = await GateRun.timed {
      await dependencies.runner.run(prepared.request)
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
        dependencies: dependencies)
    else { return nil }
    let (outcome, milliseconds) = await GateRun.timed {
      await dependencies.runner.run(prepared.request)
    }
    context.steps.record(
      .areaBuild, tier: nil, milliseconds: milliseconds,
      verdict: outcome == .passed ? .green : .red, area: area.name)
    let run = StepRun(
      area: area, step: .build, template: template, selection: [], outcome: outcome,
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
    let request = { @Sendable (repositoryRoot: URL) in
      testRequest(
        plan, template: template, step: step, repositoryRoot: repositoryRoot,
        dependencies: dependencies)
    }
    let (outcome, milliseconds) = await GateRun.timed {
      await dependencies.runner.run(request(root))
    }
    context.steps.record(
      .areaTest, tier: nil, milliseconds: milliseconds,
      verdict: outcome == .passed ? .green : .red, area: area.name)
    // A test file the merge base lacks fails there for being missing, which would read as the
    // same whole-step failure and hide the head's.
    let rerunnable = !files.contains { change.new.contains($0.path) }
    result.runs.append(
      StepRun(
        area: area, step: step, template: template, selection: plan.ids.map(\.selector),
        outcome: outcome, rerun: rerunnable ? request : nil, lintUnread: false))

    let config = BrownfieldConfig(
      brownfield: dependencies.config.brownfield, areas: [area],
      allow: dependencies.config.allow, buildPresets: dependencies.config.buildPresets,
      judge: dependencies.config.judge)
    let (judgement, proveMilliseconds) = await GateRun.timed {
      await BrownfieldProve.run(
        root: root, base: base, config: config,
        junitDirectory: dependencies.layout.worktreeRoot.appending(
          path: "junit/\(area.name)", directoryHint: .isDirectory),
        proofs: context.proofs, dependencies: dependencies.prove)
    }
    context.steps.record(
      .prove, tier: nil, milliseconds: proveMilliseconds, verdict: judgement.verdict,
      area: area.name)
    result.findings += judgement.findings
    result.blocked = result.blocked || judgement.verdict == .blocked
    return result
  }

  private static func testRequest(
    _ plan: BrownfieldProve.AreaPlan, template: String, step: AreaStep, repositoryRoot: URL,
    dependencies: Dependencies
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
      workingDirectory: directory.path(percentEncoded: false), deadline: dependencies.deadline,
      environment: environment(area, dependencies), junitPath: junit)
  }

  private static func prepare(
    _ area: BrownfieldArea, step: AreaStep, repositoryRoot: String, files: [String],
    dependencies: Dependencies
  ) -> PreparedAreaCommand? {
    AreaCommandExpansion.prepare(
      area: area, step: step, repositoryRoot: repositoryRoot, files: files, tests: [],
      junitPath: AreaCommandExpansion.junitPath(
        layout: dependencies.layout, area: area.name, step: step),
      deadline: dependencies.deadline, environment: environment(area, dependencies))
  }

  /// The step prepared again in the merge base's scratch tree. It was prepared once at the head
  /// from the same area, so it can't come back `nil`; `false` stands in so a rerun never passes.
  private static func rerunRequest(
    _ area: BrownfieldArea, step: AreaStep, scratch: URL, files: [String],
    dependencies: Dependencies
  ) -> AreaCommandRequest {
    let directory = scratch.path(percentEncoded: false)
    return prepare(
      area, step: step, repositoryRoot: directory, files: files, dependencies: dependencies)?
      .request
      ?? AreaCommandRequest(
        area: area.name, step: step, command: "false", workingDirectory: directory,
        deadline: dependencies.deadline, environment: [:], junitPath: nil)
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
      case .timedOut(let tail): "timed out:\n\(tail)"
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
