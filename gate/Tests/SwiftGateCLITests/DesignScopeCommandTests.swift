import Foundation
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate design-scope")
struct DesignScopeCommandTests {
  private func temporaryFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-design-scope-\(UUID().uuidString).json", directoryHint: .notDirectory)
    try Data(contents.utf8).write(to: url)
    return url
  }

  @Test(
    "no --frame-answers is a failure, never a default tier — catches a skill forgetting the flag")
  func missingFlagFails() {
    guard case .failed(let message) = DesignScopeRun.run(frameAnswersPath: nil) else {
      Issue.record("expected .failed")
      return
    }
    #expect(message.contains("--frame-answers"))
  }

  @Test("an unreadable path is a failure, never a default tier")
  func unreadablePathFails() {
    let missing = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-design-scope-missing-\(UUID().uuidString).json")
    guard case .failed(let message) = DesignScopeRun.run(frameAnswersPath: missing.path) else {
      Issue.record("expected .failed")
      return
    }
    #expect(message.contains(missing.path))
  }

  @Test("malformed JSON is a failure, never a default tier")
  func malformedJSONFails() throws {
    let file = try temporaryFile("not json")
    defer { try? FileManager.default.removeItem(at: file) }
    guard case .failed(let message) = DesignScopeRun.run(frameAnswersPath: file.path) else {
      Issue.record("expected .failed")
      return
    }
    #expect(message.contains(file.path))
  }

  @Test("a valid frame-answers file recommends a tier and echoes the input")
  func validFileRecommends() throws {
    let file = try temporaryFile(
      """
      {
        "schemaVersion": 1,
        "addsDependency": false,
        "addsModuleKind": false,
        "modulesAdded": 0,
        "modulesTouched": 4
      }
      """)
    defer { try? FileManager.default.removeItem(at: file) }
    guard case .recommended(let report) = DesignScopeRun.run(frameAnswersPath: file.path) else {
      Issue.record("expected .recommended")
      return
    }
    #expect(report.tier == .deep)
    #expect(report.reasons.map(\.code) == [.modulesTouched])
    #expect(report.input.modulesTouched == 4)
  }

  @Test("the JSON report round-trips through JSONDecoder with the documented keys")
  func jsonReportShape() throws {
    let file = try temporaryFile(
      """
      {
        "schemaVersion": 1,
        "addsDependency": true,
        "addsModuleKind": false,
        "modulesAdded": 0,
        "modulesTouched": 0
      }
      """)
    defer { try? FileManager.default.removeItem(at: file) }
    guard case .recommended(let report) = DesignScopeRun.run(frameAnswersPath: file.path) else {
      Issue.record("expected .recommended")
      return
    }
    let rendered = DesignScopeReport.render(report, format: .json)
    let object =
      try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
    #expect(object?["command"] as? String == "design-scope")
    #expect(object?["tier"] as? String == "standard")
    let input = object?["input"] as? [String: Any]
    #expect(input?["addsDependency"] as? Bool == true)
    let reasons = object?["reasons"] as? [[String: Any]]
    #expect(reasons?.first?["code"] as? String == "new-dependency")
  }

  @Test("the human report names the tier and every reason")
  func humanReportShape() throws {
    let file = try temporaryFile(
      """
      {
        "schemaVersion": 1,
        "addsDependency": false,
        "addsModuleKind": false,
        "modulesAdded": 1,
        "modulesTouched": 1
      }
      """)
    defer { try? FileManager.default.removeItem(at: file) }
    guard case .recommended(let report) = DesignScopeRun.run(frameAnswersPath: file.path) else {
      Issue.record("expected .recommended")
      return
    }
    let rendered = DesignScopeReport.render(report, format: .human)
    #expect(rendered.contains("quick"))
    #expect(rendered.contains("no new dependency"))
  }
}
