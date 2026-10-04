import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// 1 captured failing area run, read the way the live runner reads it: stdout then stderr, with
/// its JUnit report's placeholders made paths again.
private struct CapturedFailure {
  let outcome: AreaCommandOutcome
  /// The test file the capture changed, from its `change.diff`.
  let testFile: String

  init(_ ecosystem: String) throws {
    let directory = "AreaRuns/\(ecosystem)/test-fail"
    let exit = try #require(
      Int32(try Fixture.text("\(directory)/exit").trimmingCharacters(in: .whitespacesAndNewlines)))
    let output = try Fixture.text("\(directory)/stdout") + Fixture.text("\(directory)/stderr")
    var junit = try? Fixture.text("\(directory)/junit.xml")
    for placeholder in ["repo", "scratch", "home", "tmp", "host", "user"] {
      junit = junit?.replacingOccurrences(of: "<\(placeholder)>", with: "/\(placeholder)")
    }
    outcome = AreaOutcomeReading.outcome(
      end: .exited(exit), output: output, junit: junit.map { Data($0.utf8) })
    let diff = try Fixture.text("\(directory)/change.diff")
    testFile = try #require(
      diff.split(separator: "\n").first { $0.hasPrefix("+++ b/") }.map {
        String($0.dropFirst("+++ b/".count))
      })
  }

  func id(line: Int = 1, name: String? = nil) -> AreaTestID {
    AreaTestID(name: name ?? testFile, selector: testFile, file: testFile, line: line)
  }

  func located(_ id: AreaTestID, among ids: [AreaTestID]? = nil) throws -> ProveAssertion? {
    guard case .failed(_, let tail, let junit) = outcome else {
      Issue.record("a captured failing run reads as failed")
      return nil
    }
    return AreaFailureLocator.firstFailure(
      of: id, among: ids ?? [id], output: tail, junit: junit)
  }
}

@Suite("brownfield proofs")
struct BrownfieldProofsTests {
  @Test(
    "each captured failing run locates its first failure in the changed test's file — catches a reverted failure recorded with no location, or a helper's frame taken for the test's",
    arguments: [
      ("cargo", 17, ProveAssertionKind.other), ("go", 57, .other), ("gradle", 47, .other),
      ("maven", 36, .other), ("node", 21, .other), ("python", 19, .other), ("ruby", 16, .other),
      ("swift", 8, .xctAssert),
    ])
  func locatesCapturedFailures(ecosystem: String, line: Int, kind: ProveAssertionKind) throws {
    let run = try CapturedFailure(ecosystem)

    let found = try run.located(run.id())

    #expect(found == ProveAssertion(file: run.testFile, line: line, kind: kind))
  }

  @Test(
    "a failure in another file is no location for the test, even with the same base name elsewhere — catches any file:line in the output taken as the test's"
  )
  func otherFileIsNoLocation() throws {
    let run = try CapturedFailure("node")
    let other = AreaTestID(
      name: "other", selector: "other", file: "packages/turbo-utils/__tests__/other.test.ts",
      line: 1)
    let renamed = AreaTestID(
      name: "moved", selector: "moved", file: "apps/web/src/convert-case.test.ts", line: 1)

    #expect(try run.located(run.id()) != nil, "the run does name the changed test's file")
    #expect(try run.located(other) == nil)
    #expect(try run.located(renamed) == nil)
  }

  @Test(
    "a failure below a sibling test's first line in the same file is the sibling's, not the earlier test's — catches 1 failure credited to every test in its file"
  )
  func siblingOwnsLaterLines() throws {
    let run = try CapturedFailure("python")
    let earlier = run.id(line: 3, name: "test_a")
    let later = run.id(line: 18, name: "test_id_to_title")

    #expect(try run.located(earlier, among: [earlier, later]) == nil)
    #expect(
      try run.located(later, among: [earlier, later])
        == ProveAssertion(file: run.testFile, line: 19, kind: .other))
  }

  @Test(
    "selected reverted runs map to proven with its location, passes-reverted and crashed, and a time-out records nothing — catches a judgement with no proof row, or a time-out recorded as a verdict"
  )
  func selectedOutcomes() throws {
    let run = try CapturedFailure("python")
    let failing = run.id(name: "failing")
    let passing = AreaTestID(name: "passing", selector: "p", file: "t/p.py", line: 1)
    let crashing = AreaTestID(name: "crashing", selector: "c", file: "t/c.py", line: 1)
    let slow = AreaTestID(name: "slow", selector: "s", file: "t/s.py", line: 1)

    let proved = BrownfieldProofs.proved(
      area: "gguf",
      outcomes: [
        (failing, run.outcome), (passing, .passed), (crashing, .crashed(signal: 6, tail: "")),
        (slow, .timedOut(tail: "")),
      ], whole: false, proofBase: "base0")

    #expect(
      proved == [
        ProvedTest(
          test: "failing", target: "gguf", outcome: .proven, proofBase: "base0",
          assertion: ProveAssertion(file: run.testFile, line: 19, kind: .other)),
        ProvedTest(
          test: "passing", target: "gguf", outcome: .passesReverted, proofBase: "base0",
          assertion: nil),
        ProvedTest(
          test: "crashing", target: "gguf", outcome: .crashed, proofBase: "base0", assertion: nil),
      ])
  }

  @Test(
    "a whole-command crash records nothing for its tests while a whole-command pass records each as passes-reverted — catches 1 crash pinned on every test it ran"
  )
  func wholeOutcomes() {
    let a = AreaTestID(name: "a", selector: "a", file: "t/a.py", line: 1)
    let b = AreaTestID(name: "b", selector: "b", file: "t/b.py", line: 1)

    let crashed = BrownfieldProofs.proved(
      area: "x",
      outcomes: [(a, .crashed(signal: 6, tail: "")), (b, .crashed(signal: 6, tail: ""))],
      whole: true, proofBase: "base0")
    let passed = BrownfieldProofs.proved(
      area: "x", outcomes: [(a, .passed), (b, .passed)], whole: true, proofBase: "base0")

    #expect(crashed == [])
    #expect(passed.map(\.outcome) == [.passesReverted, .passesReverted])
  }
}
