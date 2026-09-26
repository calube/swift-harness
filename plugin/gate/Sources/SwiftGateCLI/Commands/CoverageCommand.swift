import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Diff coverage of changed Core, client and Live lines by T1 tests alone, plus per-module T1
/// presence (spec §7.3).
enum CoverageCheck {
  static let summaryRuleID = "coverage.summary"

  struct Judgement: Sendable {
    let verdict: Verdict
    let findings: [Finding]
  }

  /// Lines added since the merge base of HEAD and `base`, relative to this project's root.
  static func addedLines(git: any Git, base: String) async -> Result<[AddedLines], BlockedReason> {
    do throws(GitError) {
      guard let mergeBase = try await git.mergeBase("HEAD", base) else {
        return .failure(BlockedReason("HEAD and \(base) share no history; pass --base <ref>"))
      }
      let prefix = try await git.workingDirectoryPrefix()
      return .success(
        try await git.addedLines(since: mergeBase)
          .filter { $0.path.hasPrefix(prefix) }
          .map { AddedLines(path: String($0.path.dropFirst(prefix.count)), ranges: $0.ranges) })
    } catch {
      return .failure(BlockedReason("git: \(error)"))
    }
  }

  /// Diff coverage from the llvm-cov exports of a T1 run, plus per-module T1 presence.
  static func judge(
    graph: ModuleGraph, config: Config, added: [AddedLines], exports: [Data], root: URL
  ) throws(ReportContractViolation) -> Judgement {
    let rootPath = CanonicalPath.of(root)
    var coverage = LineCoverage(files: [:])
    var unreadable: [String] = []
    for export in exports {
      do throws(CoverageParseError) {
        coverage = coverage.merged(
          with: try LineCoverage(llvmExport: export, repositoryRoot: rootPath))
      } catch {
        unreadable.append(error.detail)
      }
    }
    let minimum = config.pyramid.diffCoverageMin
    let diff = try DiffCoverage.evaluate(
      addedLines: added, scopes: graph, coverage: coverage, minimum: minimum)
    var findings = diff.findings + (try T1Presence.evaluate(graph))
    if diff.measured > 0 {
      let percent = Int((Double(diff.covered) / Double(diff.measured) * 100).rounded(.down))
      findings.append(
        try Finding(
          ruleID: summaryRuleID, severity: .nit, file: ".", line: nil,
          message:
            "T1 covers \(diff.covered) of \(diff.measured) changed Core/client/Live lines "
            + "(\(percent)%; minimum \(Int((minimum * 100).rounded()))%)",
          failureScenario: nil))
    }
    for detail in unreadable {
      findings.append(
        try Finding(
          ruleID: DiffCoverage.noDataRuleID, severity: .minor, file: ".", line: nil,
          message: "llvm-cov export unreadable: \(detail)", failureScenario: nil))
    }
    let gating = findings.contains { $0.severity.failsGate }
    return Judgement(
      verdict: gating ? .red : unreadable.isEmpty ? .green : .blocked, findings: findings)
  }

  static func run(
    root: URL, swiftPM: any SwiftPM, git: any Git, base: String, context: GateRun.Context
  ) async throws -> GateRunParts {
    let repository: ConfiguredRepository.Loaded
    switch await ConfiguredRepository.load(root: root, swiftPM: swiftPM, command: "coverage") {
    case .failed(let outcome): return try TestCheck.parts(t1Failure: outcome)
    case .loaded(let loaded): repository = loaded
    }
    let added: [AddedLines]
    switch await addedLines(git: git, base: base) {
    case .failure(let reason): return try TestCheck.parts(t1Failure: .blocked(reason: reason.text))
    case .success(let lines): added = lines
    }
    let plan = TierPlan(changedPaths: added.map(\.path), graph: repository.graph, tier: .t1)
    let t1 = try await HostTestCheck.run(
      HostTestCheck.selections(plan: plan, graph: repository.graph), root: root,
      swiftPM: swiftPM, outputDirectory: context.directory, readCoverage: true)
    let judgement = try judge(
      graph: repository.graph, config: repository.config, added: added,
      exports: t1.coverageExports, root: root)
    return GateRunParts(
      tiers: [try t1.tier.merging(judgement.verdict)], findings: t1.findings + judgement.findings)
  }
}

struct BlockedReason: Error, Sendable {
  let text: String

  init(_ text: String) { self.text = text }
}

extension TierResult {
  /// This tier with another check's verdict folded in (for example coverage judged from T1).
  func merging(_ other: Verdict) throws(ReportContractViolation) -> TierResult {
    try TierResult(
      tier: tier, verdict: verdict.merged(with: other),
      durationMilliseconds: durationMilliseconds, testCounts: testCounts)
  }
}

struct CoverageCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "coverage",
    abstract: "Require T1 tests alone to cover changed Core, client and Live lines.")

  @Option(help: "Measure lines changed since the merge base of HEAD and this ref.")
  var base = "origin/main"

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let swiftPM = ScopeResolution.liveSwiftPM(root: root)
    try await GateRun.execute(root: root, format: output.format, command: "coverage") { context in
      try await CoverageCheck.run(
        root: root, swiftPM: swiftPM, git: git, base: base, context: context)
    }
  }
}
