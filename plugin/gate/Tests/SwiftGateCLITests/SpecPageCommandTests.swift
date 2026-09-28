import Foundation
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("spec-page check command")
struct SpecPageCommandTests {
  static func path(_ file: String) -> String {
    Fixture.directory.appending(path: "spec-page/\(file)").path
  }

  static func json(_ output: String) throws -> [String: Any] {
    try #require(
      try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], "\(output)")
  }

  @Test(
    "a captured page whose slices all quote its spec exits 0 and prints confirm: skippable, its slice ids and page sha — catches a command the skill can't read the confirm from"
  )
  func greenHuman() {
    let result = SpecPageCheckRun.run(
      pagePath: Self.path("task-status.page.txt"), specPath: Self.path("task-status.spec.txt"),
      json: false)

    #expect(result.exitCode == 0)
    let lines = result.output.split(separator: "\n").map(String.init)
    #expect(lines.first == "spec-page check: GREEN")
    #expect(lines.contains("confirm: skippable"))
    #expect(
      lines.contains("pageSha: dbdc3a9cc390c6760e52ddfeeb8750d7fea2d1b3c9a595ab58b9e44db775aa5a"))
    #expect(
      lines.contains {
        $0.contains("slice-1-test-new-task-is-to-do-with-only-start-and-empty-history")
      })
    #expect(
      lines.contains {
        $0.contains("slice-4-test-undo-reverts-latest-change-and-is-disabled-when-history-empty")
      })
  }

  @Test(
    "--json prints the verdict, confirm, page sha, slices and findings under fixed keys — catches a key rename breaking plan confirm"
  )
  func greenJSON() throws {
    let result = SpecPageCheckRun.run(
      pagePath: Self.path("recipient-postcode.page.txt"),
      specPath: Self.path("recipient-postcode.spec.txt"), json: true)

    #expect(result.exitCode == 0)
    let object = try Self.json(result.output)
    #expect(object["command"] as? String == "spec-page check")
    #expect(object["verdict"] as? String == "GREEN")
    #expect(object["confirm"] as? String == "skippable")
    #expect(object["message"] is NSNull)
    #expect(
      object["pageSha"] as? String
        == "fac806ca6b4928218e61ed54e030d44a74b6d424473a01541e3a128fe5e01b18")
    let slices = try #require(object["slices"] as? [[String: Any]])
    #expect(slices.count == 4)
    #expect(slices[0]["number"] as? Int == 1)
    #expect(
      slices[0]["id"] as? String == "slice-1-test-short-recipient-shows-error-and-disables-save")
    #expect(slices[0]["test"] as? String == "testShortRecipientShowsErrorAndDisablesSave")
    #expect(slices[0]["tier"] as? String == "T1")
    #expect(slices[0]["line"] as? Int == 23)
    #expect((slices[0]["quote"] as? String)?.hasPrefix("A recipient of fewer") == true)
    let findings = try #require(object["findings"] as? [[String: Any]])
    #expect(findings.map { $0["rule"] as? String } == ["spec-page.summary"])
  }

  @Test(
    "a page with a none slice and too many words exits 1, reports confirm required and a null quote — catches a RED page exiting 0"
  )
  func redPage() throws {
    let result = SpecPageCheckRun.run(
      pagePath: Self.path("shipping-address.page.txt"),
      specPath: Self.path("shipping-address.spec.txt"), json: true)

    #expect(result.exitCode == 1)
    let object = try Self.json(result.output)
    #expect(object["verdict"] as? String == "RED")
    #expect(object["confirm"] as? String == "required")
    let slices = try #require(object["slices"] as? [[String: Any]])
    #expect(slices[2]["quote"] is NSNull)
    let findings = try #require(object["findings"] as? [[String: Any]])
    #expect(findings.first?["rule"] as? String == "spec-page.too-long")
  }

  @Test(
    "an unreadable spec file exits 2 and is never GREEN, naming the file — catches a missing spec skipping every quote check"
  )
  func unreadableSpec() throws {
    let missing = Self.path("no-such.spec.txt")
    for json in [false, true] {
      let result = SpecPageCheckRun.run(
        pagePath: Self.path("task-status.page.txt"), specPath: missing, json: json)

      #expect(result.exitCode == 2)
      #expect(result.output.contains(missing))
      #expect(!result.output.contains("GREEN"))
    }
    let object = try Self.json(
      SpecPageCheckRun.run(
        pagePath: Self.path("task-status.page.txt"), specPath: missing, json: true
      ).output)
    #expect(object["verdict"] as? String == "BLOCKED")
    #expect(object["confirm"] is NSNull)
  }

  @Test(
    "an unreadable page exits 2 with no page sha — catches a confirm bound to a page never read"
  )
  func unreadablePage() throws {
    let missing = Self.path("no-such.page.txt")
    let result = SpecPageCheckRun.run(
      pagePath: missing, specPath: Self.path("task-status.spec.txt"), json: true)

    #expect(result.exitCode == 2)
    let object = try Self.json(result.output)
    #expect(object["verdict"] as? String == "BLOCKED")
    #expect(object["pageSha"] is NSNull)
    #expect((object["message"] as? String)?.contains(missing) == true)
  }
}
