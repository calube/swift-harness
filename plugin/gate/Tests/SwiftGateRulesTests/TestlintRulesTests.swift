import Foundation
import SwiftGateDomain
import SwiftGateRules
import Testing

/// Exact-line checks for each testlint rule over its fixtures, under the fixture's manifest
/// context.
@Suite("Testlint rules")
struct TestlintRulesTests {
  private func lines(_ ruleID: String, _ fixture: String, flows: [String]?? = nil) throws -> [Int] {
    let rule = try #require(RuleCatalog.testlint.first { $0.descriptor.id == ruleID })
    let directory = RuleFixtureTests.fixturesRoot.appending(path: ruleID)
    let manifestFile = directory.appending(path: "fixture.json")
    var manifest = RuleFixtureManifest()
    if FileManager.default.fileExists(atPath: manifestFile.path) {
      manifest = try JSONDecoder().decode(
        RuleFixtureManifest.self, from: Data(contentsOf: manifestFile))
    }
    let base = try manifest.context()
    let context =
      flows.map { RuleContext(scopes: base.scopes, flows: $0) } ?? base
    let file = directory.appending(path: fixture)
    let input = SourceInput(
      path: manifest.path(forFileNamed: file.lastPathComponent),
      text: try String(contentsOf: file, encoding: .utf8))
    let result = try RuleEngine(rules: [rule]).run([input], context: context)
    return result.findings.filter { $0.ruleID == ruleID }.compactMap(\.line)
  }

  @Test(
    "tests with no assertion are RED at their declaration; every recognised assertion form counts — catches tests that cannot fail"
  )
  func noAssertion() throws {
    #expect(try lines("test.no-assertion", "bad/SwiftTesting.swift") == [5])
    #expect(try lines("test.no-assertion", "bad/XCTest.swift") == [5])
    #expect(try lines("test.no-assertion", "good/Assertions.swift") == [])
  }

  @Test(
    "a Swift Testing test on a TestClock or withMainSerialExecutor outside a .serialized suite is RED; nested and extended serialized suites and XCTest pass — catches clock tests that hang under parallel runs"
  )
  func testClockSerialized() throws {
    #expect(try lines("test.testclock-serialized", "bad/Unserialized.swift") == [6, 21, 29])
    #expect(try lines("test.testclock-serialized", "good/Serialized.swift") == [])
  }

  @Test(
    "literal, self-comparison and just-constructed assertions are RED — catches assertions that cannot fail"
  )
  func tautology() throws {
    #expect(try lines("test.tautology", "bad/Tautologies.swift") == [6, 12, 18, 23, 24])
    #expect(try lines("test.tautology", "good/RealChecks.swift") == [])
  }

  @Test("a test whose only assertions are nil checks is RED — catches existence-only tests")
  func existenceOnly() throws {
    #expect(try lines("test.existence-only", "bad/NotNil.swift") == [5, 11, 16])
    #expect(try lines("test.existence-only", "good/Behavior.swift") == [])
  }

  @Test("asserting a value configured on the test's own double is RED — catches tests of the mock")
  func assertsOwnDouble() throws {
    #expect(try lines("test.asserts-own-double", "bad/Doubles.swift") == [7, 13])
    #expect(try lines("test.asserts-own-double", "good/DoubleDrivesSUT.swift") == [])
  }

  @Test("try? and catch without an issue in a test body are RED — catches swallowed failures")
  func swallowedError() throws {
    #expect(try lines("test.swallowed-error", "bad/Swallowed.swift") == [5, 13, 22])
    #expect(try lines("test.swallowed-error", "good/Recorded.swift") == [])
  }

  @Test("Task.sleep, usleep and Thread.sleep in tests are RED — catches timing-dependent flakes")
  func sleep() throws {
    #expect(try lines("test.sleep", "bad/Sleeps.swift") == [6, 12, 13])
    #expect(try lines("test.sleep", "good/TestClock.swift") == [])
  }

  @Test(
    "bodies equal after dropping trivia are duplicates, reported on the later copy — catches copy-pasted tests"
  )
  func duplicate() throws {
    #expect(try lines("test.duplicate", "bad/Duplicates.swift") == [10])
    #expect(try lines("test.duplicate", "good/Distinct.swift") == [])
  }

  @Test("duplicates are found across files — catches a copy in a sibling file")
  func duplicateAcrossFiles() throws {
    let body = "import Testing\n@Test(\"n — c\")\nfunc a() {\n  #expect(f() == 1)\n}\n"
    let result = try RuleEngine(rules: RuleCatalog.testlint).run(
      [SourceInput(path: "T/B.swift", text: body), SourceInput(path: "T/A.swift", text: body)],
      context: RuleContext(scopes: StaticModuleScopes()))
    let duplicates = result.findings.filter { $0.ruleID == "test.duplicate" }
    #expect(duplicates.map(\.file) == ["T/B.swift"])
    #expect(duplicates.first?.message.contains("T/A.swift:3") == true)
  }

  @Test("@Test without a display name is RED — catches tests whose name carries no regression")
  func unnamed() throws {
    #expect(try lines("test.unnamed", "bad/Unnamed.swift") == [3, 7, 11])
    #expect(try lines("test.unnamed", "good/Named.swift") == [])
  }

  @Test(
    "non-exhaustive TestStore without a same-line reason is RED — catches silently skipped state assertions"
  )
  func nonExhaustiveStore() throws {
    #expect(try lines("test.non-exhaustive-store", "bad/Off.swift") == [8, 10, 11])
    #expect(try lines("test.non-exhaustive-store", "good/Justified.swift") == [])
  }

  @Test(
    "XCUITests must map to a declared flow; with no config the rule is inert — catches T3 growing past the closed list"
  )
  func xcuitestFlows() throws {
    #expect(try lines("test.xcuitest-unlisted-flow", "bad/Unlisted.swift") == [4])
    #expect(try lines("test.xcuitest-unlisted-flow", "good/Listed.swift") == [])
    #expect(try lines("test.xcuitest-unlisted-flow", "bad/Unlisted.swift", flows: .some(nil)) == [])
  }

  @Test(
    "a T2 test rendering nothing and importing only Core/Client is RED — catches host logic on the simulator"
  )
  func misplacedT2() throws {
    #expect(try lines("test.misplaced-t2", "bad/HostLogic.swift") == [1])
    #expect(try lines("test.misplaced-t2", "good/Snapshot.swift") == [])
    #expect(try lines("test.misplaced-t2", "good/UIModuleImport.swift") == [])
  }

  @Test(
    "the same host-logic test in a T1 target is fine — catches the rule firing without tier data")
  func misplacedT2NeedsTier() throws {
    let text = "@testable import CartCore\nimport Testing\n"
    let scopes = StaticModuleScopes([
      .init(scope: ModuleScope(module: "CartCore", role: .core), directories: ["Sources/CartCore"]),
      .init(
        scope: ModuleScope(module: "CartCoreTests", role: .tests(.t1)),
        directories: ["Tests/CartCoreTests"]),
    ])
    let result = try RuleEngine(rules: RuleCatalog.testlint).run(
      [SourceInput(path: "Tests/CartCoreTests/A.swift", text: text)],
      context: RuleContext(scopes: scopes))
    #expect(!result.findings.contains { $0.ruleID == "test.misplaced-t2" })
  }

  @Test("testlint ignores non-test files — catches production helpers linted as tests")
  func nonTestFilesIgnored() throws {
    let text = "func testSomething() { try? run(); Thread.sleep(forTimeInterval: 1) }\n"
    let result = try RuleEngine(rules: RuleCatalog.testlint).run(
      [SourceInput(path: "Sources/AppCore/Helpers.swift", text: text)],
      context: RuleContext(scopes: PathConventionModuleScopes()))
    #expect(result.findings.isEmpty)
  }

  @Test(
    "the orphan test's pre-deadline mutant `while true {}` is RED at its literal and today's deadline version passes — catches a fixture that hangs on every prove and mutate run"
  )
  func hangWithoutDeadlineOrphanMutant() throws {
    let id = "test.hang-without-deadline"
    #expect(try lines(id, "bad/OrphanMutantBeforeDeadline.swift") == [15])
    #expect(try lines(id, "good/OrphanMutantWithDeadline.swift") == [])
  }

  @Test(
    "every forever-waiting shape a test writes out is RED: constant-true loops in Swift, C, shell and Python with no exit, a break that only leaves an inner loop, sleep infinity, RunLoop run(), dispatchMain() and pause() — catches a hang the orphan test's shape alone would miss"
  )
  func hangWithoutDeadlineShapes() throws {
    #expect(
      try lines("test.hang-without-deadline", "bad/Shapes.swift")
        == [6, 7, 8, 9, 10, 18, 24, 25, 26, 27, 28])
  }

  @Test(
    "a loop with a break, return or exit, a finite sleep, and any literal that sets its own deadline (Date, deadline, DispatchTime, time.time(), timeout N, alarm, withTimeout) pass, and so does a test display name naming a shape, beside a bare spin that fails — catches the rule flagging fixtures that end by themselves"
  )
  func hangWithoutDeadlineBounded() throws {
    #expect(try lines("test.hang-without-deadline", "good/Bounded.swift") == [])
    let directory = RuleFixtureTests.fixturesRoot.appending(path: "test.hang-without-deadline")
    let text = try String(
      contentsOf: directory.appending(path: "bad/Shapes.swift"), encoding: .utf8)
    let result = try RuleEngine(rules: RuleCatalog.testlint).run(
      [SourceInput(path: "Tests/HangTests/Shapes.swift", text: text)],
      context: RuleContext(scopes: PathConventionModuleScopes()))
    let finding = try #require(
      result.findings.first { $0.ruleID == "test.hang-without-deadline" && $0.line == 9 })
    #expect(finding.severity == .major)
    #expect(finding.message.contains("while :"))
    #expect(finding.message.contains("deadline"))
  }

  @Test(
    "a spinning script held in a file-scope constant, outside any function or type, is RED — catches a top-level literal skipped as if it were an attribute argument"
  )
  func hangWithoutDeadlineFileScope() throws {
    #expect(try lines("test.hang-without-deadline", "bad/FileScope.swift") == [3])
  }

  @Test(
    "an exit after a spinning loop's closing brace doesn't count as leaving it — catches the loop body read past its own closing brace"
  )
  func hangWithoutDeadlineExitAfterLoop() throws {
    #expect(try lines("test.hang-without-deadline", "bad/ExitAfterLoop.swift") == [4])
  }

  @Test(
    "a loop a literal opens but never closes, and a Python `while True:` ending the literal, are RED — catches a script assembled from pieces crashing the scan past its last character"
  )
  func hangWithoutDeadlineUnclosedFragments() throws {
    #expect(try lines("test.hang-without-deadline", "bad/UnclosedFragments.swift") == [4, 5, 6])
  }

  @Test(
    "a Python exit at the loop's own indent is after the loop, not in it — catches the line that ends a Python loop's body read as part of it"
  )
  func hangWithoutDeadlinePythonExitAfterLoop() throws {
    #expect(try lines("test.hang-without-deadline", "bad/PythonExitAfterLoop.swift") == [4])
  }

  @Test(
    "a carriage return and an escaped quote in a literal keep the words around them apart — catches a spin hidden by decoding `\\r` or `\\\"` to nothing"
  )
  func hangWithoutDeadlineEscapedSeparators() throws {
    #expect(try lines("test.hang-without-deadline", "bad/EscapedSeparators.swift") == [4, 5])
  }

  @Test(
    "a repeat tail with no opening brace, a shell loop that exits before a missing done, a break after a nested shell loop and a tab-indented Python break all pass — catches a crash on a fragment, or a loop's own exit missed"
  )
  func hangWithoutDeadlineLoopFragments() throws {
    #expect(try lines("test.hang-without-deadline", "good/LoopFragments.swift") == [])
  }

  @Test(
    "price-tracker's captured detail test, which spins on `while !flag { await Task.yield() }` twice, is RED at both loops, and loops bounded by a deadline, an attempt cap, a break or a throw pass — catches a test that hangs its gate when the flag never flips"
  )
  func unboundedWaitCapturedSpins() throws {
    #expect(try lines("test.unbounded-wait", "bad/AssetDetailFeatureTests.swift") == [71, 73])
    #expect(try lines("test.unbounded-wait", "good/BoundedWaits.swift") == [])
  }
}
