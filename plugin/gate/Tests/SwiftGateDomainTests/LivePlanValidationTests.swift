import Foundation
import SwiftGateDomain
import Testing

/// A plan with 3 requirements and 2 tasks; `rows` is the body of its `## Validation` table, under
/// the header and separator lines.
private func plan(rows: String) -> String {
  """
  # Offline drafts

  ## Requirements
  - req-draft-list: Show every saved draft
  - req-offline-save: Save a draft without a network
  - req-draft-sync: Sync a saved draft on the next launch

  ## Validation

  | Done when | Layer | Check | Runs after | Writer | Reason |
  |---|---|---|---|---|---|
  \(rows)

  ## Assumptions
  - A draft syncs on the next launch with a network.

  ### draft-list
  List the saved drafts.
  - Deps: none · Gate: slice · estLines: 60
  - Covers: req-draft-list, req-draft-sync
  - Writes: `app/drafts/list/`

  ### save-queue
  Queue a save made offline.
  - Deps: draft-list · Gate: slice · estLines: 120
  - Covers: req-offline-save
  - Writes: `app/drafts/queue/`
  """
}

private let cleanRows = """
  | `req-draft-list` | acceptance | `curl -fsS localhost:$QA_PORT/drafts \\| jq -e 'length == 2'` | draft-list | save-queue | |
  | req-offline-save | flow | `qa/offline-save.flow.json` | draft-list, `save-queue` | save-queue | |
  | req-offline-save | state | `qa/offline-save.state.sh` | draft-list, save-queue | save-queue | reads the stored draft file |
  | req-draft-sync | | | | | the sync test in draft-list covers it |
  """

/// The 1-based line of the first line of `text` that contains `needle`.
private func line(of needle: String, in text: String) -> Int? {
  text.split(separator: "\n", omittingEmptySubsequences: false).firstIndex {
    $0.contains(needle)
  }.map { $0 + 1 }
}

@Suite("Live plan validation table")
struct LivePlanValidationTests {
  @Test(
    "a Validation table's rows import with their layer, unwrapped check, Runs after ids, writer and reason, and a reason-only row as unit-only — catches a dropped row or a check left in backticks"
  )
  func importsRows() throws {
    let text = plan(rows: cleanRows)
    let validation = try #require(try LivePlanParser.parse(text).validation)
    #expect(
      validation.table.rows == [
        ValidationRow(
          requirement: "req-draft-list", layer: .acceptance,
          check: "curl -fsS localhost:$QA_PORT/drafts | jq -e 'length == 2'",
          runsAfter: ["draft-list"], writer: "save-queue"),
        ValidationRow(
          requirement: "req-offline-save", layer: .flow, check: "qa/offline-save.flow.json",
          runsAfter: ["draft-list", "save-queue"], writer: "save-queue"),
        ValidationRow(
          requirement: "req-offline-save", layer: .state, check: "qa/offline-save.state.sh",
          runsAfter: ["draft-list", "save-queue"], writer: "save-queue",
          reason: "reads the stored draft file"),
      ])
    #expect(
      validation.table.unitOnly == [
        ValidationUnitOnly(
          requirement: "req-draft-sync", reason: "the sync test in draft-list covers it")
      ])
    #expect(validation.headingLine == line(of: "## Validation", in: text))
    #expect(
      validation.rowLines
        == [
          line(of: "| `req-draft-list`", in: text), line(of: "| flow |", in: text),
          line(of: "| state |", in: text),
        ].compactMap { $0 })
  }

  @Test(
    "a row whose layer is unit fails naming its line and the 3 layers — catches a layer read as free text"
  )
  func unitLayerFails() {
    let text = plan(rows: "| req-draft-list | unit | `DraftTests` | draft-list | draft-list | |")
    let error = #expect(throws: LivePlanError.self) { try LivePlanParser.parse(text) }
    guard case .invalidValidation(let at, let reason) = error else {
      Issue.record("expected invalidValidation, got \(String(describing: error))")
      return
    }
    #expect(at == line(of: "| unit |", in: text))
    #expect(reason.contains("`unit`"))
    #expect(reason.contains("acceptance, flow or state"))
    #expect(error?.message.contains("line \(at)") == true)
  }

  @Test(
    "a row naming an id Requirements doesn't list fails naming the line and the id — catches a misspelled requirement read as a check"
  )
  func unknownRequirementFails() {
    let text = plan(
      rows: "| req-draft-lsit | acceptance | `DraftTests` | draft-list | draft-list | |")
    let error = #expect(throws: LivePlanError.self) { try LivePlanParser.parse(text) }
    #expect(
      error
        == .invalidValidation(
          line: line(of: "req-draft-lsit", in: text) ?? 0,
          reason: "`req-draft-lsit` is not a `## Requirements` id"))
  }

  @Test(
    "a check row with an empty Check, Runs after or Writer fails naming the empty column, and a reason-only row needs its reason — catches a row that can never run"
  )
  func emptyCellsFail() {
    let cases = [
      ("| req-draft-list | acceptance | | draft-list | draft-list | |", "Check"),
      ("| req-draft-list | acceptance | `DraftTests` | | draft-list | |", "Runs after"),
      ("| req-draft-list | acceptance | `DraftTests` | draft-list | | |", "Writer"),
      ("| req-draft-list | | | | | |", "Reason"),
      ("| req-draft-list | | `DraftTests` | | | covered by unit tests |", "Check"),
    ]
    for (row, column) in cases {
      let error = #expect(throws: LivePlanError.self, "\(row)") {
        try LivePlanParser.parse(plan(rows: row))
      }
      guard case .invalidValidation(_, let reason) = error else {
        Issue.record("\(row): expected invalidValidation, got \(String(describing: error))")
        continue
      }
      #expect(reason.contains("`\(column)`"), "\(row): \(reason)")
    }
  }

  @Test(
    "a table without the Done when column, or a row with a cell too few, fails naming the line — catches a table read by column position alone"
  )
  func malformedTableFails() {
    let missingColumn = plan(rows: "").replacingOccurrences(of: "| Done when ", with: "| Done ")
    let headerError = #expect(throws: LivePlanError.self) {
      try LivePlanParser.parse(missingColumn)
    }
    #expect(
      headerError?.message.contains("line \(line(of: "| Done |", in: missingColumn) ?? 0)")
        == true)
    #expect(headerError?.message.contains("`Done when`") == true)

    let short = plan(rows: "| req-draft-list | acceptance | `DraftTests` | draft-list |")
    let rowError = #expect(throws: LivePlanError.self) { try LivePlanParser.parse(short) }
    #expect(
      rowError?.message.contains("line \(line(of: "| draft-list |", in: short) ?? 0)") == true)
  }

  @Test(
    "a plan with no Validation section parses with no table, and its tasks unchanged — catches a missing section read as an empty table"
  )
  func noSectionIsNil() throws {
    let text = plan(rows: cleanRows)
    let start = try #require(text.range(of: "## Validation"))
    let end = try #require(text.range(of: "## Assumptions"))
    let without = text.replacingCharacters(in: start.lowerBound..<end.lowerBound, with: "")
    let parsed = try LivePlanParser.parse(without)
    #expect(parsed.validation == nil)
    let withSection = try LivePlanParser.parse(text)
    #expect(withSection.validation?.table.rows.count == 3)
    #expect(parsed.tasks == withSection.tasks)
  }

  @Test(
    "a second Validation section, a section with no table and a header with no separator each fail naming their line, and a validation.json that isn't JSON fails decoding — catches a malformed section read as no rows"
  )
  func sectionShapeFails() throws {
    let text = plan(rows: cleanRows)
    let twice = text.replacingOccurrences(
      of: "## Assumptions", with: "## Validation\n\nRepeated.\n\n## Assumptions")
    let second = #expect(throws: LivePlanError.self) { try LivePlanParser.parse(twice) }
    let secondHeading = twice.split(separator: "\n", omittingEmptySubsequences: false)
      .lastIndex { $0 == "## Validation" }.map { $0 + 1 }
    #expect(
      second
        == .invalidValidation(line: secondHeading ?? 0, reason: "a second `## Validation` section"))

    let tableStart = try #require(text.range(of: "| Done when"))
    let tableEnd = try #require(text.range(of: "## Assumptions"))
    let empty = text.replacingCharacters(in: tableStart.lowerBound..<tableEnd.lowerBound, with: "")
    let noTable = #expect(throws: LivePlanError.self) { try LivePlanParser.parse(empty) }
    #expect(noTable?.message.contains("line \(line(of: "## Validation", in: empty) ?? 0)") == true)
    #expect(noTable?.message.contains("no table") == true)

    let unseparated = text.replacingOccurrences(of: "|---|---|---|---|---|---|\n", with: "")
    let noSeparator = #expect(throws: LivePlanError.self) { try LivePlanParser.parse(unseparated) }
    #expect(noSeparator?.message.contains("separator") == true)

    #expect(throws: ValidationTableJSONError.self) {
      try ValidationTableJSON.decode(Data("not json".utf8))
    }
  }

  @Test(
    "validation.json round-trips its rows and unit-only entries, and a schemaVersion other than 1 fails decoding naming it — catches a table from a newer harness read as this one"
  )
  func jsonRoundTrip() throws {
    let table = try #require(try LivePlanParser.parse(plan(rows: cleanRows)).validation).table
    #expect(try ValidationTableJSON.decode(ValidationTableJSON.encode(table)) == table)
    let newer = ValidationTable(schemaVersion: 2, rows: table.rows, unitOnly: table.unitOnly)
    let error = #expect(throws: ValidationTableJSONError.self) {
      try ValidationTableJSON.decode(ValidationTableJSON.encode(newer))
    }
    #expect(error == .unsupportedSchemaVersion(2))
    let unknownLayer = Data(
      String(decoding: try ValidationTableJSON.encode(table), as: UTF8.self)
        .replacingOccurrences(of: "\"flow\"", with: "\"unit\"").utf8)
    #expect(throws: ValidationTableJSONError.self) { try ValidationTableJSON.decode(unknownLayer) }
  }
}
