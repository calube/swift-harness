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

  /// Each captured confirmation, its approver and the page sha it recorded.
  static let capturedConfirms: [(file: String, by: String, pageSha: String)] = [
    (
      "confirm-user.json", "user",
      "fac806ca6b4928218e61ed54e030d44a74b6d424473a01541e3a128fe5e01b18"
    ),
    (
      "confirm-spec-quotes.json", "spec-quotes",
      "dbdc3a9cc390c6760e52ddfeeb8750d7fea2d1b3c9a595ab58b9e44db775aa5a"
    ),
  ]

  @Test(
    "the approvers are exactly user, spec-quotes and delegate: captured user and spec-quotes plans re-encode byte for byte, a delegate plan writes delegate back, and a near value fails naming itself — catches a delegated confirm refused or recorded as the user, a plan confirmed before delegate existed breaking, or the type opening to any value"
  )
  func approversAreClosedAndIncludeDelegate() throws {
    #expect(PlanFile.PageApprover.allCases.map(\.rawValue) == ["user", "spec-quotes", "delegate"])

    for captured in Self.capturedConfirms {
      let data = try Self.captured(captured.file)
      let plan = try PlanFileJSON.decode(data)
      let source = try #require(plan.specPageSource, "\(captured.file)")
      let approval = try #require(source.approval, "\(captured.file)")
      #expect(approval.by.rawValue == captured.by, "\(captured.file)")
      #expect(approval.pageSha == captured.pageSha, "\(captured.file)")
      #expect(source.pageSha == captured.pageSha, "\(captured.file)")
      #expect(plan.designSource == nil, "\(captured.file)")
      #expect(try PlanFileJSON.encode(plan) == data, "\(captured.file)")
    }

    let text = String(decoding: try Self.captured("confirm-user.json"), as: UTF8.self)
    try #require(text.contains("\"by\" : \"user\""), "the captured plan no longer says by user")
    let delegated = text.replacingOccurrences(
      of: "\"by\" : \"user\"", with: "\"by\" : \"delegate\"")
    let plan = try PlanFileJSON.decode(Data(delegated.utf8))
    let approval = try #require(plan.specPageSource?.approval)
    #expect(approval.by.rawValue == "delegate")
    #expect(String(decoding: try PlanFileJSON.encode(plan), as: UTF8.self) == delegated)

    for value in ["delegated", "Delegate", "orchestrator"] {
      let error = Self.decodingError(
        text.replacingOccurrences(of: "\"by\" : \"user\"", with: "\"by\" : \"\(value)\""))
      #expect(error?.contains(value) == true, "\(value): \(error ?? "decoded")")
    }
  }
}
