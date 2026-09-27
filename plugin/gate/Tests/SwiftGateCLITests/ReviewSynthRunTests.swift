import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate review-synth: numbered-diff baseline and run telemetry")
struct ReviewSynthRunTests {
  static let runID = "20260927T113017Z-15a65d14"
  static let counter = "Packages/CounterFeature/Sources/CounterCore/CounterFeature.swift"

  /// A temp `.harness/runs/<runID>` holding one focus file per focus, the baseline effect finding
  /// in the concurrency file, and a review-input bundle when `bundle` is set.
  static func runDirectory(bundle: Bool) throws -> (root: URL, run: URL, files: [URL]) {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-synth-run-\(UUID().uuidString)", directoryHint: .isDirectory)
    let run = root.appending(path: runID, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    var files: [URL] = []
    for focus in ReviewFocus.allCases {
      let findings =
        focus == .concurrency
        ? [
          ReviewFinding(
            severity: .major, category: "effect-lifetime", file: counter, line: 49,
            title: "fact effect has no cancellation id",
            failureScenario: "tap Fact then Reset: the late response shows a fact after reset",
            evidence: "CounterFeature.swift:49 `.run` with no `.cancellable(id:)`",
            fix: "add a cancel id", verified: true)
        ] : []
      let url = run.appending(path: "\(focus.rawValue).json")
      try FocusReviewJSON.encode(
        FocusReview(focus: focus, status: .reviewed, reason: nil, findings: findings)
      ).write(to: url)
      files.append(url)
    }
    if bundle {
      let directory = run.appending(path: "review-input", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let manifest = ReviewInputManifest(
        runID: runID, base: "main", mergeBase: "abc", gateVerdict: .green,
        changedFiles: [counter], swiftUIUnits: [],
        artifacts: .init(
          check: "check.json", arch: "arch.json", testlint: "testlint.json",
          comments: "comments.json", diff: "diff.patch", numberedDiff: "diff-numbered.txt",
          mutate: "mutate.json"),
        notes: [])
      try JSONEncoder().encode(manifest).write(to: directory.appending(path: "manifest.json"))
      try Data(NumberedDiff.render(Fixture.text("Review/clean-reset.patch")).utf8).write(
        to: directory.appending(path: "diff-numbered.txt"))
    }
    return (root, run, files)
  }

  static func startedAt() throws -> Date {
    try #require(ISO8601DateFormatter().date(from: "2026-09-27T11:30:17Z"))
  }

  @Test(
    "synth reads the bundle's numbered diff and files a baseline defect as pre-existing — catches review-synth ignoring the diff and blocking a clean change"
  )
  func bundleBaselineApplies() throws {
    let (root, run, files) = try Self.runDirectory(bundle: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try ReviewSynthRun.run(files: files, runDirectory: run)
    #expect(report.verdict == .merge)
    #expect(report.preExisting.count == 1)
    #expect(report.baselineUnavailable == nil)
  }

  @Test(
    "a run with no review-input bundle counts every finding and names the missing manifest — catches a lost bundle silently filing blockers as pre-existing"
  )
  func missingBundleCountsEverything() throws {
    let (root, run, files) = try Self.runDirectory(bundle: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try ReviewSynthRun.run(files: files, runDirectory: run)
    #expect(report.verdict == .fixThenMerge)
    #expect(report.baselineUnavailable?.contains("review-input/manifest.json") == true)
  }

  @Test(
    "synth writes review-telemetry.json with the run's wall time and the workflow's reported tokens, and the summary names it — catches a review whose cost nobody can find"
  )
  func telemetryRecorded() throws {
    let (root, run, files) = try Self.runDirectory(bundle: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workflow = run.appending(path: "review-workflow.json")
    try Data(
      #"""
      {"bundle":"b","reviews":[],"telemetry":{"outputTokens":51234,
       "agents":[{"label":"review:concurrency","returned":true},{"label":"verify:concurrency","returned":false}],
       "unavailable":["per-agent tokens: the workflow script sees no usage per agent call"]}}
      """#.utf8
    ).write(to: workflow)

    let report = try ReviewSynthRun.run(
      files: files, runDirectory: run, workflowResult: workflow,
      now: Self.startedAt().addingTimeInterval(412))

    let path = run.appending(path: "review-telemetry.json")
    #expect(report.telemetry == path.path)
    let telemetry = try JSONDecoder().decode(ReviewTelemetry.self, from: Data(contentsOf: path))
    #expect(telemetry.runID == Self.runID)
    #expect(telemetry.wallSeconds == 412)
    #expect(telemetry.outputTokens == 51234)
    #expect(telemetry.agents?.map(\.label) == ["review:concurrency", "verify:concurrency"])
    #expect(telemetry.agents?.map(\.returned) == [true, false])
    #expect(
      telemetry.unavailable == [
        "per-agent tokens: the workflow script sees no usage per agent call"
      ])
    let summary = ReviewSummary.render(report, reportPath: "review.json")
    #expect(summary.contains("telemetry: \(path.path)"))
  }

  @Test(
    "without a workflow result the telemetry file says the tokens are unavailable instead of inventing them — catches a zero token count standing in for unknown"
  )
  func telemetryWithoutWorkflowResult() throws {
    let (root, run, files) = try Self.runDirectory(bundle: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try ReviewSynthRun.run(
      files: files, runDirectory: run, now: Self.startedAt().addingTimeInterval(30))
    let telemetry = try JSONDecoder().decode(
      ReviewTelemetry.self,
      from: Data(contentsOf: run.appending(path: "review-telemetry.json")))
    #expect(telemetry.wallSeconds == 30)
    #expect(telemetry.outputTokens == nil)
    #expect(telemetry.agents == nil)
    #expect(telemetry.unavailable.contains { $0.contains("--workflow-result") })
  }
}
