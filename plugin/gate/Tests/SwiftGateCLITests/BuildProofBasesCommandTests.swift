import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway git common dir holding one plan with a build run whose merged tasks each have a
/// stored return.
private struct ProofBasesScenario {
  static let plan = "2026-09-28-notes"
  static let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
  static let preset = BuildPreset(
    designTier: .none, maxParallel: 3, review: .gate, taskGate: .tier(.push),
    mergeGate: .ready, workerModel: .opus, timeBudgetMin: 90, stopStartsBeforeMin: 15,
    onDesignConflict: .block)

  let shared = SharedPlanState()
  var git: FakeGit { shared.git() }

  func layout() throws -> PlanStateLayout.Plan {
    try PlanStateLayout(commonDirectory: shared.commonDirectory.path).plan(Self.plan)
  }

  func write(_ path: String, _ data: Data) throws {
    try FileManager.default.createDirectory(
      at: URL(filePath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: URL(filePath: path))
  }

  /// A spec-page plan's `plan.json`, as `plan claim --spec-page` seeds it, with `surface`
  /// recorded as its surface commit.
  func writePlan(surface: String?) throws {
    let seed = PlanFile.seedSpecPage(slug: Self.plan)
    let file = PlanFile(
      schemaVersion: seed.schemaVersion, slug: seed.slug, source: seed.source,
      surfaceCommit: surface, resume: seed.resume)
    try write(try layout().planFile, try PlanFileJSON.encode(file))
  }

  /// Starts a run that merges `returns`' tasks in order, each with a stored return naming its
  /// surface commit, or none.
  func mergedRun(_ returns: [(task: String, surface: String?)]) async throws {
    let store = try await BuildRunStore.create(
      plan: Self.plan, presetName: "fast", preset: Self.preset, startedAt: Self.startedAt,
      git: git, suffix: 0xabc)
    for (index, entry) in returns.enumerated() {
      try await store.append(
        .merge(
          .init(
            task: entry.task, preCommit: "pre-\(index)", postCommit: "post-\(index)",
            at: Self.startedAt)))
      let taskReturn = TaskReturn(
        task: entry.task, outcome: .readyToMerge, commits: ["1"], gate: nil, review: nil,
        testsAdded: [], notes: "", designConflict: nil, surfaceCommit: entry.surface)
      try write(
        store.layout.directory + "/returns/\(entry.task).json",
        try TaskReturnJSON.encode(taskReturn))
    }
  }

  func run() async -> BuildLoopResult<BuildProofBasesReport> {
    await BuildProofBasesRun.run(slug: Self.plan, git: git)
  }
}

@Suite("build proof-bases")
struct BuildProofBasesCommandTests {
  @Test(
    "the plan's surface comes first, then each later stub, each sha once — catches a final gate missing the plan surface or proving at it twice"
  )
  func planSurfaceFirst() async throws {
    let scenario = ProofBasesScenario()
    defer { scenario.shared.remove() }
    try scenario.writePlan(surface: "surf")
    try await scenario.mergedRun([("a", "surf"), ("b", "stub"), ("c", "surf")])

    let result = await scenario.run()

    #expect(result.verdict == .green, "\(result.message)")
    #expect(result.report?.proofBases == ["surf", "stub"])
    #expect(result.report?.arguments == "--proof-base surf --proof-base stub")
    #expect(
      BuildProofBasesRun.render(result, format: .human) == "--proof-base surf --proof-base stub")
  }

  @Test(
    "a plan surface no task names still leads, and the same plan without one prints only the tasks' surfaces — catches the plan surface read from returns alone, or invented when plan.json has none"
  )
  func planSurfaceOrNone() async throws {
    let returns: [(task: String, surface: String?)] = [("a", "aaa"), ("b", nil), ("c", "ccc")]
    let expected: [(String?, [String])] = [
      ("surf", ["surf", "aaa", "ccc"]),
      (nil, ["aaa", "ccc"]),
    ]
    for (surface, bases) in expected {
      let scenario = ProofBasesScenario()
      defer { scenario.shared.remove() }
      try scenario.writePlan(surface: surface)
      try await scenario.mergedRun(returns)

      let result = await scenario.run()

      #expect(result.verdict == .green, "\(result.message)")
      #expect(result.report?.proofBases == bases, "plan surface \(surface ?? "none")")
      #expect(
        BuildProofBasesRun.render(result, format: .human)
          == bases.map { "--proof-base \($0)" }.joined(separator: " "))
    }
  }

  @Test(
    "a plan.json that can't be read or decoded exits 2 naming it — catches a final gate run with an empty or partial list of proof bases"
  )
  func unreadablePlanFileBlocks() async throws {
    for damage in ["not json", "directory"] {
      let scenario = ProofBasesScenario()
      defer { scenario.shared.remove() }
      try await scenario.mergedRun([("a", "aaa")])
      let path = try scenario.layout().planFile
      if damage == "directory" {
        try FileManager.default.createDirectory(
          at: URL(filePath: path + "/inner"), withIntermediateDirectories: true)
      } else {
        try scenario.write(path, Data(damage.utf8))
      }

      let result = await scenario.run()

      #expect(result.verdict == .blocked, "\(damage)")
      #expect(result.verdict.exitCode == 2)
      #expect(result.report == nil, "\(damage)")
      #expect(result.message.contains("plan.json"), "\(damage): \(result.message)")
    }
  }

  @Test(
    "a missing plan.json keeps the tasks' surfaces and says the plan surface is unknown — catches a lost plan.json passing as a plan with no surface"
  )
  func missingPlanFileIsNamed() async throws {
    let scenario = ProofBasesScenario()
    defer { scenario.shared.remove() }
    try await scenario.mergedRun([("a", "aaa"), ("b", "bbb")])

    let result = await scenario.run()

    #expect(result.verdict == .green, "\(result.message)")
    #expect(result.report?.proofBases == ["aaa", "bbb"])
    #expect(
      result.message.contains(try scenario.layout().planFile + " is missing"), "\(result.message)")
  }
}
