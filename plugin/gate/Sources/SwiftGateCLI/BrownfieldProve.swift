import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Brownfield prove: each area's changed tests run through `test_files` in a scratch tree at the
/// task head with the task's non-test changes reverted.
enum BrownfieldProve {
  struct Dependencies: Sendable {
    let git: any Git
    let scratch: any ScratchWorktrees
    let runner: any AreaCommandRunning
    /// A file's text, or `nil` when it can't be read.
    let readFile: @Sendable (URL) -> String?
    /// Per command run, when ``bound`` is `nil`.
    let deadline: Duration
    /// The worktree's state, whose prove DerivedData an `xcodebuild` in the scratch tree builds
    /// in; `nil` leaves each command as it is.
    let layout: BrownfieldStateLayout?
    /// Each area's bound for a command in the scratch tree, by step.
    let bound: (@Sendable (_ area: String, _ step: AreaStep) -> AreaCommandBound)?
    /// How many tests a reverted run ran, from the reports it left.
    var testCounts = AreaTestCountReader()

    init(
      git: any Git, scratch: any ScratchWorktrees, runner: any AreaCommandRunning,
      readFile: @escaping @Sendable (URL) -> String? = {
        try? String(contentsOf: $0, encoding: .utf8)
      },
      deadline: Duration, layout: BrownfieldStateLayout? = nil,
      bound: (@Sendable (_ area: String, _ step: AreaStep) -> AreaCommandBound)? = nil
    ) {
      self.git = git
      self.scratch = scratch
      self.runner = runner
      self.readFile = readFile
      self.deadline = deadline
      self.layout = layout
      self.bound = bound
    }

    /// Live git and scratch trees under `layout`'s scratch directory, around `runner`.
    static func live(
      root: URL, layout: BrownfieldStateLayout, runner: any AreaCommandRunning, deadline: Duration
    ) -> Dependencies {
      let process = LiveProcessRunner()
      return Dependencies(
        git: LiveGit(runner: process, repositoryRoot: root.path),
        scratch: LiveScratchWorktrees(
          runner: process, repositoryRoot: root.path, directory: layout.scratchDirectory),
        runner: runner, deadline: deadline,
        layout: layout)
    }
  }

  /// Whether the scratch-tree build directories of `areas` already hold a build; `none` when no
  /// area's kind has 1 the harness places.
  static func derivedData(_ areas: [BrownfieldArea], layout: BrownfieldStateLayout)
    -> GateDerivedData
  {
    GateStepCollector.derivedData(
      buildDirectories: areas.flatMap { ScratchTreeBuild.buildDirectories(area: $0, layout: layout) }
        .map { URL(filePath: $0, directoryHint: .isDirectory) })
  }

  /// - Parameters:
  ///   - root: the worktree's toplevel.
  ///   - junitDirectory: where `{junit}` paths point.
  ///   - proofs: takes each changed test the reverted runs said something about, for the gate
  ///     run's `prove.result` events.
  static func run(
    root: URL, base: String, config: BrownfieldConfig, junitDirectory: URL,
    proofs: ProveResultCollector, dependencies: Dependencies
  ) async -> ChangedTestJudgement {
    await prove(
      root: root, base: base, config: config, junitDirectory: junitDirectory, proofs: proofs,
      dependencies: dependencies
    ).judgement
  }

  /// What a prove does with an area whose reverted run the box can't hold.
  enum OutOfTime: Sendable, Equatable {
    /// BLOCKED: a later gate can still prove it.
    case blocks
    /// A `prove.unproven` note: no later gate runs, and the area's tests passed at the head.
    case unproven
  }

  /// What a prove decided, and how its reverted runs built: `none` when it ran none.
  struct Outcome: Sendable, Equatable {
    let judgement: ChangedTestJudgement
    let derivedData: GateDerivedData
  }

  /// ``run(root:base:config:junitDirectory:proofs:dependencies:)``, labelled by the scratch-tree
  /// build directories of the areas whose changed tests it runs, read before they run, and `none`
  /// when it runs none.
  ///
  /// - Parameters:
  ///   - layout: the clone's state the label reads; `nil` reads `dependencies`'.
  ///   - outOfTime: what an area the box leaves too little time becomes.
  static func prove(
    root: URL, base: String, config: BrownfieldConfig, junitDirectory: URL,
    proofs: ProveResultCollector, dependencies: Dependencies, layout: BrownfieldStateLayout? = nil,
    outOfTime: OutOfTime = .blocks
  ) async -> Outcome {
    func unbuilt(_ judgement: ChangedTestJudgement) -> Outcome {
      Outcome(judgement: judgement, derivedData: .none)
    }
    let git = dependencies.git
    let mergeBase: String
    let changed: [String]
    let added: [AddedLines]
    do throws(GitError) {
      guard let found = try await git.mergeBase("HEAD", base) else {
        return unbuilt(
          blocked("HEAD and \(base) share no history, so there is no tree to revert to"))
      }
      mergeBase = found
      changed = try await git.changedFiles(since: mergeBase)
      added = try await git.addedLines(since: mergeBase)
    } catch {
      return unbuilt(blocked("git: \(error)"))
    }
    let tests = changed.filter { path in
      config.areas.contains { ChangedTestIDs.isTestFile(path, of: $0) }
    }
    var judgement = ChangedTestJudgement.empty
    var plans: [AreaPlan] = []
    for area in config.areas {
      var files: [ChangedTestFile] = []
      for change in added where ChangedTestIDs.isTestFile(change.path, of: area) {
        guard let content = dependencies.readFile(root.appending(path: change.path)) else {
          judgement = judgement.merged(
            with: blocked("can't read \(change.path)", file: change.path))
          continue
        }
        files.append(ChangedTestFile(path: change.path, content: content, added: change))
      }
      guard !files.isEmpty else { continue }
      switch plan(area, files: files) {
      case .run(let plan): plans.append(plan)
      case .nothing: continue
      case .cannot(let reason): judgement = judgement.merged(with: reason)
      }
    }
    guard !plans.isEmpty else {
      let names = config.areas.map(\.name).joined(separator: ", ")
      return unbuilt(
        judgement.merged(with: note("prove: no new or changed tests in \(names) since \(base)")))
    }
    // A plan whose run the box leaves too little time isn't started: it would only be killed.
    plans = plans.filter { plan in
      guard let bound = dependencies.bound?(plan.area.name, plan.step), bound.cannotFinish else {
        return true
      }
      let expected = bound.expected.map { " its measured \($0.components.seconds) s" } ?? ""
      let file = plan.ids.first?.file ?? "."
      switch outOfTime {
      case .blocks:
        judgement = judgement.merged(
          with: blocked(
            "\(plan.area.name)'s changed tests not run: \(bound.reason) can't hold\(expected)",
            file: file))
      case .unproven:
        judgement = judgement.merged(
          with: unproven(
            "\(plan.area.name)'s changed tests unproven, though its tests passed: "
              + "\(bound.reason) can't hold\(expected)", file: file))
      }
      return false
    }
    guard !plans.isEmpty else { return unbuilt(judgement) }
    let reverted = changed.filter { !tests.contains($0) }
    guard !reverted.isEmpty else {
      return unbuilt(
        judgement.merged(
          with: note("prove: only tests changed since \(base), so there is nothing to revert")))
    }
    let request = ScratchTreeRequest(
      revision: "HEAD", revertTo: mergeBase, copiedPaths: tests, revertedPaths: reverted)
    let built =
      (layout ?? dependencies.layout).map { Self.derivedData(plans.map(\.area), layout: $0) }
      ?? .none
    let ran: AreaRun
    do throws(ScratchWorktreeError) {
      ran = try await dependencies.scratch.withScratchTree(request) { toplevel in
        var total = AreaRun()
        for plan in plans {
          total =
            total
            + (await execute(
              plan, in: toplevel, junitDirectory, proofBase: mergeBase, dependencies))
        }
        return total
      }
    } catch {
      return unbuilt(judgement.merged(with: blocked("scratch worktree: \(error)")))
    }
    proofs.record(ran.proved)
    return Outcome(
      judgement: judgement.merged(with: ran.judgement).merged(
        with: note(
          "prove: \(ran.proven) of \(ran.total) changed tests fail with the change's source "
            + "reverted")),
      derivedData: built)
  }

  /// How 1 area's changed tests run.
  struct AreaPlan: Sendable {
    enum Command: Sendable {
      /// `test_files`, expanded per selection.
      case selected(String)
      /// `test`, once, because the area can't select its changed tests.
      case whole(String)
    }

    let area: BrownfieldArea
    let ids: [AreaTestID]
    let command: Command
    /// The step its first run is.
    var step: AreaStep {
      switch command {
      case .selected: .testFiles
      case .whole: .test
      }
    }
  }

  /// The outcome of running some areas' plans.
  struct AreaRun: Sendable {
    var judgement = ChangedTestJudgement.empty
    var proven = 0
    var total = 0
    var proved: [ProvedTest] = []

    static func + (lhs: AreaRun, rhs: AreaRun) -> AreaRun {
      AreaRun(
        judgement: lhs.judgement.merged(with: rhs.judgement), proven: lhs.proven + rhs.proven,
        total: lhs.total + rhs.total, proved: lhs.proved + rhs.proved)
    }
  }

  enum Planned: Sendable {
    case run(AreaPlan)
    /// The change touches test files but no test in them.
    case nothing
    case cannot(ChangedTestJudgement)
  }

  static func plan(_ area: BrownfieldArea, files: [ChangedTestFile]) -> Planned {
    if let template = area.testFiles {
      if template.contains("{tests}") {
        let ids =
          area.kind == .swiftpm
          ? ChangedTestIDs.swift(files.flatMap(swiftTests))
          : ChangedTestIDs.ids(kind: area.kind, areaRoot: area.root, files: files)
        if let ids {
          return ids.isEmpty
            ? .nothing : .run(AreaPlan(area: area, ids: ids, command: .selected(template)))
        }
      } else if template.contains("{files}") {
        return .run(
          AreaPlan(
            area: area, ids: ChangedTestIDs.files(areaRoot: area.root, files: files),
            command: .selected(template)))
      }
    }
    guard let whole = area.test ?? area.testFiles else {
      return .cannot(
        blocked(
          "\(area.name) has changed tests but neither test nor test_files, so prove can't run "
            + "them", file: files[0].path))
    }
    return .run(
      AreaPlan(
        area: area, ids: ChangedTestIDs.files(areaRoot: area.root, files: files),
        command: .whole(whole)))
  }

  /// The test functions a Swift file's change adds or edits, in the target its `Tests/<target>/`
  /// directory names.
  private static func swiftTests(_ file: ChangedTestFile) -> [ChangedTest] {
    let components = file.path.split(separator: "/").map(String.init)
    let target =
      components.firstIndex(of: "Tests").flatMap {
        $0 + 2 < components.count ? components[$0 + 1] : nil
      } ?? components.dropLast().last ?? ""
    let unit = SourceUnit(input: SourceInput(path: file.path, text: file.content), scope: nil)
    return ChangedTestDiscovery.tests(in: unit, target: target, added: file.added)
  }

  private static func execute(
    _ plan: AreaPlan, in toplevel: URL, _ junitDirectory: URL, proofBase: String,
    _ dependencies: Dependencies
  ) async -> AreaRun {
    let area = plan.area
    let directory = area.root == "." ? toplevel : toplevel.appending(path: area.root)
    // Read again for each run: the box's time left shrinks between them.
    var bound: AreaCommandBound?
    var runs = 0
    /// The run's outcome and how many tests its reports show it ran.
    func run(_ template: String, step: AreaStep, ids: [AreaTestID]) async -> (
      outcome: AreaCommandOutcome, executed: Int?
    ) {
      runs += 1
      bound = dependencies.bound?(area.name, step)
      var junit: String?
      if template.contains("{junit}") {
        try? FileManager.default.createDirectory(
          at: junitDirectory, withIntermediateDirectories: true)
        let path = junitDirectory.appending(path: "\(area.name)-prove-\(runs).xml").path
        // An earlier prove's report at the same path would read as this run's.
        for stale in [path] + JUnitReports.companionPaths(of: path) {
          try? FileManager.default.removeItem(atPath: stale)
        }
        junit = path
      }
      let command = ChangedTestIDs.expand(
        template, tests: ChangedTestIDs.testsArgument(kind: area.kind, ids: ids),
        files: ChangedTestIDs.filesArgument(areaRoot: area.root, ids: ids),
        junit: junit.map(ChangedTestIDs.shellQuoted))
      let request = AreaCommandRequest(
        area: area.name, step: step, command: command, workingDirectory: directory.path,
        deadline: bound?.duration ?? dependencies.deadline, environment: [:], junitPath: junit)
      let placed =
        dependencies.layout.map { ScratchTreeBuild.request(request, kind: area.kind, layout: $0) }
        ?? request
      let outcome = await dependencies.runner.run(placed)
      return (outcome, await dependencies.testCounts.counts(of: placed)?.tests)
    }
    let outcomes: [(AreaTestID, AreaCommandOutcome)]
    let judgement: ChangedTestJudgement
    let whole: Bool
    switch plan.command {
    case .whole(let command):
      whole = true
      let outcome = await run(command, step: .test, ids: plan.ids).outcome
      outcomes = plan.ids.map { ($0, outcome) }
      judgement = ProveVerdict.judgeWhole(
        area: area.name, ids: plan.ids, outcome: outcome, bound: bound)
    case .selected(let template):
      whole = false
      let together = await run(template, step: .testFiles, ids: plan.ids)
      if ProveVerdict.needsRerunAlone(
        together.outcome, idCount: plan.ids.count, executed: together.executed)
      {
        var alone: [(AreaTestID, AreaCommandOutcome)] = []
        for id in plan.ids {
          let ran = await run(template, step: .testFiles, ids: [id])
          alone.append((id, ProveVerdict.reading(ran.outcome, executed: ran.executed)))
        }
        outcomes = alone
      } else {
        let outcome = ProveVerdict.reading(together.outcome, executed: together.executed)
        outcomes = plan.ids.map { ($0, outcome) }
      }
      judgement = ProveVerdict.judge(area: area.name, outcomes: outcomes, bound: bound)
    }
    let proven = outcomes.filter {
      if case .failed = $0.1 { return true }
      return false
    }.count
    return AreaRun(
      judgement: judgement, proven: proven, total: plan.ids.count,
      proved: BrownfieldProofs.proved(
        area: area.name, outcomes: outcomes, whole: whole, proofBase: proofBase))
  }

  private static func blocked(_ message: String, file: String = ".") -> ChangedTestJudgement {
    let finding = try? Finding(
      ruleID: ProofRules.noEvidenceRuleID, severity: .minor, file: file, line: nil,
      message: "prove: \(message)", failureScenario: nil)
    return ChangedTestJudgement(findings: finding.map { [$0] } ?? [], blocked: true)
  }

  private static func unproven(_ message: String, file: String) -> ChangedTestJudgement {
    let finding = try? Finding(
      ruleID: ProofRules.unprovenRuleID, severity: .nit, file: file, line: nil,
      message: "prove: \(message)", failureScenario: nil)
    return ChangedTestJudgement(findings: finding.map { [$0] } ?? [], blocked: false)
  }

  private static func note(_ message: String) -> ChangedTestJudgement {
    let finding = try? Finding(
      ruleID: ProofRules.summaryRuleID, severity: .nit, file: ".", line: nil, message: message,
      failureScenario: nil)
    return ChangedTestJudgement(findings: finding.map { [$0] } ?? [], blocked: false)
  }
}
