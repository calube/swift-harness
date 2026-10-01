import CryptoKit
import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("test result event")
struct TestResultEventsTests {
  private static func hostEvidence(xctest: String?, swiftTesting: String?) throws
    -> HostTestEvidence
  {
    HostTestEvidence(
      packagePath: "Probe", testTargets: [], succeeded: true,
      xctestReport: try xctest.map { try Fixture.data("SwiftTest/\($0)") },
      swiftTestingReport: try swiftTesting.map { try Fixture.data("SwiftTest/\($0)") },
      stdout: "", stderr: "", testSourceFiles: [], repositoryRoot: Fixture.repositoryRoot)
  }

  private static func bundleCases(_ scenario: String, tier: Tier) throws -> [TestCaseResult] {
    try XcresultTestResults.parse(Fixture.data("Xcresult/\(scenario).tests.json")).testCases
      .compactMap { TestCaseResult($0, tier: tier) }
  }

  @Test(
    "captured xUnit reports give 1 case per testcase with its id, target, outcome and duration, skipped cases included — catches a skipped case dropped"
  )
  func xunitCases() throws {
    let evidence = try Self.hostEvidence(
      xctest: "pass.xml", swiftTesting: "skip-swift-testing.xml")

    let cases = TestCaseResult.cases(in: evidence)

    #expect(
      cases == [
        TestCaseResult(
          test: "ProbeTests.PassXCTests/testDoubles", target: "ProbeTests", tier: .t1,
          outcome: .passed, milliseconds: 31),
        TestCaseResult(
          test: "ProbeTests.SkipSwiftTests/disabledWithReason", target: "ProbeTests", tier: .t1,
          outcome: .skipped, milliseconds: nil),
        TestCaseResult(
          test: "ProbeTests.SkipSwiftTests/disabledWithoutReason", target: "ProbeTests",
          tier: .t1, outcome: .skipped, milliseconds: nil),
      ])
  }

  @Test(
    "a captured failing Swift Testing report gives a failed case, and an unreadable report gives none — catches a failure recorded as a pass"
  )
  func xunitFailure() throws {
    let failing = try Self.hostEvidence(xctest: nil, swiftTesting: "fail-swift-testing.xml")
    let torn = HostTestEvidence(
      packagePath: "Probe", testTargets: [], succeeded: false,
      xctestReport: Data("<testsuites><testsuite>".utf8), swiftTestingReport: nil, stdout: "",
      stderr: "", testSourceFiles: [], repositoryRoot: Fixture.repositoryRoot)

    #expect(
      TestCaseResult.cases(in: failing) == [
        TestCaseResult(
          test: "ProbeTests.FailSwiftTests/doublesWrong", target: "ProbeTests", tier: .t1,
          outcome: .failed, milliseconds: 0)
      ])
    #expect(TestCaseResult.cases(in: torn).isEmpty)
  }

  @Test(
    "captured result bundles give 1 case per test case with its id, target, outcome and duration, skipped and failed included — catches a skipped case dropped"
  )
  func bundleCases() throws {
    #expect(
      try Self.bundleCases("skip", tier: .t2) == [
        TestCaseResult(
          test: "CounterUISnapshotTests.ProbeSkipXCTests/testSkippedWithoutReason",
          target: "CounterUISnapshotTests", tier: .t2, outcome: .skipped, milliseconds: 9),
        TestCaseResult(
          test: "CounterUISnapshotTests.ProbeSkipXCTests/testSkippedWithReason",
          target: "CounterUISnapshotTests", tier: .t2, outcome: .skipped, milliseconds: 2),
        TestCaseResult(
          test: "CounterUISnapshotTests.ProbeSkipSwiftTests/disabledWithoutReason",
          target: "CounterUISnapshotTests", tier: .t2, outcome: .skipped, milliseconds: nil),
        TestCaseResult(
          test: "CounterUISnapshotTests.ProbeSkipSwiftTests/disabledWithReason",
          target: "CounterUISnapshotTests", tier: .t2, outcome: .skipped, milliseconds: nil),
      ])
    #expect(
      try Self.bundleCases("fail", tier: .t3).map(\.outcome) == [.failed, .passed, .failed])
  }

  @Test(
    "a result the bundle reader doesn't know gives no case, and an expected failure keeps its outcome — catches an unknown result recorded as a pass"
  )
  func bundleOutcomes() {
    let unknown = XcresultTestCase(
      identifier: "Suite/a()", targetName: "T", result: .other("unknown"), messages: [])
    let expected = XcresultTestCase(
      identifier: "Suite/b()", targetName: "T", result: .expectedFailure, messages: ["known"],
      milliseconds: 4)

    #expect(TestCaseResult(unknown, tier: .t2) == nil)
    #expect(TestCaseResult(expected, tier: .t2)?.outcome == .expectedFailure)
    #expect(TestCaseResult(expected, tier: .t2)?.milliseconds == 4)
  }

  @Test(
    "the same test gets the same id from a swift test report and a result bundle, for XCTest, Swift Testing, nested suites and arguments — catches host and simulator runs of 1 test that never join"
  )
  func sameIDFromBothSources() throws {
    let bundle = try XcresultTestResults.parse(Fixture.data("Xcresult/pass.tests.json"))
      .testCases
    let xctest = try #require(bundle.first { $0.identifier == "ProbePassXCTests/testAdds()" })
    let skipped = try XcresultTestResults.parse(Fixture.data("Xcresult/skip.tests.json"))
      .testCases
    let swiftTesting = try #require(
      skipped.first { $0.identifier == "ProbeSkipSwiftTests/disabledWithReason()" })
    let pairs: [(XUnitTestCase, XcresultTestCase)] = [
      (
        XUnitTestCase(
          className: "CounterUISnapshotTests.ProbePassXCTests", name: "testAdds",
          outcome: .passed),
        xctest
      ),
      (
        XUnitTestCase(
          className: "CounterUISnapshotTests.ProbeSkipSwiftTests", name: "disabledWithReason()",
          outcome: .skipped(reason: "r")),
        swiftTesting
      ),
      (
        XUnitTestCase(className: "T.Outer.Inner", name: "nested()", outcome: .passed),
        XcresultTestCase(
          identifier: "Outer/Inner/nested()", targetName: "T", result: .passed, messages: [])
      ),
      (
        XUnitTestCase(className: "T.Suite", name: "param(value:)", outcome: .passed),
        XcresultTestCase(
          identifier: "Suite/param(value:)", targetName: "T", result: .passed, messages: [])
      ),
      (
        XUnitTestCase(className: "T", name: "free()", outcome: .passed),
        XcresultTestCase(identifier: "free()", targetName: "T", result: .passed, messages: [])
      ),
    ]

    for (host, simulator) in pairs {
      let fromHost = TestCaseResult(host, tier: .t1)
      let fromBundle = try #require(TestCaseResult(simulator, tier: .t2))
      #expect(fromHost.test == fromBundle.test)
      #expect(fromHost.target == fromBundle.target)
    }
    #expect(
      TestCaseResult(pairs[2].0, tier: .t1).test == "T.Outer/Inner/nested",
      "nested suites join with / after the target")
    #expect(TestCaseResult(pairs[3].0, tier: .t1).test == "T.Suite/param(value:)")
    #expect(TestCaseResult(pairs[4].0, tier: .t1).test == "T.free")
  }

  @Test(
    "an id of 512 bytes or more is stored as sha256:<hex> of it with testHashed, and a shorter one is stored as is without the flag — catches a long id dropped by the payload guard"
  )
  func longIDsAreHashed() throws {
    let long = "T.Suite/" + String(repeating: "a", count: 504)
    let short = String(long.dropLast())
    #expect(long.utf8.count == 512)
    func result(_ id: String) -> TestCaseResult {
      TestCaseResult(test: id, target: "T", tier: .t1, outcome: .passed, milliseconds: 3)
    }

    let hashed = TestResultEvent(result(long))
    let kept = TestResultEvent(result(short))

    let hex = SHA256.hash(data: Data(long.utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(hashed.test == "sha256:\(hex)")
    #expect(hashed.testHashed)
    #expect(kept.test == short)
    #expect(!kept.testHashed)
    let keptJSON = String(decoding: try JSONEncoder().encode(kept), as: UTF8.self)
    #expect(!keptJSON.contains("testHashed"))
    #expect(
      try JSONDecoder().decode(TestResultEvent.self, from: JSONEncoder().encode(hashed)) == hashed)
    #expect(try JSONDecoder().decode(TestResultEvent.self, from: Data(keptJSON.utf8)) == kept)
  }
}
