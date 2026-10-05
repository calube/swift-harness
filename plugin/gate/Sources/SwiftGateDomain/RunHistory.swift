import Foundation

/// Run identifiers: `yyyyMMddTHHmmssZ-<hex>`, sortable by start time and safe as a directory name.
public enum RunID {
  public static func make(startedAt date: Date, suffix: UInt32) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    func pad(_ value: Int?, _ width: Int) -> String {
      let text = String(value ?? 0)
      return String(repeating: "0", count: max(0, width - text.count)) + text
    }
    let hex = String(suffix, radix: 16)
    return pad(c.year, 4) + pad(c.month, 2) + pad(c.day, 2) + "T" + pad(c.hour, 2)
      + pad(c.minute, 2) + pad(c.second, 2) + "Z-"
      + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
  }

  /// Rejects anything that could escape `.harness/runs/` when used as a path component.
  public static func isValid(_ runID: String) -> Bool {
    guard let first = runID.unicodeScalars.first, first != ".", first != "-" else { return false }
    return runID.unicodeScalars.allSatisfy {
      $0.isASCII
        && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == ".")
    }
  }
}

/// One line of `.harness/runs/history.jsonl`: the per-run summary `stats` aggregates. Findings stay
/// in the run's own `report.json`.
public struct RunHistoryRecord: Sendable, Equatable, Codable {
  public static let schemaVersion = 1

  public let schemaVersion: Int
  public let runID: String
  /// What ran, for example `lint` or `check fast`. Absent in records written before it existed.
  public let command: String?
  public let finishedAt: Date
  public let verdict: Verdict
  public let durationMilliseconds: Int
  public let tiers: [TierResult]
  public let findingCount: Int
  /// `ready` steps a lower `check` tier added, such as `prove` and `mutate`. Absent when none.
  public let steps: [String]?
  /// The refs `prove` retried compile-only tests at, oldest first. Absent when none.
  public let proofBases: [String]?
  /// The commit `HEAD` was at when the run started. Absent in records written before it existed,
  /// or when the checkout had no commit to name.
  public let headCommit: String?
  /// The commit `--base` resolved to when the run started, so a reader can tell what its diff
  /// was measured from. Absent in records written before it existed, for a command with no
  /// `--base`, or when the ref named no commit.
  public let base: String?
  /// Whether the run started on a tree with uncommitted changes outside the harness's own state.
  /// Absent in records written before it existed, or when git couldn't say.
  public let dirty: Bool?
  /// ``GateReuse/key(_:)`` of the inputs a brownfield tier ran on, so a later run on the same
  /// inputs can answer with this one. Absent for every other run, and when an input was unknown.
  public let reuseKey: String?
  /// The brownfield areas whose tests the run ran, sorted, so `build check-return` can tell a
  /// task's added tests ran. Absent for a run with no area step, and in records written before it
  /// existed.
  public let testedAreas: [String]?

  public init(
    report: RunReport, finishedAt: Date, command: String? = nil, steps: [String]? = nil,
    proofBases: [String]? = nil, headCommit: String? = nil, base: String? = nil,
    dirty: Bool? = nil, reuseKey: String? = nil, testedAreas: [String]? = nil
  ) {
    self.schemaVersion = Self.schemaVersion
    self.runID = report.runID
    self.command = command
    self.finishedAt = finishedAt
    self.verdict = report.verdict
    self.durationMilliseconds = report.durationMilliseconds
    self.tiers = report.tiers
    self.findingCount = report.findings.count
    self.steps = steps
    self.proofBases = proofBases
    self.headCommit = headCommit
    self.base = base
    self.dirty = dirty
    self.reuseKey = reuseKey
    self.testedAreas = testedAreas
  }
}

/// A run's `report.json`: the ``RunReport`` exactly as `--json` prints it, plus the commit the run
/// started at. A reader that decodes only ``RunReport`` ignores the extra key.
public struct RecordedRunReport: Sendable, Equatable {
  public let report: RunReport
  /// `nil` when the checkout had no commit to name, or the report predates the key.
  public let headCommit: String?

  public init(report: RunReport, headCommit: String?) {
    self.report = report
    self.headCommit = headCommit
  }

  private enum CodingKeys: String, CodingKey {
    case headCommit
  }

  /// The same byte-stable formatting as ``RunReportJSON``.
  public static func encode(_ recorded: RecordedRunReport) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(recorded)
  }

  public static func decode(_ data: Data) throws -> RecordedRunReport {
    try JSONDecoder().decode(RecordedRunReport.self, from: data)
  }
}

extension RecordedRunReport: Codable {
  public init(from decoder: any Decoder) throws {
    report = try RunReport(from: decoder)
    headCommit = try decoder.container(keyedBy: CodingKeys.self)
      .decodeIfPresent(String.self, forKey: .headCommit)
  }

  /// Both write into the one top-level object, so the report's own keys stay where they were.
  public func encode(to encoder: any Encoder) throws {
    try report.encode(to: encoder)
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(headCommit, forKey: .headCommit)
  }
}

/// JSON Lines encoding for run history: one compact, newline-terminated object per run.
public enum RunHistoryJSON {
  public static func encodeLine(_ record: RunHistoryRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(record)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  /// Decodes every line. Lines that are not a valid record (for example one torn by a crash
  /// mid-write) are counted rather than failing the whole history.
  public static func decode(_ data: Data) -> (records: [RunHistoryRecord], invalidLines: Int) {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var records: [RunHistoryRecord] = []
    var invalid = 0
    for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
      if let record = try? decoder.decode(RunHistoryRecord.self, from: Data(line)),
        record.schemaVersion == RunHistoryRecord.schemaVersion
      {
        records.append(record)
      } else {
        invalid += 1
      }
    }
    return (records, invalid)
  }
}
