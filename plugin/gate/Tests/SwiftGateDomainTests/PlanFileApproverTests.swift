import Foundation
import SwiftGateDomain
import Testing

@Suite("plan.json records who confirmed a spec page")
struct PlanFileApproverTests {
  static let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/PlanState", directoryHint: .isDirectory)

  static func captured(_ file: String) throws -> Data {
    try Data(contentsOf: fixturesRoot.appending(path: file))
  }

  static func decodingError(_ text: String) -> String? {
    do {
      _ = try PlanFileJSON.decode(Data(text.utf8))
      return nil
    } catch {
      return String(describing: error)
    }
  }

  @Test(
    "a captured plan.json confirmed by user or by spec-quotes decodes with its approver and page sha and re-encodes byte for byte — catches a new approver breaking plans confirmed before it",
    arguments: [
      (
        "confirm-user.json", "user",
        "fac806ca6b4928218e61ed54e030d44a74b6d424473a01541e3a128fe5e01b18"
      ),
      (
        "confirm-spec-quotes.json", "spec-quotes",
        "dbdc3a9cc390c6760e52ddfeeb8750d7fea2d1b3c9a595ab58b9e44db775aa5a"
      ),
    ] as [(String, String, String)])
  func capturedConfirmsDecode(file: String, by: String, pageSha: String) throws {
    let data = try Self.captured(file)
    let plan = try PlanFileJSON.decode(data)
    let source = try #require(plan.specPageSource)
    let approval = try #require(source.approval)
    #expect(approval.by.rawValue == by)
    #expect(approval.pageSha == pageSha)
    #expect(source.pageSha == pageSha)
    #expect(plan.designSource == nil)
    #expect(try PlanFileJSON.encode(plan) == data)
  }

  @Test(
    "a plan.json confirmed by a delegate decodes as delegate and writes delegate back — catches a delegated confirm recorded as the user, or refused as unknown"
  )
  func delegateRoundTrips() throws {
    let text = String(decoding: try Self.captured("confirm-user.json"), as: UTF8.self)
    try #require(text.contains("\"by\" : \"user\""), "the captured plan no longer says by user")
    let delegated = text.replacingOccurrences(
      of: "\"by\" : \"user\"", with: "\"by\" : \"delegate\"")

    let plan = try PlanFileJSON.decode(Data(delegated.utf8))
    let approval = try #require(plan.specPageSource?.approval)
    #expect(approval.by.rawValue == "delegate")
    #expect(approval.by != .user)
    #expect(String(decoding: try PlanFileJSON.encode(plan), as: UTF8.self) == delegated)
  }

  @Test(
    "an approver near delegate still fails decoding and names itself — catches the new approver opening the type to any value"
  )
  func unknownApproverNamesItself() throws {
    let text = String(decoding: try Self.captured("confirm-user.json"), as: UTF8.self)
    for value in ["delegated", "Delegate", "orchestrator"] {
      let error = Self.decodingError(
        text.replacingOccurrences(of: "\"by\" : \"user\"", with: "\"by\" : \"\(value)\""))
      #expect(error?.contains(value) == true, "\(value): \(error ?? "decoded")")
    }
  }
}
