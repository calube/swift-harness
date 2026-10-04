import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("brownfield baseline")
struct BaselineTests {
  static let key = BaselineStepKey(area: "api", step: .test, command: "pytest {junit}")

  @Test(
    "a failure at both trees is absorbed and one at the head only stays — catches a baseline that hides new failures"
  )
  func absorbsOnlyKnownFailures() {
    let verdict = Baseline.compare(
      head: [Self.key: .failedTests(["a.known", "a.new"])],
      base: [Self.key: .failedTests(["a.known", "a.elsewhere"])])

    #expect(verdict.absorbed == [BaselineFailure(key: Self.key, test: "a.known")])
    #expect(verdict.remaining == [BaselineFailure(key: Self.key, test: "a.new")])
    #expect(verdict.baselineCount == 1)
  }

  @Test(
    "a whole-step failure and a named test never absorb each other — catches a failed base step hiding every head test"
  )
  func wholeStepAndNamedTestStayApart() {
    let named = Baseline.compare(
      head: [Self.key: .failedTests(["a.new"])], base: [Self.key: .failed])
    let whole = Baseline.compare(
      head: [Self.key: .failed], base: [Self.key: .failedTests(["a.known"])])
    let both = Baseline.compare(head: [Self.key: .failed], base: [Self.key: .failed])

    #expect(named.remaining == [BaselineFailure(key: Self.key, test: "a.new")])
    #expect(whole.remaining == [BaselineFailure(key: Self.key, test: nil)])
    #expect(both.absorbed == [BaselineFailure(key: Self.key, test: nil)])
    #expect(named.absorbed.isEmpty && whole.absorbed.isEmpty && both.remaining.isEmpty)
  }

  @Test(
    "an answer for another selection or a missing answer absorbs nothing — catches a key without the command's selection"
  )
  func otherSelectionAbsorbsNothing() {
    let first = BaselineStepKey(
      area: "api", step: .testFiles, command: "pytest {tests}", selection: ["a.py"])
    let second = BaselineStepKey(
      area: "api", step: .testFiles, command: "pytest {tests}", selection: ["b.py"])
    let verdict = Baseline.compare(
      head: [second: .failed, Self.key: .failedTests(["a.x"])], base: [first: .failed])

    #expect(verdict.absorbed.isEmpty)
    #expect(
      Set(verdict.remaining) == [
        BaselineFailure(key: second, test: nil), BaselineFailure(key: Self.key, test: "a.x"),
      ])
  }

  @Test(
    "the summary names each absorbed failure as a nit, and is absent when none was — catches a summary that gates"
  )
  func summaryIsANit() throws {
    let verdict = Baseline.compare(
      head: [Self.key: .failedTests(["a.known"])], base: [Self.key: .failedTests(["a.known"])])
    let summary = try #require(verdict.summary(file: "baseline/t.json"))

    #expect(summary.ruleID == BrownfieldRuleID.baselineSummary.rawValue)
    #expect(summary.severity == .nit)
    #expect(summary.message.contains("a.known") && summary.message.contains("api"))
    #expect(BaselineVerdict().summary(file: "baseline/t.json") == nil)
  }

  @Test(
    "a file round-trips, and a newer answer for a key replaces the older — catches a merge that keeps a stale answer"
  )
  func fileRoundTripsAndMerges() throws {
    let lint = BaselineStepKey(
      area: "web", step: .lint, command: "eslint {files}", selection: ["b", "a"])
    var file = BaselineFile(
      tree: "abc", records: [.init(key: Self.key, result: .failedTests(["a.x"]))])
    file.merge([.init(key: lint, result: .failed), .init(key: Self.key, result: .passed)])

    let decoded = try BaselineFile.decode(file.encoded(), tree: "abc")

    #expect(decoded == file)
    #expect(decoded.results == [Self.key: .passed, lint: .failed])
    #expect(lint.selection == ["a", "b"])
  }

  @Test(
    "an unknown step, an unknown result or another tree's file fails decoding and names itself — catches a file read as empty"
  )
  func decodingIsClosed() throws {
    func json(step: String = "test", result: String = "failed", tree: String = "abc") -> Data {
      Data(
        """
        {"version":1,"tree":"\(tree)","records":[{"area":"api","step":"\(step)","command":"c",\
        "selection":[],"result":"\(result)"}]}
        """.utf8)
    }

    _ = try BaselineFile.decode(json(), tree: "abc")
    #expect(throws: BaselineFileError.self) {
      try BaselineFile.decode(json(step: "deploy"), tree: "abc")
    }
    #expect(throws: BaselineFileError.self) {
      try BaselineFile.decode(json(result: "flaky"), tree: "abc")
    }
    #expect(throws: BaselineFileError.self) {
      try BaselineFile.decode(json(result: "failed-tests"), tree: "abc")
    }
    do {
      _ = try BaselineFile.decode(json(tree: "def"), tree: "abc")
      Issue.record("another tree's file decoded")
    } catch {
      #expect(error.detail.contains("def"))
    }
    do {
      _ = try BaselineFile.decode(json(step: "deploy"), tree: "abc")
    } catch {
      #expect(error.detail.contains("deploy"))
    }
  }
}

@Suite("brownfield baseline over captured area runs")
struct BaselineAreaRunTests {
  static let directory = Fixture.directory.appending(path: "AreaRuns", directoryHint: .isDirectory)

  static func outcome(_ ecosystem: String, _ run: String) throws -> AreaCommandOutcome {
    let base = directory.appending(path: "\(ecosystem)/\(run)", directoryHint: .isDirectory)
    let exit = try #require(
      Int32(
        String(decoding: try Data(contentsOf: base.appending(path: "exit")), as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    let tail = String(decoding: try Data(contentsOf: base.appending(path: "stdout")), as: UTF8.self)
    let junit = try? Data(contentsOf: base.appending(path: "junit.xml"))
    if exit == 0 { return .passed }
    if exit > 128 { return .crashed(signal: exit - 128, tail: tail) }
    return .failed(exit: exit, tail: tail, junit: junit)
  }

  @Test(
    "a captured failing run reads as its failing test's id — catches ids read from the wrong attribute or a bare testsuite root",
    arguments: [
      ("python", "tests.test_metadata.TestMetadataMethod.test_id_to_title"),
      ("gradle", "okhttp3.sse.internal.ServerSentEventIteratorTest.multiline()"),
      ("maven", "io.github.jhipster.sample.security.SecurityUtilsUnitTest.testGetCurrentUserLogin"),
      ("swift", "XcodeGenCoreTests.ArrayExtensionsTests.testSearchingForFirstIndex"),
    ])
  func failingRunReadsItsTest(ecosystem: String, test: String) throws {
    #expect(BaselineStepResult.of(try Self.outcome(ecosystem, "test-fail")) == .failedTests([test]))
  }

  @Test(
    "a captured jest failure reads as its test named once — catches a classname repeated into the id"
  )
  func jestFailureReadsOnce() throws {
    #expect(
      BaselineStepResult.of(try Self.outcome("node", "test-fail"))
        == .failedTests(["convertCase should convert 'hello_world' to 'camel'"]))
  }

  @Test(
    "a captured run with no JUnit, or a crash, fails the whole step; a pass passes — catches a crash read as a pass",
    arguments: [
      ("go", "test-fail", BaselineStepResult.failed), ("cargo", "test-fail", .failed),
      ("ruby", "test-fail", .failed), ("python", "test-crash", .failed),
      ("ruby", "test-crash", .failed), ("python", "test-pass", .passed),
      ("go", "test-pass", .passed),
    ])
  func runsWithoutTestIDs(ecosystem: String, run: String, expected: BaselineStepResult) throws {
    #expect(BaselineStepResult.of(try Self.outcome(ecosystem, run)) == expected)
  }

  @Test(
    "a timeout and an unreadable report fail the whole step — catches a truncated report read as a pass"
  )
  func unreadableReportFailsWhole() {
    #expect(BaselineStepResult.of(.timedOut(tail: "")) == .failed)
    #expect(
      BaselineStepResult.of(.failed(exit: 1, tail: "", junit: Data("<testsuites><testcase".utf8)))
        == .failed)
    #expect(
      BaselineStepResult.of(
        .failed(
          exit: 1, tail: "",
          junit: Data("<testsuites><testcase classname=\"a\" name=\"b\"/></testsuites>".utf8)))
        == .failed)
  }
}
