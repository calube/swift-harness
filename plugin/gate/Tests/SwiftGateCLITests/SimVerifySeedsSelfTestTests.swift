import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `swiftgate self-test`'s `sim-verify` seeds: real `sim/` run folders that the accessibility
/// rules must judge RED (seeded controls) and GREEN (the clean sample app).
@Suite("swiftgate self-test — sim verify seeds")
struct SimVerifySeedsSelfTestTests {
  static let seeded = "sim-verify/unlabeled-controls"
  static let valid = "sim-verify/valid"

  private static func tempRoot() -> URL {
    TestTemporaryDirectory.root
      .appending(
        path: "swiftgate-sim-verify-seeds-\(UUID().uuidString)", directoryHint: .isDirectory
      )
      .resolvingSymlinksInPath()
  }

  private static func stage(_ seed: String, in root: URL) throws -> URL {
    let source = Fixture.checkoutRoot.appending(
      path: "gate/Fixtures/seeds/\(seed)", directoryHint: .isDirectory)
    let destination = root.appending(
      path: "gate/Fixtures/seeds/\(seed)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
  }

  private static func seedFailures(_ outcome: StaticCheckOutcome) -> [String] {
    guard case .checked(let result) = outcome else { return ["not checked: \(outcome)"] }
    return result.findings.map { "\($0.file): \($0.message)" }
      .filter { $0.hasPrefix("gate/Fixtures/seeds/") }
  }

  @Test(
    "self-test runs the sim-verify seeds: the seeded run yields both accessibility rules and the clean run none — catches an unregistered family or a rule that misses its seed"
  )
  func seedsMatchTheirAnswerKeys() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Self.stage(Self.seeded, in: root)
    _ = try Self.stage(Self.valid, in: root)

    let outcome = await SelfTest.run(harnessRoot: root)
    #expect(Self.seedFailures(outcome) == [])
  }

  @Test(
    "a seeded run whose answer key says GREEN turns self-test RED, naming the 2 rules it fired — catches a sim-verify runner that can't fail"
  )
  func seededRunAgainstAGreenKeyIsRed() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let caseRoot = try Self.stage(Self.seeded, in: root)
    try Data(#"{"schemaVersion": 1, "verdict": "green", "ruleIDs": []}"#.utf8)
      .write(to: caseRoot.appending(path: "expected.json"))

    let outcome = await SelfTest.run(harnessRoot: root)
    #expect(
      Self.seedFailures(outcome) == [
        "gate/Fixtures/seeds/\(Self.seeded): expected rule id(s) [], got "
          + "[sim.a11y-identifier, sim.a11y-label]"
      ])
  }

  @Test(
    "a case whose sim folder has no session.json is blocked, naming why — catches an unreadable run judged GREEN"
  )
  func unreadableRunIsBlocked() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let caseRoot = try Self.stage(Self.valid, in: root)
    try FileManager.default.removeItem(at: caseRoot.appending(path: "sim/session.json"))

    let outcome = await SelfTest.run(harnessRoot: root)
    let failures = Self.seedFailures(outcome)
    #expect(failures.count == 1)
    #expect(failures.first?.hasPrefix("gate/Fixtures/seeds/\(Self.valid): blocked: ") == true)
    #expect(failures.first?.contains("session.json") == true)
  }
}
