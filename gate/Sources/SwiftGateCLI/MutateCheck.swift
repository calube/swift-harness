import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// `mutate` (spec §7.4): mutants on the Core, client and Live lines a change adds, each run
/// against the T1 test targets depending on its module, in parallel scratch worktrees.
enum MutateCheck {
  struct Environment: Sendable {
    let root: URL
    let git: any Git
    let scratch: any ScratchWorktrees
    let toolchain: any MutationToolchain
    /// `--jobs`: overrides `[mutation] max_workers` and the default cap.
    let workers: Int?
    var cores = ProcessInfo.processInfo.activeProcessorCount
    let timeout: MutantTimeout

    static func live(root: URL, git: any Git, workers: Int? = nil) -> Environment {
      Environment(
        root: root, git: git,
        scratch: LiveScratchWorktrees(runner: LiveProcessRunner(), repositoryRoot: root.path),
        toolchain: LiveMutationToolchain(runner: LiveProcessRunner()),
        workers: workers, timeout: MutantTimeout())
    }
  }

  /// Roles whose added lines are mutated: the host-testable production code T1 must pin.
  static func isMutated(_ module: Module) -> Bool {
    guard module.isHostTestable else { return false }
    switch module.role {
    case .core, .client, .clientLive: return true
    case .ui, .app, .testSupport, .tests: return false
    }
  }

  static func run(
    _ environment: Environment, graph: ModuleGraph, config: Config, base: String,
    context: GateRun.Context
  ) async -> ChangedTestJudgement {
    let clock = ContinuousClock()
    let start = clock.now
    let mergeBase: String
    let prefix: String
    let added: [AddedLines]
    let changed: [String]
    do throws(GitError) {
      guard let found = try await environment.git.mergeBase("HEAD", base) else {
        return SummarizedJudgement.blocked(
          MutationRules.noEvidenceRuleID, "HEAD and \(base) share no history; pass --base <ref>"
        ).judgement
      }
      mergeBase = found
      prefix = try await environment.git.workingDirectoryPrefix()
      added = try await environment.git.addedLines(since: mergeBase)
        .filter { $0.path.hasPrefix(prefix) }
        .map { AddedLines(path: String($0.path.dropFirst(prefix.count)), ranges: $0.ranges) }
      changed = try await environment.git.changedFiles(since: mergeBase)
    } catch {
      return SummarizedJudgement.blocked(MutationRules.noEvidenceRuleID, "git: \(error)")
        .judgement
    }

    var candidates = MutationCandidates()
    var texts: [String: String] = [:]
    var diff = ""
    for change in added.sorted(by: { $0.path < $1.path }) where change.path.hasSuffix(".swift") {
      guard !config.exclude.contains(where: { change.path.hasPrefix($0 + "/") }),
        let module = graph.module(containingFile: change.path), isMutated(module)
      else { continue }
      guard
        let text = try? String(
          contentsOf: environment.root.appending(path: change.path), encoding: .utf8)
      else {
        return SummarizedJudgement.blocked(
          MutationRules.noEvidenceRuleID, "could not read \(change.path)"
        ).judgement
      }
      texts[change.path] = text
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      diff += change.path + "\n"
      for range in change.ranges {
        for line in range where line <= lines.count { diff += lines[line - 1] + "\n" }
      }
      let unit = SourceUnit(input: SourceInput(path: change.path, text: text), scope: module.scope)
      let found = MutantGenerator.candidates(in: unit, text: text, added: change)
      candidates.mutants += found.mutants
      candidates.equivalent += found.equivalent
      candidates.bareMarkers += found.bareMarkers
    }
    guard !candidates.mutants.isEmpty || !candidates.bareMarkers.isEmpty else {
      let setAside =
        candidates.equivalent.isEmpty
        ? "" : " (\(candidates.equivalent.count) annotated equivalent)"
      return SummarizedJudgement.note(
        "mutate: no mutants on changed Core, client or Live lines since \(base)\(setAside)"
      ).judgement
    }

    let sampled = MutantSampling.sample(
      candidates.mutants, limit: config.mutation.maxMutants,
      seed: MutantSampling.seed(diff: diff))
    var selections: [String: [HostTestSelection]] = [:]
    let jobs = sampled.compactMap { mutant -> MutantJob? in
      guard let text = texts[mutant.file], let mutated = mutant.apply(to: text) else { return nil }
      if selections[mutant.file] == nil {
        selections[mutant.file] = TierPlan(changedPaths: [mutant.file], graph: graph, tier: .t1)
          .packages.map { package in
            HostTestSelection(
              packagePath: package.packagePath,
              targets: package.testTargets.map { name in
                TestTargetReference(
                  name: name, path: graph.module(named: name)?.path ?? package.packagePath)
              })
          }
      }
      return MutantJob(
        mutant: mutant, originalText: text, mutatedText: mutated,
        selections: selections[mutant.file] ?? [])
    }
    let run = await MutationRunner(
      scratch: environment.scratch, toolchain: environment.toolchain,
      workers: MutationWorkers.count(
        configured: environment.workers ?? config.mutation.maxWorkers, cores: environment.cores,
        mutants: jobs.count { !$0.selections.isEmpty }), timeout: environment.timeout
    ).run(
      jobs,
      tree: ScratchTreeRequest(
        revision: "HEAD", revertTo: "HEAD", copiedPaths: changed, revertedPaths: [],
        seededBuildDirectories: Set(jobs.flatMap { $0.selections.map(\.packagePath) }).sorted()
          .map { prefix + $0 }),
      projectPrefix: prefix, reportDirectory: context.directory.appending(path: "mutate"))
    return MutationRules.judge(
      MutationRunSummary(
        results: run.results, equivalent: candidates.equivalent,
        bareMarkers: candidates.bareMarkers,
        candidateCount: candidates.mutants.count + candidates.equivalent.count,
        workers: run.workers, durationMilliseconds: GateRun.milliseconds(clock.now - start)))
  }
}
