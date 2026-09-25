import Foundation

/// `.harness/task-status.json` (spec §5.9): a worker's own, gitignored report that the design it
/// was handed conflicts with what it found. Workers can't edit design, evidence or amendments
/// directly (spec §6.3); the orchestrator reads this file to decide whether to run
/// `/swift-harness:design --amend` and which other tasks move to `needsReplan`.
public struct TaskStatusReport: Sendable, Equatable, Codable {
  /// One conflict finding: a fact the design assumed that turned out false, with the evidence
  /// that refutes it.
  public struct Report: Sendable, Equatable, Codable {
    public let kind: String
    /// The design section anchor the conflict is against (Foundation §9.1 finding location).
    public let section: String
    /// `req-…` / `test-…` ids the finding invalidates.
    public let ids: [String]
    public let claim: String
    /// Uses the same citation shape as a design claim (spec §5.2) so the orchestrator can run
    /// `evidence check` against it before amending anything.
    public let evidence: [Citation]

    public init(kind: String, section: String, ids: [String], claim: String, evidence: [Citation]) {
      self.kind = kind
      self.section = section
      self.ids = ids
      self.claim = claim
      self.evidence = evidence
    }
  }

  public let task: String
  public let state: String
  public let report: Report

  public init(task: String, state: String, report: Report) {
    self.task = task
    self.state = state
    self.report = report
  }
}

/// Encodes `task-status.json` as one pretty-printed, key-sorted object.
public enum TaskStatusReportJSON {
  public static func encode(_ report: TaskStatusReport) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(report)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  public static func decode(_ data: Data) throws -> TaskStatusReport {
    try JSONDecoder().decode(TaskStatusReport.self, from: data)
  }
}
