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

  @Test(
    "a run started over send-money-7's earlier combined report at the same --output path leaves a new empty file until it ends, then its own report with the start's creation time — catches build gate-wait --qa reading the earlier run's GREEN, or dating the run from its end"
  )
  func startReplacesAnEarlierReport() throws {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-qa-output-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { TestTemporaryDirectory.remove(root) }
    let path = "out/qa-send-flow.json"
    let file = root.appending(path: path)
    let earlier = try Fixture.data("BrownfieldTrial/send-money-7-qa-combined-before-merge.json")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try earlier.write(to: file)
    let old = Date(timeIntervalSince1970: 1_790_000_000)
    try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: file.path)

    try QARunRun.startOutput(at: path, root: root)

    #expect(try Data(contentsOf: file).isEmpty)
    let started = try #require(
      try FileManager.default.attributesOfItem(atPath: file.path)[.creationDate] as? Date)
    #expect(started > old)
    try FileManager.default.setAttributes(
      [.creationDate: old.addingTimeInterval(60)], ofItemAtPath: file.path)

    try QARunRun.writeOutput(
      try QAReportJSON.decode(earlier), reportFile: nil, to: path, root: root)

    #expect(try QAReportJSON.decode(Data(contentsOf: file)).verdict == .green)
    #expect(
      try FileManager.default.attributesOfItem(atPath: file.path)[.creationDate] as? Date
        == old.addingTimeInterval(60))
  }
}
