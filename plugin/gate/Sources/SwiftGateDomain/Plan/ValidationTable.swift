import Foundation

/// The layer a validation row checks at. `unit` is not one: each task's own tests prove its unit
/// behaviour, so the table never lists them.
public enum ValidationLayer: String, Sendable, Equatable, Codable, CaseIterable {
  /// Behaviour at a boundary: an API, a CLI, or the module that joins 2 tasks.
  case acceptance
  /// A user journey in the running app.
  case flow
  /// The result the app persisted or sent, read straight after its flow.
  case state
}

/// 1 row of a plan's validation table: 1 check for 1 requirement.
public struct ValidationRow: Sendable, Equatable, Codable {
  /// A `## Requirements` id, by convention `req-<name>`.
  public let requirement: String
  public let layer: ValidationLayer
  /// The command, test name or file the row runs.
  public let check: String
  /// Ledger task ids; the row runs once every one has merged.
  public let runsAfter: [String]
  /// The ledger task that writes the check.
  public let writer: String
  /// `nil` when the row states none.
  public let reason: String?

  public init(
    requirement: String, layer: ValidationLayer, check: String, runsAfter: [String],
    writer: String, reason: String? = nil
  ) {
    self.requirement = requirement
    self.layer = layer
    self.check = check
    self.runsAfter = runsAfter
    self.writer = writer
    self.reason = reason
  }
}

/// A requirement the plan leaves to its tasks' unit tests, with the reason it needs no other check.
public struct ValidationUnitOnly: Sendable, Equatable, Codable {
  public let requirement: String
  public let reason: String

  public init(requirement: String, reason: String) {
    self.requirement = requirement
    self.reason = reason
  }
}

/// A plan's validation table, stored as `validation.json` beside `ledger.json`.
public struct ValidationTable: Sendable, Equatable, Codable {
  public static let fileName = "validation.json"
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let rows: [ValidationRow]
  public let unitOnly: [ValidationUnitOnly]

  public init(
    schemaVersion: Int = ValidationTable.currentSchemaVersion, rows: [ValidationRow],
    unitOnly: [ValidationUnitOnly] = []
  ) {
    self.schemaVersion = schemaVersion
    self.rows = rows
    self.unitOnly = unitOnly
  }
}

/// Why a `validation.json` can't be read as a table.
public enum ValidationTableJSONError: Error, Sendable, Equatable {
  case unsupportedSchemaVersion(Int)
  case malformed(String)
}

public enum ValidationTableJSON {
  public static func encode(_ table: ValidationTable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(table)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  public static func decode(_ data: Data) throws(ValidationTableJSONError) -> ValidationTable {
    do {
      return try JSONDecoder().decode(ValidationTable.self, from: data)
    } catch {
      throw .malformed("\(error)")
    }
  }
}

/// A `PLAN.md`'s `## Validation` section as parsed, with the line each entry came from so a
/// finding can name it.
public struct LivePlanValidation: Sendable, Equatable {
  public let table: ValidationTable
  /// The 1-based line of the `## Validation` heading.
  public let headingLine: Int
  /// The line of each of `table.rows`, in order.
  public let rowLines: [Int]

  public init(table: ValidationTable, headingLine: Int, rowLines: [Int]) {
    self.table = table
    self.headingLine = headingLine
    self.rowLines = rowLines
  }
}
