import SwiftGateRules
import Testing

@Suite("TriviaEquivalence")
struct TriviaEquivalenceTests {
  private static let original = """
    public func isLong(_ fact: String) -> Bool {
      fact.count > 120
    }
    """

  @Test(
    "reindenting, rewrapping and editing comments is trivia-only — catches impact demanding a test change for swift format output"
  )
  func formattingIsTriviaOnly() {
    let reformatted = """
      /// Whether a fact is too long to show.
      public func isLong(
          _ fact: String
      ) -> Bool { fact.count > 120 }  // limit from the design
      """
    #expect(TriviaEquivalence.isTriviaOnlyChange(from: Self.original, to: reformatted))
  }

  @Test(
    "operator, literal, identifier and string-content changes are not trivia-only — catches impact waving a behavior change through"
  )
  func tokenChangesAreNotTriviaOnly() {
    for changed in [
      Self.original.replacingOccurrences(of: ">", with: ">="),
      Self.original.replacingOccurrences(of: "120", with: "121"),
      Self.original.replacingOccurrences(of: "count", with: "utf8.count"),
      #"let s = "a  b""#,
    ] {
      #expect(!TriviaEquivalence.isTriviaOnlyChange(from: Self.original, to: changed))
    }
    #expect(!TriviaEquivalence.isTriviaOnlyChange(from: #"let s = "a b""#, to: #"let s = "a  b""#))
  }

  @Test(
    "a file using #line, #column or #sourceLocation, or that fails to parse, is never trivia-only — catches a moved line number or an unparseable file skipping impact"
  )
  func positionSensitiveOrBrokenSources() {
    for source in [
      "let here = #line",
      "let here = #column",
      "#sourceLocation(file: \"a.swift\", line: 1)\nlet x = 1\n#sourceLocation()",
      "func broken( {",
    ] {
      #expect(!TriviaEquivalence.isTriviaOnlyChange(from: source, to: "\n" + source))
    }
  }
}
