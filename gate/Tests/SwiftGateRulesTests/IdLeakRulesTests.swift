import SwiftGateDomain
import SwiftGateRules
import Testing

/// Spec §5.1: local ids (ledger tasks, claims, doc requirement/test-plan ids) and codename-shaped
/// text must never leak into committed code. Covers both rule families that enforce it
/// (`comments.leaked-id`, `test.leaked-id`) plus the pure ``KnownIds`` set builder they share.
@Suite("Known-id leak rules")
struct IdLeakRulesTests {
  private func commentFindings(_ text: String, knownIds: Set<String> = []) throws -> [String] {
    let rule = try #require(
      RuleCatalog.comments.first { $0.descriptor.id == "comments.leaked-id" }
    )
    let input = SourceInput(path: "F.swift", text: text)
    let context = RuleContext(scopes: StaticModuleScopes(), knownIds: knownIds)
    let result = try RuleEngine(rules: [rule]).run([input], context: context)
    return result.findings.map(\.message)
  }

  private func testNameFindings(_ text: String, knownIds: Set<String> = []) throws -> [String] {
    let rule = try #require(
      RuleCatalog.testlint.first { $0.descriptor.id == "test.leaked-id" })
    let input = SourceInput(path: "FTests.swift", text: text)
    let context = RuleContext(scopes: StaticModuleScopes(), knownIds: knownIds)
    let result = try RuleEngine(rules: [rule]).run([input], context: context)
    return result.findings.map(\.message)
  }

  @Test(
    "a ledger task id in a comment is flagged — catches local plan ids leaking into code")
  func ledgerTaskIdInComment() throws {
    let text = "// ties into offline-queue-core-reducer directly\nlet x = 1\n"
    #expect(try commentFindings(text, knownIds: ["offline-queue-core-reducer"]).count == 1)
    #expect(
      try commentFindings(
        "// an unrelated comment\nlet x = 1\n",
        knownIds: [
          "offline-queue-core-reducer"
        ]
      ).isEmpty)
  }

  @Test(
    "a claim id in a Swift Testing display name is flagged — catches evidence ids leaking into test names"
  )
  func claimIdInTestName() throws {
    let id = "ev-tca-effect-run-supports-cancellation"
    let leaking =
      "import Testing\n@Test(\"\(id)\")\nfunc regressionCheck() {\n  #expect(1 == 1)\n}\n"
    #expect(try testNameFindings(leaking, knownIds: [id]).count == 1)
    let clean =
      "import Testing\n@Test(\"a clean behavior name\")\nfunc regressionCheck() {\n"
      + "  #expect(1 == 1)\n}\n"
    #expect(try testNameFindings(clean, knownIds: [id]).isEmpty)
  }

  @Test(
    "Wave N, Stage-N and the bare task-id shape are flagged, lowercase 'phase' prose is not — catches plan codenames without over-matching English"
  )
  func codenameShapes() throws {
    let waveAndStage = "// Wave 3 shipped this; Stage-0 seeded the rest\nlet x = 1\n"
    #expect(try commentFindings(waveAndStage).count == 2)

    let bareTaskId = "// milestone SH1 unblocked the stepper\nlet x = 1\n"
    #expect(try commentFindings(bareTaskId).count == 1)

    let adjective = "// a phase-locked loop keeps the clock in sync\nlet x = 1\n"
    #expect(try commentFindings(adjective).isEmpty)
  }

  @Test(
    "a known id embedded in a longer identifier is not flagged — catches substring false positives"
  )
  func embeddedIdNotFlagged() throws {
    let text = "// see reoffline-queue-core-reducer-migrated for details\nlet x = 1\n"
    #expect(try commentFindings(text, knownIds: ["offline-queue-core-reducer"]).isEmpty)
  }

  @Test(
    "common technical tokens are not flagged — catches acronyms and version strings shaped like a codename"
  )
  func technicalTokensNotFlagged() throws {
    let text = """
      // Encode as UTF8, hash with SHA1 or MD5, target iOS18 on ARM64 or x86.
      // Respect A11y over P2P, decode H264 via HTTP2, require Swift6, ship as v2.
      let x = 1
      """
    #expect(try commentFindings(text).isEmpty)
  }

  @Test(
    "a codename-shaped function name with no display name is flagged — catches an id leaking through the declaration itself"
  )
  func codenameInFunctionName() throws {
    let text = "import Testing\n@Test func SH1() {\n  #expect(1 == 1)\n}\n"
    #expect(try testNameFindings(text).count == 1)
  }

  @Test(
    "an interpolated segment in a display name is skipped rather than matched literally — catches a false match or crash on `@Test(\"...\\(x)...\")`"
  )
  func interpolatedDisplayNameSegmentIgnored() throws {
    let text =
      "import Testing\nlet stage = 2\n@Test(\"Wave \\(stage) migration completes\")\n"
      + "func migrationCompletes() {\n  #expect(1 == 1)\n}\n"
    #expect(try testNameFindings(text).isEmpty)
  }

  @Test(
    "KnownIds.build merges ledger, claim and doc ids and drops blanks — catches a malformed source becoming a match-everything id"
  )
  func knownIdsBuild() {
    let ids = KnownIds.build(
      ledgerTaskIds: ["offline-queue-core-reducer", "  ", ""],
      claimIds: ["ev-tca-effect-run-supports-cancellation"],
      docIds: ["req-offline-queue-drains-on-reconnect", "offline-queue-core-reducer"])
    #expect(
      ids
        == [
          "offline-queue-core-reducer", "ev-tca-effect-run-supports-cancellation",
          "req-offline-queue-drains-on-reconnect",
        ])
    #expect(KnownIds.build().isEmpty)
  }
}
