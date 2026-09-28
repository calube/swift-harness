import Foundation
import SwiftGateDomain
import Testing

@Suite("sprint.json")
struct SprintRunJSONTests {
  /// `sprint.json` after slice 2 of 3, as the store writes it. Sprint commands and status read
  /// these exact keys.
  static let slicingTwo = """
    {
      "baseCommit" : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "branch" : "sprint/notes-search",
      "schemaVersion" : 1,
      "slices" : [
        {
          "gateRun" : "20260927T231701Z-cb69701e",
          "number" : 1,
          "status" : "passed"
        },
        {
          "gateRun" : "20260927T231702Z-cb69701e",
          "number" : 2,
          "status" : "passed"
        },
        {
          "number" : 3,
          "status" : "pending"
        }
      ],
      "slug" : "notes-search",
      "specPage" : "docs/sprints/notes-search.md",
      "step" : {
        "name" : "slicing",
        "slice" : 2
      },
      "surfaceCommit" : "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }

    """

  @Test(
    "a run after slice 2 encodes to the documented keys and layout — catches a key renamed under the sprint commands"
  )
  func encodesDocumentedLayout() throws {
    let run = try #require(try SprintFixtures.run(after: 4))
    #expect(String(decoding: try SprintRunJSON.encode(run), as: UTF8.self) == Self.slicingTwo)
  }

  @Test(
    "every step decodes to the run that was encoded and re-encodes to the same bytes — catches a field lost or reordered across a write",
    arguments: 1...6)
  func roundTripIsByteStable(events: Int) throws {
    let run = try #require(try SprintFixtures.run(after: events))
    let bytes = try SprintRunJSON.encode(run)
    let decoded = try SprintRunJSON.decode(bytes)
    #expect(decoded == run)
    #expect(try SprintRunJSON.encode(decoded) == bytes)
  }

  @Test(
    "a decoded file still takes the next legal step — catches a decoded run the state machine treats differently from a live one"
  )
  func decodedRunContinues() throws {
    let decoded = try SprintRunJSON.decode(Data(Self.slicingTwo.utf8))
    #expect(decoded.next == .slice(3))
    let next = try SprintTransition.apply(
      .slice(3, gateRun: SprintFixtures.gateRun(3)), to: decoded)
    #expect(next.step == .slicing(3))
  }

  @Test(
    "an unknown step fails decoding and names it — catches a step outside the state machine read as some other step"
  )
  func unknownStepFails() {
    let file = Self.slicingTwo.replacingOccurrences(
      of: "\"name\" : \"slicing\"", with: "\"name\" : \"reviewing\"")
    let error = #expect(throws: SprintRunJSONError.self) {
      try SprintRunJSON.decode(Data(file.utf8))
    }
    guard case .invalid(let field, let reason) = error else {
      Issue.record("expected an invalid field, got \(String(describing: error))")
      return
    }
    #expect(field == "step.name")
    #expect(reason.contains("reviewing"))
    #expect(error?.message.contains("step.name") == true)
  }

  /// Each edit of the valid file and the field its error must name.
  static let malformed: [(label: String, from: String, to: String, field: String)] = [
    ("slice status", "\"status\" : \"pending\"", "\"status\" : \"done\"", "slices[2].status"),
    (
      "empty surface sha", "\"surfaceCommit\" : \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"",
      "\"surfaceCommit\" : \"\"", "surfaceCommit"
    ),
    (
      "branch name as base", "\"baseCommit\" : \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"",
      "\"baseCommit\" : \"main\"", "baseCommit"
    ),
    ("schema version", "\"schemaVersion\" : 1", "\"schemaVersion\" : 2", "schemaVersion"),
    ("unknown key", "\"schemaVersion\" : 1", "\"schemaVersion\" : 1, \"notes\" : \"x\"", "notes"),
    ("slice zero", "\"slice\" : 2", "\"slice\" : 0", "step.slice"),
    ("step ahead of slices", "\"slice\" : 2", "\"slice\" : 3", "step"),
    (
      "slicing step missing its slice", "\"name\" : \"slicing\",\n    \"slice\" : 2",
      "\"name\" : \"slicing\"", "step.slice"
    ),
    ("branch not the slug's", "\"sprint/notes-search\"", "\"sprint/other\"", "branch"),
    ("slice numbering", "\"number\" : 3", "\"number\" : 4", "slices[2].number"),
    (
      "passed slice without a gate run", "\"gateRun\" : \"20260927T231702Z-cb69701e\",", "",
      "slices[1].gateRun"
    ),
    (
      "finished step with a slice", "\"name\" : \"slicing\"", "\"name\" : \"finished\"",
      "step.slice"
    ),
    (
      "finished step without a final run", "\"name\" : \"slicing\",\n    \"slice\" : 2",
      "\"name\" : \"finished\"", "step"
    ),
    ("missing slug", "\"slug\" : \"notes-search\",", "", "slug"),
  ]

  @Test(
    "a malformed field fails decoding and names the field — catches a hand-edited or torn sprint.json read as a valid run",
    arguments: 0..<14)
  func malformedFieldFails(index: Int) throws {
    let edit = Self.malformed[index]
    let file = Self.slicingTwo.replacingOccurrences(of: edit.from, with: edit.to)
    try #require(file != Self.slicingTwo, "\(edit.label) edit didn't apply")
    let error = #expect(throws: SprintRunJSONError.self, "\(edit.label)") {
      try SprintRunJSON.decode(Data(file.utf8))
    }
    guard case .invalid(let field, _) = error else {
      Issue.record("\(edit.label): expected an invalid field, got \(String(describing: error))")
      return
    }
    #expect(field == edit.field, "\(edit.label)")
  }

  @Test("a file that isn't JSON fails as not JSON — catches a torn file read as an empty run")
  func notJSONFails() {
    let error = #expect(throws: SprintRunJSONError.self) {
      try SprintRunJSON.decode(Data("{\"slug\" : ".utf8))
    }
    guard case .notJSON(let detail) = error else {
      Issue.record("expected not JSON, got \(String(describing: error))")
      return
    }
    #expect(!detail.isEmpty)
  }
}
