import Foundation
import SwiftGateDomain
import Testing

@testable import SwiftGateAdapters

@Suite("build calibration return check")
struct BuildCalibrationReturnTests {
  @Test(
    "a sandbox return citing a gate run without the task gate's steps names each missing step only when they're required — catches calibration judging a worker by a looser rule than check-return"
  )
  func returnFindingsRequireTaskGateStepsWhenAsked() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "calibration-return-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sandbox = Sandbox(
      directory: directory, seed: directory.appending(path: "seed"), tools: LiveProcessRunner())
    try FileManager.default.createDirectory(at: sandbox.repo, withIntermediateDirectories: true)
    let runID = "20260927T100000Z-0a1b2c3d"
    let report = try RunReport(
      runID: runID, durationMilliseconds: 10,
      tiers: [try TierResult(tier: .t0, verdict: .green, durationMilliseconds: 5, testCounts: nil)],
      findings: [])
    try RunStore(worktreeRoot: sandbox.repo).record(
      report, finishedAt: Date(timeIntervalSince1970: 1_790_000_000), command: "check fast",
      steps: ["prove", "mutate"])
    let taskReturn = TaskReturn(
      task: "greeting", outcome: .readyToMerge, commits: [],
      gate: .init(tier: .fast, verdict: .green, runID: runID), review: nil, testsAdded: [],
      notes: "", designConflict: nil)
    func findings(required: Bool) async throws -> String {
      try await sandbox.returnFindings(
        taskReturn, taskID: "greeting", branch: "calibration/greeting", tip: nil, gate: .fast,
        proofRequired: true, taskGateStepsRequired: required)
    }

    let required = try await findings(required: true)
    let exempt = try await findings(required: false)

    #expect(required.components(separatedBy: "build-return.gate-missing-step").count - 1 == 3)
    for step in ["impact", "coverage", "app-build"] {
      #expect(required.contains("`\(step)`"), "\(step) isn't named")
    }
    #expect(!exempt.contains("build-return.gate-missing-step"))
  }
}
