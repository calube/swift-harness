import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("prove's build and its reading of a failed run")
struct ProveBuildTests {
  static let configs = [
    "aidoku-validation-3", "aidoku-validation", "memos-4", "price-tracker-1", "price-tracker-3",
    "price-tracker-5", "send-money-1", "send-money-2", "send-money-3", "tic-tac-toe-1",
  ]

  @Test(
    "every captured trial config's swiftpm test_files builds its tests with swift build --build-tests, and its xcode, node and go areas get no prove build — catches prove building with a test-only option swift build rejects, or splitting a command it can't rewrite"
  )
  func capturedTemplates() throws {
    var swiftpm = 0
    for name in Self.configs {
      let config = try TOMLConfigDecoder().decodeBrownfield(
        try Fixture.text("BrownfieldTrial/\(name)-config.toml"))
      for area in config.areas {
        let command = area.testFiles.flatMap {
          ProveBuild.command(fromTestFiles: $0, kind: area.kind)
        }
        if area.kind == .swiftpm {
          swiftpm += 1
          #expect(command == "swift build --build-tests", "\(name) \(area.name)")
        } else {
          #expect(command == nil, "\(name) \(area.name)")
        }
      }
    }
    #expect(swiftpm == 15)
  }

  @Test(
    "a swift test template keeps the options that change the build and drops the ones that only pick or report tests — catches a prove build of another configuration than its test run, which would then build again",
    arguments: [
      (
        "swift test -c release --parallel --num-workers 2 --filter {tests} --skip Slow",
        "swift build --build-tests -c release"
      ),
      (
        "swift test --xunit-output={junit} -Xswiftc -warnings-as-errors --filter={tests}",
        "swift build --build-tests -Xswiftc -warnings-as-errors"
      ),
    ])
  func keepsBuildOptions(_ template: String, _ expected: String) {
    #expect(ProveBuild.command(fromTestFiles: template, kind: .swiftpm) == expected)
  }

  @Test(
    "a template that builds for coverage, runs more than swift test, or isn't swift test gets no prove build — catches a build whose products the test run can't reuse",
    arguments: [
      "swift test --enable-code-coverage --filter {tests}",
      "cd Sources && swift test --filter {tests}",
      "make test FILTER={tests}",
      "swift test --filter {tests} > {junit}",
    ])
  func refusesWhatItCantCarry(_ template: String) {
    #expect(ProveBuild.command(fromTestFiles: template, kind: .swiftpm) == nil)
  }

  static let probeFile = "Probe/Tests/LibTests/DoubleTests.swift"

  static func id(_ name: String, line: Int) -> AreaTestID {
    AreaTestID(
      name: "LibTests.DoubleTests/\(name)", selector: "^LibTests\\.DoubleTests/\(name)",
      file: probeFile, line: line)
  }

  static let ids = [
    id("doublesThree()", line: 5), id("doublesFour()", line: 6), id("keepsZero()", line: 7),
  ]

  static func report() throws -> Data {
    try #require(
      JUnitReports.combined([
        try Fixture.data("SwiftTest/prove-together.xml"),
        try Fixture.data("SwiftTest/prove-together-swift-testing.xml"),
      ]))
  }

  @Test(
    "the captured run's report settles each of its 3 tests: 2 failed with their issue text and 1 passed, and none runs again — catches a failed run of several tests always rerun 1 by 1"
  )
  func reportSettlesEachTest() throws {
    let attribution = ProveVerdict.attributed(
      .failed(exit: 1, tail: "", junit: try Self.report()), ids: Self.ids)

    #expect(attribution.rerun.isEmpty)
    #expect(attribution.outcomes[Self.ids[2]] == .passed)
    for failed in Self.ids.prefix(2) {
      guard case .failed(_, let tail, _) = attribution.outcomes[failed] else {
        Issue.record("\(failed.name): \(String(describing: attribution.outcomes[failed]))")
        continue
      }
      #expect(tail.contains("Expectation failed"), "\(tail)")
    }
  }

  @Test(
    "a test the report doesn't name runs again alone, and so does every test of a crashed run or a failed run with no report — catches a crash or a missing case read as a pass or a failure"
  )
  func unsettledTestsRunAgain() throws {
    let other = AreaTestID(
      name: "LibTests.DoubleTests/halves()", selector: "^LibTests\\.DoubleTests/halves\\(\\)",
      file: Self.probeFile, line: 8)
    let partial = ProveVerdict.attributed(
      .failed(exit: 1, tail: "", junit: try Self.report()), ids: Self.ids + [other])
    #expect(partial.rerun == [other])
    #expect(partial.outcomes.count == 3)

    for outcome in [
      AreaCommandOutcome.crashed(signal: 5, tail: "Fatal error"),
      .failed(exit: 1, tail: "error: fatalError", junit: nil),
    ] {
      let attribution = ProveVerdict.attributed(outcome, ids: Self.ids)
      #expect(attribution.rerun == Self.ids, "\(outcome)")
      #expect(attribution.outcomes.isEmpty, "\(outcome)")
    }
  }
}
