import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Where a recorded reverted `swift test` run first failed, for each probe test.
@Suite("prove assertion locator")
struct ProveAssertionLocatorTests {
  private static let file = "XUnitProbe/Tests/ProbeTests/PassTests.swift"
  private static let xcTest = ChangedTest(
    framework: .xcTest, target: "ProbeTests", suites: ["PassXCTests"], function: "testDoubles",
    file: file, line: 6, lastLine: 8)
  private static let swiftTest = ChangedTest(
    framework: .swiftTesting, target: "ProbeTests", suites: ["PassSwiftTests"],
    function: "doubles()", file: file, line: 12, lastLine: 14)

  private static func evidence(root: String) throws -> HostTestEvidence {
    HostTestEvidence(
      packagePath: "XUnitProbe", testTargets: [], succeeded: false,
      xctestReport: try Fixture.data("SwiftTest/reverted.xml"),
      swiftTestingReport: try Fixture.data("SwiftTest/reverted-swift-testing.xml"),
      stdout: try Fixture.text("SwiftTest/reverted.stdout"),
      stderr: try Fixture.text("SwiftTest/reverted.stderr"), testSourceFiles: [file],
      repositoryRoot: root)
  }

  private static let recordedRoot = "\(Fixture.repositoryRoot)/gate/Fixtures/swifttest"

  @Test(
    "an XCTest failure under the run's root is located repo-relative with kind xct-assert, and outside it has no location — catches the printed absolute path kept"
  )
  func xctestLocated() throws {
    let found = ProveAssertionLocator.firstFailure(
      of: Self.xcTest, in: try Self.evidence(root: Self.recordedRoot)
    ) { _, _ in nil }

    let outside = ProveAssertionLocator.firstFailure(
      of: Self.xcTest, in: try Self.evidence(root: "/elsewhere")
    ) { _, _ in nil }

    #expect(found == ProveAssertion(file: Self.file, line: 7, kind: .xctAssert))
    #expect(outside == nil)
  }

  @Test(
    "a Swift Testing issue inside the test's lines takes the test's file, and its source line decides expect or require, and an issue outside its lines is not its own — catches a bare file name stored, or require read as expect"
  )
  func swiftTestingLocated() throws {
    let evidence = try Self.evidence(root: Self.recordedRoot)

    let expectFound = ProveAssertionLocator.firstFailure(of: Self.swiftTest, in: evidence) {
      _, _ in "    #expect(double(3) == 6)"
    }
    var asked: [String] = []
    let requireFound = ProveAssertionLocator.firstFailure(of: Self.swiftTest, in: evidence) {
      file, line in
      asked.append("\(file):\(line)")
      return "    try #require(double(3) == 6)"
    }

    #expect(expectFound == ProveAssertion(file: Self.file, line: 13, kind: .expect))
    #expect(requireFound == ProveAssertion(file: Self.file, line: 13, kind: .require))
    let elsewhere = ChangedTest(
      framework: .swiftTesting, target: "ProbeTests", suites: ["PassSwiftTests"],
      function: "doubles()", file: Self.file, line: 1, lastLine: 4)
    let notOwn = ProveAssertionLocator.firstFailure(of: elsewhere, in: evidence) { _, _ in nil }

    #expect(asked == ["\(Self.file):13"])
    #expect(notOwn == nil)
  }

  @Test(
    "each reverted run maps to its outcome, and a run with no evidence to none — catches a passing or crashed run recorded as proven"
  )
  func outcomes() throws {
    let test = Self.swiftTest
    let crash = try Finding(
      ruleID: "t1.crashed", severity: .major, file: Self.file, line: nil, message: "crashed",
      failureScenario: nil)

    #expect(
      ProvedTest.outcome(of: test, run: .reported([test: .failed(message: "x")]), judgement: .empty)
        == .proven)
    #expect(
      ProvedTest.outcome(of: test, run: .reported([test: .passed]), judgement: .empty)
        == .passesReverted)
    #expect(ProvedTest.outcome(of: test, run: .reported([:]), judgement: .empty) == nil)
    #expect(ProvedTest.outcome(of: test, run: .crashed(crash), judgement: .empty) == .crashed)
    #expect(ProvedTest.outcome(of: test, run: .noEvidence("none"), judgement: .empty) == nil)
  }
}
