import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("qa run --output")
struct QARunOutputTests {
  @Test(
    "the fixer's captured report written through --output to a relative path under a missing folder parses whole as a report with its summary last, and holds no start line — catches the trial's file whose stderr start line came first so json.load raised"
  )
  func writesOnlyTheReport() throws {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-qa-output-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { TestTemporaryDirectory.remove(root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let report = try QAReportJSON.decode(
      Fixture.data("BrownfieldTrial/send-money-6-qa-fixer-before-merge.json"))

    try QARunRun.writeOutput(
      report, reportFile: "/repo/.git/swift-harness/runs/x/qa/report.json",
      to: ".harness/tmp/qa-amount-feature.json", root: root)

    let data = try Data(contentsOf: root.appending(path: ".harness/tmp/qa-amount-feature.json"))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.hasPrefix("{"), "\(text.prefix(80))")
    let written = try QAReportJSON.decode(data)
    #expect(written.runID == report.runID)
    let object = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let summary = try #require(object["summary"] as? String)
    #expect(summary.contains(try #require(report.runID)), "\(summary)")
    #expect(!text.contains("started; its report will be written"))
  }
}
