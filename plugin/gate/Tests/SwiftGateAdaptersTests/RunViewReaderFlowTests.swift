import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Seeds the captured build run's plan state with the captured final `qa run` and T3 run of the
/// same plan, as they left the checkout.
@Suite("run view reader, flows")
struct RunViewReaderFlowTests {
  typealias Repository = RunViewReaderTests.Repository

  static let captured = Fixture.gateDirectory.appending(
    path: "Tests/Fixtures/RunView/qa-flows", directoryHint: .isDirectory)
  static let qaRun = "20261004T220955Z-1614d1ea"
  static let gateRun = "20261004T221830Z-84cb5ca2"

  static func lines() throws -> [String] {
    try String(contentsOf: captured.appending(path: "events/qa.jsonl"), encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  static func kind(_ line: String) throws -> String? {
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    return object?["kind"] as? String
  }

  static func payload(_ line: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    return try #require(object?["payload"] as? [String: Any])
  }

  /// `line` with its envelope's `runID` and its payload's `plan` replaced where given.
  static func rewritten(_ line: String, runID: String? = nil, plan: String? = nil) throws -> String
  {
    var object = try #require(
      try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    var payload = try #require(object["payload"] as? [String: Any])
    if let runID { object["runID"] = runID }
    if let plan { payload["plan"] = plan }
    object["payload"] = payload
    object["eventID"] = UUID().uuidString
    return String(
      decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      as: UTF8.self)
  }

  static func repository(lines: [String]) throws -> Repository {
    let repository = try Repository()
    try repository.write(lines, to: repository.events.appending(path: "qa.jsonl"))
    let target = repository.checkout.appending(
      path: ".harness/runs/\(qaRun)", directoryHint: .isDirectory)
    try Repository.make(target)
    try FileManager.default.copyItem(
      at: captured.appending(path: "runs/\(qaRun)/qa"), to: target.appending(path: "qa"))
    return repository
  }

  @Test(
    "the plan's batch qa.flow events in the build run's window are kept, and another plan's are not — catches a flow row drawn without its steps, or another plan's flow joined to it"
  )
  func keepsThePlansBatchFlows() throws {
    let lines = try Self.lines()
    let batch = try lines.filter {
      try Self.kind($0) == "qa.flow" && Self.payload($0)["row"] != nil
    }
    try #require(batch.count == 2)
    let other = try Self.rewritten(batch[0], plan: "another-plan")
    let repository = try Self.repository(lines: lines + [other])
    defer { repository.remove() }
    let kept = try repository.read().events.filter {
      if case .qaFlow(let flow) = $0.payload { return flow.row != nil }
      return false
    }
    #expect(Set(kept.map(\.eventID)) == Set(try batch.map(RunViewReaderTests.eventID)))
  }

  @Test(
    "a kept XCUITest qa.flow is kept when its gate run is the build run's, and not otherwise — catches kept flows the reader never shows, or another run's"
  )
  func keepsKeptFlowsOfTheRunsGateRuns() throws {
    let lines = try Self.lines()
    let kept = try lines.filter {
      try Self.kind($0) == "qa.flow" && Self.payload($0)["row"] == nil
    }
    try #require(kept.count == 2)
    let named = try Self.rewritten(kept[0], runID: RunViewReaderTests.redGate)
    let repository = try Self.repository(lines: lines + [named])
    defer { repository.remove() }
    let input = try repository.read()
    let flows = input.events.filter {
      if case .qaFlow(let flow) = $0.payload { return flow.row == nil }
      return false
    }
    #expect(flows.map(\.eventID) == [try RunViewReaderTests.eventID(named)])
    let validation = try #require(RunViewBuilder.build(input).validation)
    #expect(validation.keptFlows.map(\.gateRun) == [RunViewReaderTests.redGate])
    #expect(validation.keptFlows.first?.task == "counter-ui-reset-button")
  }

  @Test(
    "a red flow row's video, sheet, logs and container are not read as saved output, and leave no damage — catches binary evidence read as text"
  )
  func redFlowEvidenceIsNotOutput() throws {
    let repository = try Self.repository(lines: try Self.lines())
    defer { repository.remove() }
    let input = try repository.read()
    #expect(input.qaRuns[Self.qaRun]?.report != nil)
    #expect(input.qaRuns[Self.qaRun]?.outputs.isEmpty == true)
    #expect(input.damage.isEmpty, "\(input.damage)")
  }
}
