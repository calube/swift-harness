import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `swiftgate self-test`'s seed runner (spec §12): every `gate/Fixtures/seeds/<command>/<case>/`
/// must match its own `expected.json` exactly, and the runner itself must go RED — not silently
/// pass — when a seed stops proving what it claims to.
@Suite("swiftgate self-test — mechanical seeds (evidence, probe, design-lint, design-diff)")
struct DesignSeedsSelfTestTests {
  private static func failures(_ outcome: StaticCheckOutcome) -> [String] {
    guard case .checked(let result) = outcome else { return ["not checked: \(outcome)"] }
    return result.findings.map { "\($0.file): \($0.message)" }
  }

  private static func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-design-seeds-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
  }

  /// Copies one real, committed seed case into an otherwise-empty harness root, so a test can
  /// mutate its own copy without touching this checkout and without paying for the arch/rule/
  /// sample-app parts of `SelfTest.run`, which have nothing to check in an empty root beyond their
  /// own (irrelevant, and ignored below) hygiene findings.
  private static func stagedCase(_ relativePath: String, in root: URL) throws {
    let source = Fixture.checkoutRoot.appending(
      path: "gate/Fixtures/seeds/\(relativePath)", directoryHint: .isDirectory)
    let destination = root.appending(
      path: "gate/Fixtures/seeds/\(relativePath)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: destination)
  }

  private static func seedFailures(_ outcome: StaticCheckOutcome) -> [String] {
    failures(outcome).filter { $0.hasPrefix("gate/Fixtures/seeds/") }
  }

  // MARK: - Every shipped seed matches its own answer key

  @Test(
    "every committed seed under gate/Fixtures/seeds fires exactly the rule id(s) its expected.json names — catches a seed drifting from the rule it exists to prove"
  )
  func everyShippedSeedMatchesItsExpectedRuleIDs() async throws {
    let outcome = await SelfTest.run(harnessRoot: Fixture.checkoutRoot.resolvingSymlinksInPath())
    #expect(Self.seedFailures(outcome) == [])
  }

  // MARK: - A neutralised seed fails self-test, not silently passes (catches a gate that stopped catching lies)

  @Test(
    "restoring the citation tag a design-lint seed exists to catch makes self-test fail loudly, naming the rule id that stopped firing"
  )
  func neutralizedDesignLintSeedFailsSelfTest() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.stagedCase("design-lint/untagged-decision-bullet", in: root)

    let before = await SelfTest.run(harnessRoot: root)
    #expect(Self.seedFailures(before) == [])

    let docURL = root.appending(
      path: "gate/Fixtures/seeds/design-lint/untagged-decision-bullet/design.md")
    var text = try String(contentsOf: docURL, encoding: .utf8)
    #expect(text.contains("- Client-side queue\n"))
    text = text.replacingOccurrences(
      of: "- Client-side queue\n",
      with: "- Client-side queue [ev-tca-effect-run-supports-cancellation]\n")
    try text.write(to: docURL, atomically: true, encoding: .utf8)

    let after = await SelfTest.run(harnessRoot: root)
    #expect(
      Self.seedFailures(after).contains {
        $0.contains("expected rule id(s) [design-lint.untagged-bullet], got []")
      })
  }

  @Test(
    "un-tampering an evidence-check capture seed makes self-test fail, naming the rule id that stopped firing — proves the guard on a second family, not just design-lint"
  )
  func neutralizedEvidenceCheckSeedFailsSelfTest() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.stagedCase("evidence-check/tampered-capture", in: root)
    try Self.stagedCase("evidence-check/valid", in: root)

    let before = await SelfTest.run(harnessRoot: root)
    #expect(Self.seedFailures(before) == [])

    let capture =
      "captures/7f66639af7446921f447ce6e225cec40651d40d287bf8cb781f80360162639fb.txt"
    let cleanURL = root.appending(
      path: "gate/Fixtures/seeds/evidence-check/valid/docs/example/designs/seed.evidence/\(capture)"
    )
    let tamperedURL = root.appending(
      path:
        "gate/Fixtures/seeds/evidence-check/tampered-capture/docs/example/designs/seed.evidence/\(capture)"
    )
    try FileManager.default.removeItem(at: tamperedURL)
    try FileManager.default.copyItem(at: cleanURL, to: tamperedURL)

    let after = await SelfTest.run(harnessRoot: root)
    #expect(
      Self.seedFailures(after).contains {
        $0.contains("expected rule id(s) [evidence-check.captureHashMismatch], got []")
      })
  }

  @Test(
    "a seed that fires the wrong rule id is reported by name, not conflated with the one it claims — catches a seed's answer key silently drifting to match a regression"
  )
  func wrongExpectedRuleIDFailsSelfTest() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.stagedCase("evidence-check/forged-quote", in: root)

    let expectedURL = root.appending(
      path: "gate/Fixtures/seeds/evidence-check/forged-quote/expected.json")
    try Data(
      """
      {"schemaVersion": 1, "verdict": "red", "ruleIDs": ["evidence-check.citedFileMissing"]}
      """.utf8
    ).write(to: expectedURL)

    let outcome = await SelfTest.run(harnessRoot: root)
    #expect(
      Self.seedFailures(outcome).contains {
        $0.contains("expected rule id(s) [evidence-check.citedFileMissing]")
          && $0.contains("got [evidence-check.quoteNotFound]")
      })
  }

  // MARK: - Hygiene

  @Test("a seed case with no expected.json is a hygiene failure, not a silent skip")
  func caseWithoutExpectedJSONIsAHygieneFailure() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.stagedCase("design-lint/valid", in: root)
    try FileManager.default.removeItem(
      at: root.appending(path: "gate/Fixtures/seeds/design-lint/valid/expected.json"))

    let outcome = await SelfTest.run(harnessRoot: root)
    #expect(
      Self.seedFailures(outcome).contains(
        "gate/Fixtures/seeds/design-lint/valid: no expected.json"))
  }

  @Test("a seed directory whose name names no registered command is a hygiene failure")
  func unregisteredSeedCommandIsAHygieneFailure() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bogus = root.appending(path: "gate/Fixtures/seeds/bogus-command/some-case")
    try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
    try Data(
      #"{"schemaVersion": 1, "verdict": "green", "ruleIDs": []}"#.utf8
    ).write(to: bogus.appending(path: "expected.json"))

    let outcome = await SelfTest.run(harnessRoot: root)
    #expect(
      Self.seedFailures(outcome).contains(
        "gate/Fixtures/seeds/bogus-command: no self-test runner is registered for the seed command \"bogus-command\""
      ))
  }

  @Test(
    "expected.json's format is closed: an unknown key, a bad schemaVersion, a bad verdict, and ruleIDs disagreeing with verdict each fail on their own — catches the answer key silently accepting garbage",
    arguments: [
      #"{"schemaVersion": 1, "verdict": "green", "ruleIDs": [], "extra": true}"#,
      #"{"schemaVersion": 2, "verdict": "green", "ruleIDs": []}"#,
      #"{"schemaVersion": 1, "verdict": "maybe", "ruleIDs": []}"#,
      #"{"schemaVersion": 1, "verdict": "green", "ruleIDs": ["design-lint.untagged-bullet"]}"#,
      #"{"schemaVersion": 1, "verdict": "red", "ruleIDs": []}"#,
      #"{"schemaVersion": 1, "verdict": "red", "ruleIDs": ["b", "a"]}"#,
    ]
  )
  func malformedExpectedJSONIsRejected(_ json: String) async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.stagedCase("design-lint/valid", in: root)
    let expectedURL = root.appending(
      path: "gate/Fixtures/seeds/design-lint/valid/expected.json")
    try Data(json.utf8).write(to: expectedURL)

    let outcome = await SelfTest.run(harnessRoot: root)
    #expect(
      Self.seedFailures(outcome).contains {
        $0.hasPrefix("gate/Fixtures/seeds/design-lint/valid/expected.json:")
      })
  }

  // MARK: - docs-lint seeds one violation per family (spec §6.2)

  @Test(
    "docs-lint seeds, run through self-test's own seed runner, fire at least one rule id for every family the spec's docs-lint table names — catches a family shipping with no seed of its own"
  )
  func everyDocsLintFamilyHasASeed() async throws {
    let root = Self.tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let seedsRoot = Fixture.checkoutRoot.appending(
      path: "gate/Fixtures/seeds/docs-lint", directoryHint: .isDirectory)
    let cases = try FileManager.default.contentsOfDirectory(
      at: seedsRoot, includingPropertiesForKeys: [.isDirectoryKey]
    ).filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
    struct Expected: Decodable { let ruleIDs: [String] }
    var ruleIDs: Set<String> = []
    for directory in cases {
      try Self.stagedCase("docs-lint/\(directory.lastPathComponent)", in: root)
      let data = try Data(contentsOf: directory.appending(path: "expected.json"))
      ruleIDs.formUnion(try JSONDecoder().decode(Expected.self, from: data).ruleIDs)
    }
    // Each case's expected.json only counts once the real runner shows the case fires exactly it.
    let outcome = await SelfTest.run(harnessRoot: root)
    #expect(Self.seedFailures(outcome) == [])
    // Spec §6.2's docs-lint family table, one row per family; a family with two rule ids (either
    // proves it) lists both.
    let families: [String: Set<String>] = [
      "reference integrity": [
        "docs-lint.dangling-id", "docs-lint.bare-adr-reference", "docs-lint.requirement-uncited",
      ],
      "relative links": ["docs-lint.broken-relative-link"],
      "router reachability / managed files": [
        "docs-lint.unreachable-doc", "docs-lint.managed-file-missing",
        "docs-lint.managed-file-unlisted",
      ],
      "non-vacuity": ["docs-lint.anchor-vacuous"],
      "banned phrases": ["docs-lint.banned-phrase"],
      "repo-specific anchors": ["docs-lint.anchor-vacuous"],
      "local paths": ["docs-lint.local-path"],
      "budgets": [
        "docs-lint.topic-word-budget", "docs-lint.router-word-budget",
        "docs-lint.agents-md-line-budget",
      ],
    ]
    let uncovered = families.filter { ruleIDs.isDisjoint(with: $0.value) }.keys.sorted()
    #expect(uncovered == [])
  }
}
