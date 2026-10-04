import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A captured `F/AreaRuns/go/<case>/` run, read the way the live runner reads it: stderr folded
/// into stdout and no `{junit}` report.
private func goRun(_ caseName: String) throws -> AreaCommandOutcome {
  let directory = "AreaRuns/go/\(caseName)"
  let exit = try #require(
    Int32(try Fixture.text("\(directory)/exit").trimmingCharacters(in: .whitespacesAndNewlines)))
  let output = try Fixture.text("\(directory)/stdout") + Fixture.text("\(directory)/stderr")
  return AreaOutcomeReading.outcome(end: .exited(exit), output: output, junit: nil)
}

private let key = BaselineStepKey(area: "gobase", step: .test, command: "go test -json ./...")

private let alpha = "example.com/gobase/alpha"

@Suite("go test -json read per test")
struct GoTestReportTests {
  @Test(
    "a new failing Go test is not absorbed by a base that failed a different test — catches a Go baseline that exempts the whole step"
  )
  func newFailureStillGates() throws {
    let base = BaselineStepResult.of(try goRun("baseline-base"))
    let head = BaselineStepResult.of(try goRun("baseline-head"))

    let verdict = Baseline.compare(head: [key: head], base: [key: base])

    #expect(
      verdict.remaining == [BaselineFailure(key: key, test: "example.com/gobase/beta.TestNew")])
    #expect(
      verdict.absorbed.map(\.test) == [
        "\(alpha).TestFlaky", "\(alpha).TestTable", "\(alpha).TestTable/case_b",
      ])
  }

  @Test(
    "captured -json events read as exactly their failing tests, package-qualified, subtests included — catches passes, output lines or package events read as failures"
  )
  func eventsReadAsFailingTests() throws {
    #expect(
      BaselineStepResult.of(try goRun("baseline-base"))
        == .failedTests(["\(alpha).TestFlaky", "\(alpha).TestTable", "\(alpha).TestTable/case_b"]))
    let pocketbase = "github.com/pocketbase/pocketbase/tools/list"
    let failing = BaselineStepResult.of(try goRun("test-fail"))
    guard case .failedTests(let tests) = failing else {
      Issue.record("pocketbase's failing run read as \(failing)")
      return
    }
    #expect(tests.contains("\(pocketbase).TestSubtractSliceString"))
    #expect(
      tests.allSatisfy {
        $0.hasPrefix("\(pocketbase).TestSubtractSliceString/")
          || $0 == "\(pocketbase).TestSubtractSliceString"
      })
  }

  @Test(
    "a package that fails to build beside failing tests fails the whole step, which a base of named tests can't absorb — catches a build failure hidden behind its neighbours' test ids"
  )
  func buildFailureFailsWholeStep() throws {
    let head = BaselineStepResult.of(try goRun("build-fail"))
    let base = BaselineStepResult.of(try goRun("baseline-base"))

    #expect(head == .failed)
    let verdict = Baseline.compare(head: [key: head], base: [key: base])
    #expect(verdict.remaining == [BaselineFailure(key: key, test: nil)])
    #expect(verdict.absorbed.isEmpty)
  }

  @Test(
    "the failing test's own output is its failure text — catches a report that drops where the test failed"
  )
  func failureTextKeepsOutput() throws {
    guard case .failed(_, _, let junit?) = try goRun("baseline-base") else {
      Issue.record("the captured failing run carries no report")
      return
    }
    let cases = try XUnitReport.parse(junit)
    let flaky = try #require(cases.first { $0.name == "TestFlaky" })
    #expect(flaky.className == alpha)
    #expect(cases.first { $0.name == "TestPasses" }?.outcome == .passed)
    #expect(
      String(decoding: junit, as: UTF8.self).contains("alpha_test.go:12: fails at the base commit"))
  }

  @Test(
    "go test gains -json once, wherever it runs in the command — catches a mined go test left without events, or -json doubled",
    arguments: [
      ("go test ./...", "go test -json ./..."),
      ("go test ./... -run {tests}", "go test -json ./... -run {tests}"),
      (
        "GO_VERSION=1.27.0 DRIVER=sqlite go test -v -race ./server/...",
        "GO_VERSION=1.27.0 DRIVER=sqlite go test -json -v -race ./server/..."
      ),
      (
        "cd ../.. && go test ./a/... && go test ./b/...",
        "cd ../.. && go test -json ./a/... && go test -json ./b/..."
      ),
      ("go test -json -run X ./...", "go test -json -run X ./..."),
      ("make test", "make test"),
      ("cargo test", "cargo test"),
      ("go testdata", "go testdata"),
    ])
  func requestingJSON(command: String, expected: String) {
    #expect(GoTestReport.requestingJSON(command) == expected)
  }

  @Test(
    "discover asks a Go area's test commands for -json and leaves its build alone — catches a proposal whose Go failures can only be read as the whole step"
  )
  func discoverRequestsJSON() throws {
    let directory = Fixture.directory.appending(
      path: "Discover/usememos-memos", directoryHint: .isDirectory)
    let listing = try String(contentsOf: directory.appending(path: "ls-files.txt"), encoding: .utf8)
    let files = directory.appending(path: "tree", directoryHint: .isDirectory)
    let tree = TrackedTreeSnapshot(
      paths: listing.split(separator: "\n").map(String.init),
      read: { try? Data(contentsOf: files.appending(path: $0)) })

    let proposal = Discover.propose(tree: tree, head: "abc", dirty: [], readers: [GoReader()])

    let memos = try #require(proposal.areas.first { $0.kind == .go })
    #expect(memos.commands[.test]?.value == "go test -json ./...")
    #expect(memos.commands[.testFiles]?.value == "go test -json ./... -run {tests}")
    #expect(memos.commands[.build]?.value == "go build ./...")
  }
}
