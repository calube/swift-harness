import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("xUnit report durations")
struct XUnitReportDurationTests {
  @Test(
    "each case carries its own time in milliseconds — catches a duration read from the suite's total",
    arguments: [
      ("SwiftTest/pass.xml", [31]),
      ("SwiftTest/pass-swift-testing.xml", [0]),
      ("SwiftTest/skip.xml", [34, 34]),
      ("SwiftTest/reverted.xml", [3015]),
    ])
  func caseDurations(fixture: String, expected: [Int]) throws {
    let cases = try XUnitReport.parse(try Fixture.data(fixture))

    #expect(cases.map(\.milliseconds) == expected.map { Optional($0) })
  }

  @Test("a case without a time attribute has no duration — catches a missing time read as 0 ms")
  func missingTime() throws {
    let report = try Fixture.text("SwiftTest/pass.xml")
    let stripped = report.replacingOccurrences(
      of: #"(<testcase [^>]*?) time="[^"]*""#, with: "$1", options: .regularExpression)
    #expect(stripped != report)

    let timed = try XUnitReport.parse(Data(report.utf8))
    let untimed = try XUnitReport.parse(Data(stripped.utf8))

    #expect(timed.map(\.milliseconds) == [31])
    #expect(untimed.map(\.name) == ["testDoubles"])
    #expect(untimed.map(\.milliseconds) == [nil])
  }
}
