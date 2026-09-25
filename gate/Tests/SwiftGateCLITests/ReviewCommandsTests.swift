import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

struct FakeDiff: DiffReading {
  let text: String
  func unifiedDiff(since ref: String) async throws(GitError) -> String { text }
}

@Suite("swiftgate review-input")
struct ReviewInputTests {
  static func parts(_ verdict: Verdict, findings: [Finding] = []) throws -> GateRunParts {
    GateRunParts(
      tiers: [
        try TierResult(tier: .t0, verdict: verdict, durationMilliseconds: 1, testCounts: nil)
      ],
      findings: findings)
  }

  static func dependencies(check: GateRunParts, git: FakeGit) -> ReviewInputRun.Dependencies {
    ReviewInputRun.Dependencies(
      git: git, diff: FakeDiff(text: "diff --git a/X b/X\n"), check: { _ in check },
      comments: { _ in .checked(RuleRunResult(findings: [], allowances: [])) })
  }

  @Test(
    "a RED push gate stops the review before any reviewer input is written — catches reviewers spending tokens on code that fails its own gate"
  )
  func redGateStops() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let failing = try Finding(
      ruleID: "test.tautology", severity: .major, file: "T.swift", line: 1, message: "tautology",
      failureScenario: nil)
    let dependencies = Self.dependencies(
      check: try Self.parts(.red, findings: [failing]), git: FakeGit(changed: [], mergeBase: "base")
    )

    let outcome = try await ReviewInputRun.gather(
      root: repository.root, base: "origin/main", context: repository.context(),
      dependencies: dependencies)

    guard case .stopped(let report, let directory) = outcome else {
      Issue.record("expected the gather step to stop, got \(outcome)")
      return
    }
    #expect(report.verdict == .red)
    let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(written == ["check.json"])
  }

  @Test(
    "a BLOCKED push gate also stops — catches a review of code whose gate never ran")
  func blockedGateStops() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let dependencies = Self.dependencies(
      check: try Self.parts(.blocked), git: FakeGit(changed: [], mergeBase: "base"))
    let outcome = try await ReviewInputRun.gather(
      root: repository.root, base: "origin/main", context: repository.context(),
      dependencies: dependencies)
    guard case .stopped(let report, _) = outcome else {
      Issue.record("expected stop, got \(outcome)")
      return
    }
    #expect(report.verdict == .blocked)
  }

  @Test(
    "a GREEN gate writes the bundle with arch and testlint split out and SwiftUI detected by module — catches reviewers missing inputs or the SwiftUI focus"
  )
  func greenWritesBundle() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    try repository.write("Pkg/Sources/CounterUI/Row.swift", "import SwiftUI\nstruct Row {}\n")
    try repository.write("Pkg/Sources/CounterUI/Model.swift", "struct Model {}\n")
    try repository.write("Pkg/Sources/CounterCore/Core.swift", "import Foundation\n")
    let advisory = try Finding(
      ruleID: "arch.undeclared-kind", severity: .minor, file: "Pkg", line: nil, message: "m",
      failureScenario: nil)
    let dependencies = Self.dependencies(
      check: try Self.parts(.green, findings: [advisory]),
      git: FakeGit(
        changed: ["Pkg/Sources/CounterUI/Model.swift", "Pkg/Sources/CounterCore/Core.swift"],
        mergeBase: "base"))

    let outcome = try await ReviewInputRun.gather(
      root: repository.root, base: "origin/main", context: repository.context(),
      dependencies: dependencies)

    guard case .ready(let manifest, let directory) = outcome else {
      Issue.record("expected a bundle, got \(outcome)")
      return
    }
    #expect(manifest.mergeBase == "base")
    #expect(manifest.swiftUIUnits == ["Pkg/Sources/CounterUI/"])
    #expect(manifest.focuses.contains(.swiftui))
    let files = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    #expect(
      files == [
        "check.json", "arch.json", "testlint.json", "comments.json", "diff.patch", "manifest.json",
      ])
    let arch = try JSONDecoder().decode(
      [Finding].self, from: Data(contentsOf: directory.appending(path: "arch.json")))
    #expect(arch.map(\.ruleID) == ["arch.undeclared-kind"])
    #expect(
      try String(contentsOf: directory.appending(path: "diff.patch"), encoding: .utf8)
        .hasPrefix("diff --git"))
  }

  @Test("no merge base is BLOCKED before the gate runs — catches a review of an unknown diff")
  func noMergeBase() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let dependencies = Self.dependencies(
      check: try Self.parts(.green), git: FakeGit(changed: [], mergeBase: nil))
    let outcome = try await ReviewInputRun.gather(
      root: repository.root, base: "origin/main", context: repository.context(),
      dependencies: dependencies)
    guard case .blocked = outcome else {
      Issue.record("expected BLOCKED, got \(outcome)")
      return
    }
  }
}

@Suite("swiftgate review-synth")
struct ReviewSynthCommandTests {
  @Test(
    "synth reads focus files, writes review.json, and a bad file is a contract failure — catches a malformed verifier output silently counting as clean"
  )
  func synthFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-synth-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var files: [URL] = []
    for focus in ReviewFocus.allCases {
      let findings =
        focus == .architecture
        ? [
          ReviewFinding(
            severity: .blocker, category: "layering", file: "Pkg/Sources/Core/A.swift", line: 3,
            title: "Core imports UIKit",
            failureScenario: "building Core for macOS host tests fails, so T1 can't run",
            evidence: "Pkg/Sources/Core/A.swift:3 import UIKit", fix: "move to the UI module",
            verified: true)
        ] : []
      let url = directory.appending(path: "\(focus.rawValue).json")
      try FocusReviewJSON.encode(
        FocusReview(focus: focus, status: .reviewed, reason: nil, findings: findings)
      ).write(to: url)
      files.append(url)
    }

    let report = try ReviewSynthRun.run(files: files, runDirectory: directory)

    #expect(report.verdict == .refactorNeeded)
    let written = try JSONDecoder().decode(
      ReviewReport.self, from: Data(contentsOf: directory.appending(path: "review.json")))
    #expect(written == report)

    let broken = directory.appending(path: "broken.json")
    try Data("{\"focus\":".utf8).write(to: broken)
    #expect(throws: ReviewSynthRun.InputFailure.self) {
      try ReviewSynthRun.run(files: files + [broken], runDirectory: directory)
    }
  }
}
