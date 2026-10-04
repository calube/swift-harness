import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `plan-lint` on a design plan whose `validation.json` sits beside its ledger, through the
/// committed `plan-lint` seeds that carry one.
@Suite("plan-lint validation seeds")
struct PlanLintValidationSeedTests {
  static let cases = [
    "validation-valid", "validation-uncovered", "validation-unknown-task",
    "validation-state-without-flow",
  ]

  /// A harness root holding only the named `plan-lint` seed cases and the standards doc worker
  /// packs read, copied from this checkout.
  private static func stagedRoot(_ names: [String]) throws -> URL {
    let root = try TestTemporaryDirectory.make("swiftgate-validation-seeds")
      .resolvingSymlinksInPath()
    let seeds = "gate/Fixtures/seeds/plan-lint"
    try FileManager.default.createDirectory(
      at: root.appending(path: seeds, directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appending(path: "docs", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: Fixture.checkoutRoot.appending(path: "docs/standards.md"),
      to: root.appending(path: "docs/standards.md"))
    for name in names {
      try FileManager.default.copyItem(
        at: Fixture.checkoutRoot.appending(path: "\(seeds)/\(name)", directoryHint: .isDirectory),
        to: root.appending(path: "\(seeds)/\(name)", directoryHint: .isDirectory))
    }
    return root
  }

  private static func seedFailures(_ outcome: StaticCheckOutcome) -> [String] {
    guard case .checked(let result) = outcome else { return ["not checked: \(outcome)"] }
    return result.findings.map { "\($0.file): \($0.message)" }.filter {
      $0.hasPrefix("gate/Fixtures/seeds/")
    }
  }

  @Test(
    "each validation seed's validation.json reaches plan-lint, which fires exactly the rule its expected.json names — catches a design plan's table that plan-lint never reads"
  )
  func seedsMatchTheirRules() async throws {
    let root = try Self.stagedRoot(Self.cases)
    defer { TestTemporaryDirectory.remove(root) }

    let outcome = await SelfTest.run(harnessRoot: root)

    #expect(Self.seedFailures(outcome) == [])
  }

  @Test(
    "a validation.json that doesn't decode stops plan-lint naming the file instead of linting without it — catches a corrupt table read as no table"
  )
  func malformedTableBlocks() async throws {
    let root = try Self.stagedRoot(["validation-valid"])
    defer { TestTemporaryDirectory.remove(root) }
    let file = root.appending(path: "gate/Fixtures/seeds/plan-lint/validation-valid/validation.json")
    let text = try String(contentsOf: file, encoding: .utf8)
    try Data(text.replacingOccurrences(of: "\"flow\"", with: "\"unit\"").utf8).write(to: file)

    let failures = Self.seedFailures(await SelfTest.run(harnessRoot: root))

    #expect(failures.count == 1, "\(failures)")
    #expect(failures.first?.contains("validation.json") == true, "\(failures)")
  }
}
