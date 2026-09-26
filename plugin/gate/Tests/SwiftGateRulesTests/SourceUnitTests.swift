import SwiftGateDomain
import SwiftGateRules
import Testing

@Suite("SourceUnit")
struct SourceUnitTests {
  private func unit(_ text: String) -> SourceUnit {
    SourceUnit(input: SourceInput(path: "A.swift", text: text), scope: nil)
  }

  @Test(
    "comments carry lines, placement and stripped bodies — catches comment rules reading the wrong line"
  )
  func commentExtraction() {
    let comments = unit(
      """
      // first
      // second

      /// doc
      let a = "// not a comment" // trailing
      /*
       * block
       */
      let b = 1
      """
    ).comments
    #expect(comments.map(\.body) == ["first", "second", "doc", "trailing", "block"])
    #expect(comments.map(\.startLine) == [1, 2, 4, 5, 6])
    #expect(comments.map(\.endLine) == [1, 2, 4, 5, 8])
    #expect(comments.map(\.isTrailing) == [false, false, false, true, false])
    #expect(comments.map(\.isFollowedByBlankLine) == [false, true, false, false, false])
    #expect(comments.map(\.kind) == [.line, .line, .docLine, .line, .block])
  }

  @Test(
    "allow directives parse id and reason; malformed ones have no reason — catches bare allows passing as justified"
  )
  func allowParsing() {
    let directives = unit(
      """
      a() // swiftgate:allow x.y — because
      b() // swiftgate:allow x.y -- ascii
      c() // swiftgate:allow x.y
      d() // swiftgate:allow x.y —
      e() // swiftgate:allow x.y - single hyphen
      f() // swiftgate:allowed x.y — not the marker
      """
    ).allowDirectives
    #expect(
      directives == [
        AllowDirective(ruleID: "x.y", line: 1, reason: "because"),
        AllowDirective(ruleID: "x.y", line: 2, reason: "ascii"),
        AllowDirective(ruleID: "x.y", line: 3, reason: nil),
        AllowDirective(ruleID: "x.y", line: 4, reason: nil),
        AllowDirective(ruleID: "x.y", line: 5, reason: nil),
      ])
  }

  @Test(
    "imports and test-file detection come from syntax — catches test files missed outside Tests/")
  func imports() {
    let tests = unit("@testable import PayCore\nimport Testing\nlet s = \"import XCTest\"")
    #expect(tests.imports == ["PayCore", "Testing"])
    #expect(tests.isTestFile)
    #expect(!unit("import Foundation").isTestFile)
  }
}
