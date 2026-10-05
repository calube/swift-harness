import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The captured starter's tracked tree, as discover reads it.
private func starterTree() throws -> TrackedTreeSnapshot {
  let directory = Fixture.directory.appending(
    path: "Discover/interview-starter", directoryHint: .isDirectory)
  let listing = try String(contentsOf: directory.appending(path: "ls-files.txt"), encoding: .utf8)
  let tree = directory.appending(path: "tree", directoryHint: .isDirectory)
  return TrackedTreeSnapshot(
    paths: listing.split(separator: "\n").map(String.init),
    read: { try? Data(contentsOf: tree.appending(path: $0)) })
}

private func starterArea() throws -> BrownfieldArea {
  let areas = XcodeReader().areas(in: try starterTree())
  #expect(areas.count == 1)
  return BrownfieldArea(proposed: try #require(areas.first))
}

@Suite("a failing baseline step keeps its evidence and is read per test")
struct BaselineEvidenceTests {
  static let test = BaselineStepKey(area: "app", step: .test, command: "xcodebuild test")
  static let build = BaselineStepKey(area: "app", step: .build, command: "xcodebuild build")

  @Test(
    "an xcodebuild test run's failures read per test from its result bundle — catches 1 failing test at the merge base excusing every test of the step"
  )
  func resultBundleReadsPerTest() throws {
    let junit = try #require(
      XcresultTestReport.junit(fromTests: try Fixture.data("Xcresult/fail.tests.json")))
    let result = BaselineStepResult.of(.failed(exit: 65, tail: "** TEST FAILED **", junit: junit))

    #expect(
      result
        == .failedTests([
          "CounterUISnapshotTests.ProbeFailXCTests/testAddsWrong()",
          "CounterUISnapshotTests.ProbeFailSwiftTests/multipliesWrong()",
        ]))
    #expect(
      AreaOutcomeReading.junitCounts(junit) == JUnitCounts(tests: 3, failures: 2, skipped: 0))
  }

  @Test(
    "a test runner that couldn't launch, or a test target that didn't compile, fails the whole step — catches an infrastructure failure read as the tests it never ran",
    arguments: ["runner-launch-failed", "build-error"])
  func unownedFailureIsTheWholeStep(capture: String) throws {
    let tests = try Fixture.data("Xcresult/\(capture).tests.json")
    #expect(XcresultTestReport.junit(fromTests: tests) == nil)
  }

  @Test(
    "an xcode area's test step asks xcodebuild for a result bundle beside its JUnit path, and its build step doesn't — catches a test step whose failures can only read as the whole step"
  )
  func testStepRequestsAResultBundle() throws {
    let area = try starterArea()
    let junit = "/clone/.git/swift-harness/junit/\(area.name).test.xml"
    let prepare = { (step: AreaStep) in
      AreaCommandExpansion.prepare(
        area: area, step: step, repositoryRoot: "/clone", files: [], tests: [], junitPath: junit,
        deadline: .seconds(60), environment: [:])
    }

    let test = try #require(prepare(.test)).request
    let bundle = "/clone/.git/swift-harness/junit/\(area.name).test.xcresult"
    #expect(test.resultBundlePath == bundle)
    #expect(test.command == (area.test ?? "") + " -resultBundlePath '\(bundle)'")
    let build = try #require(prepare(.build)).request
    #expect(build.resultBundlePath == nil)
    #expect(build.command == area.build)

    let piped = "set -o pipefail && " + (area.test ?? "") + " | xcbeautify"
    #expect(AreaCommandExpansion.requestingResultBundle(piped, at: bundle) == nil)
    let named = (area.test ?? "") + " -resultBundlePath out.xcresult"
    #expect(AreaCommandExpansion.requestingResultBundle(named, at: bundle) == nil)
  }

  @Test(
    "with test ids asked for, a test step failing whole at both trees gates while a build step and a named test stay absorbed — catches final GREEN on a test step it excused whole"
  )
  func wholeTestStepIsUnattributed() throws {
    let head: [BaselineStepKey: BaselineStepResult] = [
      Self.test: .failed, Self.build: .failed,
      BaselineStepKey(area: "pkg", step: .test, command: "swift test"): .failedTests(["a.known"]),
    ]
    let base = head

    let merge = Baseline.compare(head: head, base: base)
    let final = Baseline.compare(head: head, base: base, attributingTests: true)

    #expect(merge.unattributed.isEmpty)
    #expect(merge.absorbed.count == 3)
    #expect(final.unattributed == [BaselineFailure(key: Self.test, test: nil)])
    #expect(
      Set(final.absorbed) == [
        BaselineFailure(key: Self.build, test: nil),
        BaselineFailure(
          key: BaselineStepKey(area: "pkg", step: .test, command: "swift test"), test: "a.known"),
      ])
    #expect(final.remaining.isEmpty)

    let evidence = [
      Self.test: BaselineEvidence(
        head: ["/runs/r1/app.test.txt", "/runs/r1/app.test.xcresult"],
        base: ["/clone/.git/swift-harness/baseline/tree0/app.test.1a2b"])
    ]
    let findings = final.unattributedFindings(file: "baseline/tree0.json", evidence: evidence)
    #expect(findings.count == 1)
    let finding = try #require(findings.first)
    #expect(finding.ruleID == BrownfieldRuleID.baselineWholeStep.rawValue)
    #expect(finding.severity.failsGate)
    for path in evidence[Self.test]!.head + evidence[Self.test]!.base {
      #expect(finding.message.contains(path), "names \(path)")
    }
  }

  @Test(
    "the baseline summary names where each absorbed step's head and merge base runs were kept — catches an excused failure nobody can look at"
  )
  func summaryNamesEvidence() throws {
    let verdict = Baseline.compare(head: [Self.test: .failed], base: [Self.test: .failed])
    let summary = try #require(
      verdict.summary(
        file: "baseline/tree0.json",
        evidence: [
          Self.test: BaselineEvidence(
            head: ["/runs/r1/app.test.txt"], base: ["/baseline/tree0/app.test.1a2b"])
        ]))

    #expect(summary.message.contains("/runs/r1/app.test.txt"))
    #expect(summary.message.contains("/baseline/tree0/app.test.1a2b"))
    #expect(summary.severity == .nit)
  }

  @Test(
    "a baseline record keeps its evidence folder through encoding, and a record without one encodes as before — catches evidence lost when the file is reread"
  )
  func evidenceRoundTrips() throws {
    let kept = BaselineRecord(key: Self.test, result: .failed, evidence: "tree0/app.test.1a2b")
    let bare = BaselineRecord(key: Self.build, result: .failed)
    let file = BaselineFile(tree: "tree0", records: [kept, bare])

    let decoded = try BaselineFile.decode(file.encoded(), tree: "tree0")

    #expect(decoded.records == [kept, bare])
    let plain = String(decoding: BaselineFile(tree: "tree0", records: [bare]).encoded(), as: UTF8.self)
    #expect(!plain.contains("evidence"))
  }

  @Test(
    "the starter's test globs cover its UI test folder and every local package's Tests folder, each in exactly 1 area, and no source — catches prove reading 4 added tests as no changed tests"
  )
  func starterTestGlobsMatchItsTests() throws {
    let tree = try starterTree()
    let area = try starterArea()
    let areas = Discover.propose(tree: tree, head: "abc", dirty: []).areas.map(
      BrownfieldArea.init(proposed:))
    let swift = tree.paths.filter { $0.hasSuffix(".swift") && !$0.hasSuffix("Package.swift") }
    let tests = swift.filter { $0.hasPrefix("UITests/") || $0.contains("/Tests/") }
    let sources = swift.filter { !tests.contains($0) }

    #expect(!tests.isEmpty && !sources.isEmpty)
    for path in tests {
      #expect(
        areas.filter { ChangedTestIDs.isTestFile(path, of: $0) }.count == 1,
        "\(path) is a test file of 1 area")
    }
    for path in sources {
      #expect(
        !areas.contains { ChangedTestIDs.isTestFile(path, of: $0) }, "\(path) is no test file")
    }
    #expect(
      ChangedTestIDs.isTestFile("UITests/NewFlowUITests.swift", of: area),
      "a test added to the synchronized folder later is a test file")
  }
}
