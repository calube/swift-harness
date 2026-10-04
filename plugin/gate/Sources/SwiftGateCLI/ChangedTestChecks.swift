import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// `prove`, `stress` and per-test reach (spec §7.2 rules 2 and 6, §7.4) over the host (T1) tests
/// a change adds or edits since the merge base. Simulator tests are out of scope here.
enum ChangedTestChecks {
  static let summaryRuleID = "changed-tests.summary"

  struct Environment: Sendable {
    let root: URL
    let git: any Git
    let swiftPM: any SwiftPM
    let scratch: any ScratchWorktrees
    /// SwiftPM rooted at a scratch tree's copy of this project.
    let scratchSwiftPM: @Sendable (URL) -> any SwiftPM

    /// Live scratch worktrees and scratch SwiftPM around the given repository adapters.
    static func live(root: URL, git: any Git, swiftPM: any SwiftPM) -> Environment {
      Environment(
        root: root, git: git, swiftPM: swiftPM,
        scratch: LiveScratchWorktrees(runner: LiveProcessRunner(), repositoryRoot: root.path),
        scratchSwiftPM: { ScopeResolution.liveSwiftPM(root: $0) })
    }

    static func live(root: URL) -> Environment {
      live(
        root: root, git: LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path),
        swiftPM: ScopeResolution.liveSwiftPM(root: root))
    }
  }

  /// The changed tests of one package.
  struct PackageTests: Sendable {
    let packagePath: String
    let tests: [ChangedTest]
    let targets: [TestTargetReference]
    /// Every test target directory of the package, changed or not.
    let testDirectories: [String]

    var selection: HostTestSelection {
      HostTestSelection(
        packagePath: packagePath, targets: targets, filter: ChangedTest.filter(selecting: tests))
    }

    /// The same package with only `tests`, and only the targets they're in.
    func narrowed(to tests: [ChangedTest]) -> PackageTests {
      let names = Set(tests.map(\.target))
      return PackageTests(
        packagePath: packagePath, tests: tests, targets: targets.filter { names.contains($0.name) },
        testDirectories: testDirectories)
    }

    func selection(of test: ChangedTest) -> HostTestSelection {
      HostTestSelection(
        packagePath: packagePath, targets: targets.filter { $0.name == test.target },
        filter: test.filter)
    }
  }

  struct Selection: Sendable {
    let mergeBase: String
    let packages: [PackageTests]

    var tests: [ChangedTest] { packages.flatMap(\.tests) }
  }

  // MARK: - Selection

  /// Host tests whose declarations intersect lines added since the merge base of HEAD and `base`.
  static func select(_ environment: Environment, graph: ModuleGraph, base: String) async
    -> Result<Selection, BlockedReason>
  {
    let mergeBase: String
    let added: [AddedLines]
    do throws(GitError) {
      guard let found = try await environment.git.mergeBase("HEAD", base) else {
        return .failure(BlockedReason("HEAD and \(base) share no history; pass --base <ref>"))
      }
      mergeBase = found
      let prefix = try await environment.git.workingDirectoryPrefix()
      added = try await environment.git.addedLines(since: mergeBase)
        .filter { $0.path.hasPrefix(prefix) }
        .map { AddedLines(path: String($0.path.dropFirst(prefix.count)), ranges: $0.ranges) }
    } catch {
      return .failure(BlockedReason("git: \(error)"))
    }
    var byPackage: [String: [ChangedTest]] = [:]
    for change in added where change.path.hasSuffix(".swift") {
      guard let module = graph.module(containingFile: change.path),
        module.role == .tests(.t1), module.isHostTestable,
        let package = graph.package(of: module),
        let text = try? String(
          contentsOf: environment.root.appending(path: change.path), encoding: .utf8)
      else { continue }
      let unit = SourceUnit(input: SourceInput(path: change.path, text: text), scope: module.scope)
      let tests = ChangedTestDiscovery.tests(in: unit, target: module.name, added: change)
      if !tests.isEmpty { byPackage[package.path, default: []] += tests }
    }
    let packages = byPackage.keys.sorted().map { path in
      let tests = byPackage[path] ?? []
      let testModules = graph.modules.filter { module in
        guard case .tests = module.role, let package = graph.package(of: module) else {
          return false
        }
        return package.path == path
      }
      return PackageTests(
        packagePath: path, tests: tests,
        targets: Set(tests.map(\.target)).sorted().map { name in
          TestTargetReference(name: name, path: graph.module(named: name)?.path ?? path)
        },
        testDirectories: testModules.map(\.path))
    }
    return .success(Selection(mergeBase: mergeBase, packages: packages))
  }

  /// Spec §7.2 rule 6's N for the `ready` tier.
  static let readyStressIterations = 10

  // MARK: - prove

  /// - Parameter proofBases: ancestors of HEAD, oldest first, where a test that fails to compile
  ///   or to load its package at an earlier base is tried again.
  static func prove(
    _ environment: Environment, graph: ModuleGraph, base: String, proofBases: [String] = [],
    context: GateRun.Context
  ) async -> ChangedTestJudgement {
    var derivedData = GateDerivedData.none
    let (result, milliseconds) = await GateRun.timed {
      await proveUntimed(
        environment, graph: graph, base: base, proofBases: proofBases, context: context,
        derivedData: &derivedData)
    }
    context.steps.record(
      .prove, tier: .t1, milliseconds: milliseconds, verdict: result.judgement.verdict,
      derivedData: derivedData)
    return result.withSummary(result.summary.map { "prove: \($0) (\(duration(milliseconds)))" })
  }

  /// - Parameter derivedData: set from the selected packages' build directories before the
  ///   change's own run builds them.
  private static func proveUntimed(
    _ environment: Environment, graph: ModuleGraph, base: String, proofBases: [String],
    context: GateRun.Context, derivedData: inout GateDerivedData
  ) async -> SummarizedJudgement {
    let selection: Selection
    switch await select(environment, graph: graph, base: base) {
    case .failure(let reason): return .blocked(ProofRules.noEvidenceRuleID, reason.text)
    case .success(let found): selection = found
    }
    derivedData = HostTestCheck.derivedData(
      selection.packages.map(\.selection), root: environment.root)
    for proofBase in proofBases {
      do throws(GitError) {
        guard try await environment.git.isAncestor(proofBase, of: "HEAD") else {
          return .blocked(
            ProofRules.noEvidenceRuleID,
            "proof base \(proofBase) is not an ancestor of HEAD, so the change never went through it"
          )
        }
      } catch {
        return .blocked(ProofRules.noEvidenceRuleID, "git: \(error)")
      }
    }
    guard !selection.packages.isEmpty else {
      return .note("prove: no new or changed host tests since \(base)")
    }
    let changed: [String]
    let prefix: String
    do throws(GitError) {
      changed = try await environment.git.changedFiles(since: selection.mergeBase)
      prefix = try await environment.git.workingDirectoryPrefix()
    } catch {
      return .blocked(ProofRules.noEvidenceRuleID, "git: \(error)")
    }
    let (reverted, copied) = partition(changed, prefix: prefix, graph: graph)
    guard !reverted.isEmpty else {
      return .note(
        "prove: no production source changed since \(base), so there is nothing to revert")
    }

    let output = context.directory.appending(path: "prove")
    var judgement = ChangedTestJudgement.empty
    for package in selection.packages {
      let run = await runOnce(
        package, swiftPM: environment.swiftPM, root: environment.root,
        output: output.appending(path: "change"), coverage: false)
      judgement = judgement.merged(with: ProofRules.judgeChange(package.tests, run: run.run))
    }

    var attempts: [String: [ProofRules.RevertedAttempt]] = [:]
    // The last reverted run that ran a test decides its outcome, as it decides its verdict.
    var proofs: [ChangedTest: ProvedTest] = [:]
    var pending = selection.packages
    let revertTargets = [selection.mergeBase] + proofBases
    for (index, revertTo) in revertTargets.enumerated() where !pending.isEmpty {
      let request = ScratchTreeRequest(
        revision: "HEAD", revertTo: revertTo, copiedPaths: copied, revertedPaths: reverted)
      let tried: [(PackageTests, ProofRules.RevertedAttempt)]
      do throws(ScratchWorktreeError) {
        tried = try await runReverted(
          environment, pending, request: request, prefix: prefix,
          output: output.appending(path: index == 0 ? "reverted" : "reverted-\(index)")
        ).map { package, run, evidence in
          let result = ProofRules.judgeReverted(
            package.tests, run: run, testDirectories: package.testDirectories)
          for test in package.tests {
            proofs[test] = proved(
              test, run: run, evidence: evidence, judgement: result.judgement, base: revertTo,
              root: environment.root)
          }
          return (
            package,
            ProofRules.RevertedAttempt(
              base: revertTo, tests: package.tests, judgement: result.judgement,
              proven: result.proven)
          )
        }
      } catch {
        return SummarizedJudgement(
          judgement: judgement.merged(
            with: SummarizedJudgement.blocked(
              ProofRules.noEvidenceRuleID, "scratch worktree: \(error)"
            ).judgement),
          summary: nil)
      }
      pending = []
      for (package, attempt) in tried {
        attempts[package.packagePath, default: []].append(attempt)
        let retry = ProofRules.retryable(package.tests, in: attempt.judgement)
        if !retry.isEmpty { pending.append(package.narrowed(to: retry)) }
      }
    }
    var proven = 0
    var provenAtProofBase = 0
    for package in selection.packages {
      let combined = ProofRules.combine(attempts[package.packagePath] ?? [])
      judgement = judgement.merged(with: combined.judgement)
      proven += combined.proven.count
      provenAtProofBase += combined.provenAtProofBase
    }
    context.proofs.record(selection.tests.compactMap { proofs[$0] })
    let total = selection.tests.count
    return SummarizedJudgement(
      judgement: judgement,
      summary:
        "\(proven) of \(total) new or changed host tests fail on an assertion with "
        + "the source change reverted"
        + (provenAtProofBase > 0 ? ", \(provenAtProofBase) of them at a proof base" : ""))
  }

  /// What 1 reverted run says about `test`, with where it first failed when it failed. The test
  /// file is read from `root`, where the reverted run's copy came from, only to tell the
  /// assertion's form.
  private static func proved(
    _ test: ChangedTest, run: SelectedTestRun, evidence: HostTestEvidence?,
    judgement: ChangedTestJudgement, base: String, root: URL
  ) -> ProvedTest? {
    guard let outcome = ProvedTest.outcome(of: test, run: run, judgement: judgement) else {
      return nil
    }
    let assertion =
      outcome == .proven
      ? evidence.flatMap { evidence in
        ProveAssertionLocator.firstFailure(of: test, in: evidence) { file, line in
          (try? String(contentsOf: root.appending(path: file), encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst(line - 1).first.map(String.init)
        }
      } : nil
    return ProvedTest(
      test: TestCaseResult.identifier(
        target: test.target, suites: test.suites, name: test.function),
      target: test.target, outcome: outcome, proofBase: base, assertion: assertion)
  }

  /// Splits toplevel-relative `changed` paths into the production source `prove` reverts and the
  /// rest, which keeps the change: tests, manifests, resources and config. A path outside the
  /// module graph (no Package.swift target claims it) is production input too when it's data the
  /// harness ships and its own commands read — a stamped template, a self-test seed — so it
  /// reverts alongside the Swift sources instead of silently keeping the change under test.
  static func partition(_ changed: [String], prefix: String, graph: ModuleGraph)
    -> (reverted: [String], copied: [String])
  {
    var reverted: [String] = []
    var copied: [String] = []
    for path in changed {
      guard path.hasPrefix(prefix) else { continue }
      let relative = String(path.dropFirst(prefix.count))
      let module = graph.module(containingFile: relative)
      let isProduction = module.map { !isTestModule($0) } ?? isProductionResource(relative)
      if isProduction { reverted.append(path) } else { copied.append(path) }
    }
    return (reverted, copied)
  }

  /// Runs each package's selected tests in one scratch tree made for `request`: the step every
  /// reverted run of `prove` takes, and the one `build check-return` builds a task's tests with.
  static func runReverted(
    _ environment: Environment, _ packages: [PackageTests], request: ScratchTreeRequest,
    prefix: String, output: URL
  ) async throws(ScratchWorktreeError) -> [(PackageTests, SelectedTestRun, HostTestEvidence?)] {
    try await environment.scratch.withScratchTree(request) { toplevel in
      let root = prefix.isEmpty ? toplevel : toplevel.appending(path: prefix)
      let swiftPM = environment.scratchSwiftPM(root)
      var runs: [(PackageTests, SelectedTestRun, HostTestEvidence?)] = []
      for package in packages {
        let run = await runOnce(
          package, swiftPM: swiftPM, root: root, output: output, coverage: false)
        runs.append((package, run.run, run.evidence))
      }
      return runs
    }
  }

  /// Builds and runs `selection`'s tests with `reverted` restored to each of `proofBases` in
  /// turn, trying a package again at the next base only while its tests fail to build. Returns
  /// each package's outcome at the last base it was tried at.
  static func buildAtProofBases(
    _ environment: Environment, selection: Selection, revision: String, reverted: [String],
    proofBases: [String], prefix: String, output: URL
  ) async throws(ScratchWorktreeError) -> [(
    package: PackageTests, base: String, outcome: ProofBaseTestBuild.Outcome
  )] {
    var last: [String: (package: PackageTests, base: String, outcome: ProofBaseTestBuild.Outcome)] =
      [:]
    var pending = selection.packages
    for (index, base) in proofBases.enumerated() where !pending.isEmpty {
      let request = ScratchTreeRequest(
        revision: revision, revertTo: base, copiedPaths: [], revertedPaths: reverted,
        seededBuildDirectories: pending.map { prefix + $0.packagePath })
      let runs = try await runReverted(
        environment, pending, request: request, prefix: prefix,
        output: output.appending(path: "base-\(index)"))
      pending = []
      for (package, run, _) in runs {
        let outcome = ProofBaseTestBuild.outcome(of: run, testDirectories: package.testDirectories)
        last[package.packagePath] = (package, base, outcome)
        if outcome != .compiled { pending.append(package) }
      }
    }
    return selection.packages.compactMap { last[$0.packagePath] }
  }

  private static func isTestModule(_ module: Module) -> Bool {
    if case .tests = module.role { return true }
    return false
  }

  /// Non-Swift files outside the module graph that still count as production input a changed
  /// test can guard: bootstrap stamps the templates, and `self-test` reads the seeds as its
  /// answer key. Explicit and short on purpose: anything else outside the graph (docs, captured
  /// tool-output fixtures, a test's own resources) keeps the change, as it always has.
  private static let productionResourcePrefixes = [
    "plugin/templates/", "plugin/gate/Fixtures/seeds/", "plugin/bin/",
  ]

  private static func isProductionResource(_ path: String) -> Bool {
    Self.productionResourcePrefixes.contains { path.hasPrefix($0) }
  }

  // MARK: - stress

  /// Runs every package's changed tests `iterations` times. `swift test` on this toolchain has no
  /// shuffle or repeat option for either framework, so each iteration is its own `--parallel`
  /// process: Swift Testing runs the selected tests concurrently and XCTest spreads them over
  /// worker processes, so their relative order is not fixed from one iteration to the next.
  static func stress(
    _ environment: Environment, graph: ModuleGraph, base: String, iterations: Int,
    context: GateRun.Context
  ) async -> ChangedTestJudgement {
    var derivedData = GateDerivedData.none
    let (result, milliseconds) = await GateRun.timed { () async -> SummarizedJudgement in
      let selection: Selection
      switch await select(environment, graph: graph, base: base) {
      case .failure(let reason): return .blocked(StressRules.noEvidenceRuleID, reason.text)
      case .success(let found): selection = found
      }
      derivedData = HostTestCheck.derivedData(
        selection.packages.map(\.selection), root: environment.root)
      guard !selection.packages.isEmpty else {
        return .note("stress: no new or changed host tests since \(base)")
      }
      var runs: [String: [SelectedTestRun]] = [:]
      for iteration in 1...max(1, iterations) {
        let results = await HostTestRunner(swiftPM: environment.swiftPM, root: environment.root)
          .run(
            selection.packages.map(\.selection),
            outputDirectory: context.directory.appending(path: "stress/run-\(iteration)"),
            readCoverage: false)
        for (package, result) in zip(selection.packages, results) {
          runs[package.packagePath, default: []].append(observe(package.tests, result))
        }
      }
      var judgement = ChangedTestJudgement.empty
      for package in selection.packages {
        judgement = judgement.merged(
          with: StressRules.judge(package.tests, runs: runs[package.packagePath] ?? []))
      }
      return SummarizedJudgement(
        judgement: judgement,
        summary: "\(selection.tests.count) new or changed host tests × \(iterations) runs")
    }
    context.steps.record(
      .stress, tier: .t1, milliseconds: milliseconds, verdict: result.judgement.verdict,
      derivedData: derivedData)
    return result.withSummary(result.summary.map { "stress: \($0) (\(duration(milliseconds)))" })
  }

  // MARK: - reach

  /// Runs each changed test alone with coverage. Serial: runs of one package share its build
  /// directory and coverage export.
  static func reach(
    _ environment: Environment, graph: ModuleGraph, base: String, context: GateRun.Context
  ) async -> ChangedTestJudgement {
    var derivedData = GateDerivedData.none
    let (result, milliseconds) = await GateRun.timed { () async -> SummarizedJudgement in
      let selection: Selection
      switch await select(environment, graph: graph, base: base) {
      case .failure(let reason): return .blocked(ReachRules.noDataRuleID, reason.text)
      case .success(let found): selection = found
      }
      derivedData = HostTestCheck.derivedData(
        selection.packages.map(\.selection), root: environment.root)
      guard !selection.packages.isEmpty else {
        return .note("reach: no new or changed host tests since \(base)")
      }
      let rootPath = CanonicalPath.of(environment.root)
      var judgement = ChangedTestJudgement.empty
      var index = 0
      for package in selection.packages {
        for test in package.tests {
          index += 1
          let run = await HostTestRunner(swiftPM: environment.swiftPM, root: environment.root)
            .run(
              [package.selection(of: test)],
              outputDirectory: context.directory.appending(path: "reach/test-\(index)"),
              readCoverage: true
            ).first
          var coverage: LineCoverage?
          if case .ran(_, let export?) = run {
            coverage = try? LineCoverage(llvmExport: export, repositoryRoot: rootPath)
          }
          judgement = judgement.merged(
            with: ReachRules.judge(
              test, run: run.map { observe([test], $0) } ?? .noEvidence("swift test did not run"),
              coverage: coverage, subjects: ReachRules.subjects(ofTarget: test.target, in: graph),
              graph: graph))
        }
      }
      return SummarizedJudgement(
        judgement: judgement,
        summary: "\(selection.tests.count) new or changed host tests run alone with coverage")
    }
    context.steps.record(
      .reach, tier: .t1, milliseconds: milliseconds, verdict: result.judgement.verdict,
      derivedData: derivedData)
    return result.withSummary(result.summary.map { "reach: \($0) (\(duration(milliseconds)))" })
  }

  // MARK: - Running

  private static func runOnce(
    _ package: PackageTests, swiftPM: any SwiftPM, root: URL, output: URL, coverage: Bool
  ) async -> (run: SelectedTestRun, coverage: Data?, evidence: HostTestEvidence?) {
    let result = await HostTestRunner(swiftPM: swiftPM, root: root).run(
      [package.selection], outputDirectory: output, readCoverage: coverage
    ).first
    guard let result else { return (.noEvidence("swift test did not run"), nil, nil) }
    if case .ran(let evidence, let export) = result {
      return (observe(package.tests, result), export, evidence)
    }
    return (observe(package.tests, result), nil, nil)
  }

  private static func observe(_ tests: [ChangedTest], _ result: HostTestPackageResult)
    -> SelectedTestRun
  {
    switch result {
    case .ran(let evidence, _): SelectedTestRun.observe(tests, in: evidence)
    case .failed(_, let error): .noEvidence("swift test could not run: \(error)")
    }
  }

  private static func duration(_ milliseconds: Int) -> String {
    ReportRenderer.duration(milliseconds)
  }
}

/// A judgement plus the one-line summary its command reports as a note.
struct SummarizedJudgement: Sendable {
  let judgement: ChangedTestJudgement
  let summary: String?

  static func note(_ text: String) -> SummarizedJudgement {
    SummarizedJudgement(
      judgement: ChangedTestJudgement(
        findings: [ChangedTestChecks.finding(text, severity: .nit, ruleID: nil)].compactMap { $0 },
        blocked: false),
      summary: nil)
  }

  static func blocked(_ ruleID: String, _ text: String) -> SummarizedJudgement {
    SummarizedJudgement(
      judgement: ChangedTestJudgement(
        findings: [ChangedTestChecks.finding(text, severity: .minor, ruleID: ruleID)]
          .compactMap { $0 },
        blocked: true),
      summary: nil)
  }

  func withSummary(_ text: String?) -> ChangedTestJudgement {
    guard let text, let finding = ChangedTestChecks.finding(text, severity: .nit, ruleID: nil)
    else { return judgement }
    return judgement.merged(with: ChangedTestJudgement(findings: [finding], blocked: false))
  }
}

extension ChangedTestJudgement {
  func withSummary(_ text: String?) -> ChangedTestJudgement {
    SummarizedJudgement(judgement: self, summary: nil).withSummary(text)
  }
}

extension ChangedTestChecks {
  static func finding(_ message: String, severity: Severity, ruleID: String?) -> Finding? {
    try? Finding(
      ruleID: ruleID ?? summaryRuleID, severity: severity, file: ".", line: nil,
      message: message, failureScenario: nil)
  }
}
