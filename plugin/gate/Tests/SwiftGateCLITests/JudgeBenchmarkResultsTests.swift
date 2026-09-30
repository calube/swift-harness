import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// The committed benchmark of Sonnet against Jev: its pages, its datasets, the recordings it left
/// behind, and the cascade bands it set.
@Suite("the committed judge benchmark")
struct JudgeBenchmarkResultsTests {
  static let directory = Fixture.checkoutRoot.deletingLastPathComponent().appending(
    path: "evals/results/2026-09-30-judge-benchmark", directoryHint: .isDirectory)

  static func results() throws -> [(name: String, data: Data)] {
    try #require(FileManager.default.fileExists(atPath: directory.path), "no \(directory.path)")
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasSuffix(".json") }.sorted()
    return try names.map { ($0, try Data(contentsOf: directory.appending(path: $0))) }
  }

  static func summary() throws -> String {
    String(decoding: try Data(contentsOf: directory.appending(path: "summary.md")), as: UTF8.self)
  }

  @Test(
    "bench-render on each committed result reproduces its page in the summary — catches a hand-edited summary"
  )
  func pagesReproduce() throws {
    let results = try Self.results()
    try #require(results.map(\.name).contains("test-quality.json"))
    let summary = try Self.summary()
    for (name, data) in results {
      guard case .success(let page) = JudgeBench.render(data) else {
        Issue.record("\(name) doesn't render: \(JudgeBench.render(data))")
        continue
      }
      #expect(summary.contains(page), "summary.md lacks the page bench-render gives \(name)")
    }
  }

  @Test(
    "each committed result names the hash of the dataset committed beside it — catches a result from an edited or relabelled set"
  )
  func datasetHashes() throws {
    let results = try Self.results()
    try #require(!results.isEmpty)
    for (name, data) in results {
      let report = try JudgeBenchmarkReport.decode(data)
      let committed: JudgeDataset
      switch report.dataset.id {
      case JudgeDatasetLoader.testQualityID:
        committed = try JudgeDatasetLoader.testQuality(harnessRoot: Fixture.checkoutRoot)
      case "comments":
        committed = try JudgeDatasetLoader.directory(
          Fixture.checkoutRoot.appending(
            path: JudgeBench.commentsDirectory, directoryHint: .isDirectory), id: "comments")
      default:
        committed = try JudgeDatasetLoader.file(
          Self.directory.appending(
            path: "datasets/\(report.dataset.id.replacingOccurrences(of: ":", with: "-")).json"))
      }
      #expect(report.dataset.hash == committed.hash, "\(name): dataset \(report.dataset.id)")
    }
  }

  @Test(
    "self-test --judge scores Claude's and Jev's recordings offline at their pins, with nothing stale or gating — catches a recording left behind by a relabel or a pin"
  )
  func bothRecordingsPassOffline() async throws {
    let outcome = await JudgeSelfTest.run(
      harnessRoot: Fixture.checkoutRoot, judge: nil, record: false)
    guard case .checked(let result) = outcome else {
      Issue.record("expected the recorded calibration to run, got \(outcome)")
      return
    }
    let messages = result.findings.map(\.message)
    #expect(messages.contains { $0.contains("[claude/claude-sonnet-5-5]") })
    #expect(messages.contains { $0.contains("[jev/jev-1.13.0]") })
    #expect(!result.findings.contains { $0.severity.failsGate })
    #expect(
      !result.findings.contains { $0.ruleID == JudgeSelfTest.staleRuleID },
      "\(result.findings.filter { $0.ruleID == JudgeSelfTest.staleRuleID }.map(\.message))")
  }

  /// The bands the sweep may pick. Each holds 0.4 to 0.6, where a standalone rerun of the Jev
  /// request moved answers across 0.5 (design §13.6), so no tune split can fit a band that lets a
  /// coin flip block.
  static let candidateBands: [JudgeCascade.Band] = (1...8).flatMap { lower in
    (12...19).map { upper in
      JudgeCascade.Band(lower: Double(lower) / 20, upper: Double(upper) / 20)
    }
  }

  /// The fewest kept answers wrong, then the fewest escalations, then the narrowest band, then
  /// the lowest.
  static func chosen(_ points: [JudgeCascade.BandPoint]) -> JudgeCascade.Band? {
    points.min { a, b in
      let aWrong = a.keptCorrect.n - a.keptCorrect.count
      let bWrong = b.keptCorrect.n - b.keptCorrect.count
      if aWrong != bWrong { return aWrong < bWrong }
      if a.escalated.count != b.escalated.count { return a.escalated.count < b.escalated.count }
      let aWidth = a.band.upper - a.band.lower
      let bWidth = b.band.upper - b.band.lower
      if abs(aWidth - bWidth) > 1e-9 { return aWidth < bWidth }
      return a.band.lower < b.band.lower
    }?.band
  }

  @Test(
    "each blocking question's band constant is the band the tune-split sweep of the committed @2-jev arm picks and the summary states — catches a band set by hand after the sweep"
  )
  func bandsComeFromTheSweep() throws {
    let file = Self.directory.appending(path: "test-quality.json")
    try #require(FileManager.default.fileExists(atPath: file.path), "no \(file.lastPathComponent)")
    let data = try Data(contentsOf: file)
    let report = try JudgeBenchmarkReport.decode(data)
    let native = JudgeQuestionSet.testsJev.versionedID
    let arm = try #require(report.arms.first { $0.questionSet == native })
    let tune = JudgeTuneCases(report.cases.map(\.benchmarkCase))
    let constants = JudgeCascade.bands(for: native)
    let summary = try Self.summary()
    // A result stores each question's scoring shape only, so the blocking bit comes from the set.
    let mayBlock = Set(JudgeQuestionSet.testsJev.questions.filter(\.mayBlock).map(\.id))
    let blocking = report.questions.map(\.question).filter { mayBlock.contains($0.id) }
    try #require(blocking.count == 2)
    #expect(Set(constants.keys) == Set(blocking.map(\.id)))
    for question in blocking {
      let swept = Self.chosen(
        JudgeCascade.sweep(
          question, cases: tune, run: arm.run, threshold: report.threshold,
          bands: Self.candidateBands))
      let constant = constants[question.id]
      #expect(swept == constant, "\(question.id): swept \(String(describing: swept))")
      let stated = constant.map {
        "`\(question.id)`: band " + String(format: "%.2f < p < %.2f", $0.lower, $0.upper)
      }
      #expect(
        stated.map(summary.contains) == true,
        "summary.md doesn't state \(stated ?? "a band for \(question.id)")")
    }
  }
}
