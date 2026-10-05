import Foundation

/// `at-base-run.json` in a validation worker's prepared `qa/` folder: what its `qa run --at-base
/// --prepared-by` run showed for each row, with the digest of the check each row ran. `qa adopt`
/// copies it into plan state beside the checks, and the orchestrator's `qa run --at-base` takes a
/// row's recorded result in place of running it again when the adopted check has that digest.
public struct QAAtBaseRun: Sendable, Equatable {
  public static let fileName = "at-base-run.json"
  public static let currentSchemaVersion = 1

  /// 1 row as the prepared run left it.
  public struct Row: Sendable, Equatable, Codable {
    public let requirement: String
    public let layer: ValidationLayer
    public let check: String
    /// ``QAAtBaseRun/digest(layer:check:file:)`` of the check the row ran.
    public let digest: String
    public let result: QAResult
    public let message: String
    public let exitStatus: Int?
    public let milliseconds: Int

    public init(
      requirement: String, layer: ValidationLayer, check: String, digest: String,
      result: QAResult, message: String, exitStatus: Int?, milliseconds: Int
    ) {
      self.requirement = requirement
      self.layer = layer
      self.check = check
      self.digest = digest
      self.result = result
      self.message = message
      self.exitStatus = exitStatus
      self.milliseconds = milliseconds
    }

    private enum CodingKeys: String, CodingKey {
      case requirement, layer, check, digest, result, message, exitStatus
      case milliseconds = "ms"
    }
  }

  public let schemaVersion: Int
  /// The prepared run's id, which each reused row names.
  public let runID: String
  /// The task the run's `--prepared-by` named.
  public let preparedBy: String
  /// The merge base the rows ran at.
  public let commit: String?
  public let rows: [Row]

  public init(runID: String, preparedBy: String, commit: String?, rows: [Row]) {
    self.schemaVersion = Self.currentSchemaVersion
    self.runID = runID
    self.preparedBy = preparedBy
    self.commit = commit
    self.rows = rows
  }

  /// The record of a prepared run's `rows`, each with the digest its check had when it ran.
  /// A row with no digest in `digests` is left out, so it never matches.
  public init(
    runID: String, preparedBy: String, commit: String?, rows: [QARow], digests: [Int: String]
  ) {
    self.init(
      runID: runID, preparedBy: preparedBy, commit: commit,
      rows: rows.compactMap { row in
        digests[row.row].map { digest in
          Row(
            requirement: row.requirement, layer: row.layer, check: row.check, digest: digest,
            result: row.result, message: row.message, exitStatus: row.exitStatus,
            milliseconds: row.milliseconds)
        }
      })
  }

  /// Lowercase hex SHA-256 over the row's layer, its check's text and, when the check names a
  /// file, that file's bytes: 2 checks with the same digest are byte-identical.
  public static func digest(layer: ValidationLayer, check: String, file: Data?) -> String {
    var bytes = Data("\(layer.rawValue)\0\(check)\0".utf8)
    if let file {
      bytes.append(UInt8(ascii: "f"))
      bytes.append(file)
    } else {
      bytes.append(UInt8(ascii: "-"))
    }
    return CaptureDigest.sha256Hex(bytes)
  }

  /// What a run at the merge base takes from this record, and why each other row runs.
  public struct Reuse: Sendable, Equatable {
    /// The recorded outcome of each reused row, by row.
    public let outcomes: [Int: QACheckOutcome]
    /// Why each ready row that isn't reused runs, by row.
    public let reasons: [Int: String]
  }

  /// The ready rows of `plan` this record proves: a row whose requirement, layer, check text and
  /// digest in `digests` match a recorded row that read `pass` or `red`. A flow row and the state
  /// rows that run on its device are reused together or not at all, since a state check reads
  /// what its flow left on a device that only a run of that flow brings up.
  public func reuse(in plan: QARunPlan, digests: [Int: String]) -> Reuse {
    Reuse(outcomes: [:], reasons: [:])
  }
}

extension QAAtBaseRun: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, runID, preparedBy, commit, rows
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let version = try c.decode(Int.self, forKey: .schemaVersion)
    guard version == Self.currentSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: c, debugDescription: "unsupported schemaVersion \(version)")
    }
    self.init(
      runID: try c.decode(String.self, forKey: .runID),
      preparedBy: try c.decode(String.self, forKey: .preparedBy),
      commit: try c.decodeIfPresent(String.self, forKey: .commit),
      rows: try c.decode([Row].self, forKey: .rows))
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(schemaVersion, forKey: .schemaVersion)
    try c.encode(runID, forKey: .runID)
    try c.encode(preparedBy, forKey: .preparedBy)
    try c.encode(commit, forKey: .commit)
    try c.encode(rows, forKey: .rows)
  }
}

public enum QAAtBaseRunJSON {
  public static func encode(_ record: QAAtBaseRun) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(record)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  public static func decode(_ data: Data) throws -> QAAtBaseRun {
    try JSONDecoder().decode(QAAtBaseRun.self, from: data)
  }
}
