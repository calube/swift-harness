import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("xcresult test durations")
struct XcresultReportDurationTests {
  @Test(
    "each case carries its durationInSeconds in milliseconds — catches the display string duration parsed instead",
    arguments: [
      ("Xcresult/fail.tests.json", [19, 0, nil]),
      ("Xcresult/record.tests.json", [32, 1000]),
      ("Xcresult/ui-pass.tests.json", [4908]),
    ] as [(String, [Int?])])
  func caseDurations(fixture: String, expected: [Int?]) throws {
    let results = try XcresultTestResults.parse(try Fixture.data(fixture))

    #expect(results.testCases.map(\.milliseconds) == expected)
  }
}
