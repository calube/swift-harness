import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `swiftgate self-test`'s build executor seeds: `build next`, `ledger set`, `build check-return`,
/// `build merge` and preset parsing each have a committed case that must yield exactly its
/// violation, and a check swapped for one that lets everything through must turn self-test RED.
@Suite("swiftgate self-test — build executor seeds")
struct BuildSeedsSelfTestTests {
  /// Each violation seed and the one identifier it must yield.
  static let violations: [(seed: String, ruleID: String)] = [
    ("build-next/unmerged-dependency", "build-next.unmerged-dependency"),
    ("build-next/overlapping-write-sets", "build-next.write-set-overlap"),
    ("ledger-set/done-to-pending", "ledger-set.refused-transition"),
    ("build-check-return/commit-off-branch", "build-return.commit-off-branch"),
    ("build-check-return/gate-run-missing", "build-return.gate-run-missing"),
    ("build-merge/main-moved", "build-merge.main-moved"),
    ("build-presets/missing-key", "config.missing-key(build.presets.broken.merge_gate)"),
  ]

  static let valid = [
    "build-next/valid", "ledger-set/valid", "build-check-return/valid", "build-merge/valid",
    "build-presets/valid",
  ]

  private static func tempRoot() -> URL {
    TestTemporaryDirectory.root
      .appending(path: "swiftgate-build-seeds-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
  }

  private static func stage(_ seed: String, in root: URL) throws {
    let source = Fixture.checkoutRoot.appending(
      path: "gate/Fixtures/seeds/\(seed)", directoryHint: .isDirectory)
    let destination = root.appending(
      path: "gate/Fixtures/seeds/\(seed)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: destination)
  }

  private static func seedFailures(_ outcome: StaticCheckOutcome) -> [String] {
    guard case .checked(let result) = outcome else { return ["not checked: \(outcome)"] }
    return result.findings.map { "\($0.file): \($0.message)" }
      .filter { $0.hasPrefix("gate/Fixtures/seeds/") }
  }

  private static func expectedRuleIDs(_ seed: String) throws -> [String] {
    let data = try Data(
      contentsOf: Fixture.checkoutRoot.appending(
        path: "gate/Fixtures/seeds/\(seed)/expected.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(object["ruleIDs"] as? [String])
  }

  @Test(
    "each build seed's answer key names exactly its one violation, and self-test agrees — catches a seed that fires a different rule, or several",
    arguments: violations.map(\.seed).indices
  )
  func violationSeedYieldsExactlyItsRule(_ index: Int) async throws {
    let (seed, ruleID) = Self.violations[index]
    #expect(try Self.expectedRuleIDs(seed) == [ruleID])
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.stage(seed, in: root)

    let outcome = await SelfTest.run(harnessRoot: root)
    #expect(Self.seedFailures(outcome) == [])
  }

  @Test(
    "each build family's clean case yields nothing — catches a seed setup that fires on its own, so the violation seed would pass for the wrong reason",
    arguments: valid
  )
  func validSeedYieldsNothing(_ seed: String) async throws {
    #expect(try Self.expectedRuleIDs(seed) == [])
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.stage(seed, in: root)

    let outcome = await SelfTest.run(harnessRoot: root)
    #expect(Self.seedFailures(outcome) == [])
  }

  /// A check that lets everything through, for the family `seed` belongs to.
  private static func disabled(_ seed: String) -> BuildSeedChecks {
    var checks = BuildSeedChecks.live
    switch seed.split(separator: "/").first.map(String.init) {
    case "build-next":
      checks.schedule = { ledger, running, _, _, _ in
        BuildScheduler.Result(
          toStart: ledger.tasks.filter { $0.status == .pending }.map(\.id),
          running: running.sorted(), phase: .normal, refused: [])
      }
    case "ledger-set":
      checks.setStatus = { _, _, _ in nil }
    case "build-check-return":
      checks.checkReturn = { _, plan, _ in
        BuildCheckReturnReport(
          command: BuildCheckReturnRun.command, plan: plan, task: nil, verdict: .green,
          findings: [], warnings: [], message: "no-op")
      }
    case "build-merge":
      checks.merge = { _ in
        BuildMergeReport(
          command: BuildMerge.mergeCommand, plan: "p", task: "t", status: .merged,
          verdict: .green, message: "no-op")
      }
    case "build-presets":
      checks.loadConfig = { _ in nil }
    default:
      Issue.record("no no-op check for \(seed)")
    }
    return checks
  }

  @Test(
    "swapping a build seed's check for a no-op turns self-test RED, naming the violation that stopped firing — catches a check that can't fail",
    arguments: violations.map(\.seed).indices
  )
  func disabledCheckTurnsSelfTestRed(_ index: Int) async throws {
    let (seed, ruleID) = Self.violations[index]
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.stage(seed, in: root)

    let outcome = await SelfTest.run(harnessRoot: root, buildChecks: Self.disabled(seed))
    #expect(
      Self.seedFailures(outcome) == [
        "gate/Fixtures/seeds/\(seed): expected rule id(s) [\(ruleID)], got []"
      ])
  }
}
