import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("an area test step's totals read from what it left on disk")
struct AreaTestCountReaderTests {
  private static func request(junitPath: String?, bundle: String? = nil) -> AreaCommandRequest {
    AreaCommandRequest(
      area: "APIClient", step: .test, command: "swift test --xunit-output {junit}",
      workingDirectory: "/", deadline: .seconds(5), environment: [:], junitPath: junitPath,
      resultBundlePath: bundle)
  }

  @Test(
    "a passing swift test step's XCTest report and its Swift Testing companion read as the trial's 7 tests — catches a passing step's totals left unread because the runner reads reports only on failure"
  )
  func readsTheJUnitReportAndItsCompanion() async throws {
    let directory = TestTemporaryDirectory.root.appending(
      path: "area-test-counts-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { TestTemporaryDirectory.remove(directory) }
    for name in ["APIClient.test.xml", "APIClient.test-swift-testing.xml"] {
      try Fixture.data("BrownfieldTrial/send-money-2-junit/\(name)")
        .write(to: directory.appending(path: name))
    }
    let junit = directory.appending(path: "APIClient.test.xml").path

    let counts = await AreaTestCountReader(xcresults: FakeXcresultReader(scenario: "pass"))
      .counts(of: Self.request(junitPath: junit))

    #expect(counts == JUnitCounts(tests: 7, failures: 0, skipped: 0))
  }

  @Test(
    "an xcodebuild step with no JUnit report reads its result bundle: the captured failing bundle's 3 tests, 2 failed — catches an xcode area's totals missing from every report"
  )
  func readsTheResultBundle() async throws {
    let directory = TestTemporaryDirectory.root.appending(
      path: "area-test-counts-\(UUID().uuidString)", directoryHint: .isDirectory)
    let bundle = directory.appending(path: "App.test.xcresult", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { TestTemporaryDirectory.remove(directory) }

    let counts = await AreaTestCountReader(xcresults: FakeXcresultReader(scenario: "fail"))
      .counts(
        of: Self.request(
          junitPath: directory.appending(path: "App.test.xml").path, bundle: bundle.path))

    #expect(counts == JUnitCounts(tests: 3, failures: 2, skipped: 0))
  }
}
