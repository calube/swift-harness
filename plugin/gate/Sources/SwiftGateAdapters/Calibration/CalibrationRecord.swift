import Foundation
import SwiftGateDomain

/// Where `calibrate design` reads seeds and writes its pass record, relative to the repository
/// root. The record is committed so every worktree shares one pass (plan Decisions). The harness
/// repository keeps its consumer plugin under `plugin/`, so that's where the prompts and seeds are.
public enum DesignCalibrationLayout {
  public static let pluginDirectory = "plugin"
  public static let seedsDirectory = "\(pluginDirectory)/gate/Fixtures/calibrate-design"
  public static let recordPath = "\(seedsDirectory)/last-pass.json"
  public static let agentsDirectory = "\(pluginDirectory)/agents"
  public static let workflowsDirectory = "\(pluginDirectory)/workflows"
  public static let inputFile = "input.md"
  public static let labelFile = "label.json"
}

/// The content hash a calibration pass is keyed by: every `plugin/agents/design-*.md` and
/// `plugin/workflows/design-*.js` (spec §6.2). Each file contributes its repo-relative path and the
/// SHA-256 of its bytes, in path order, so an edit, an added or removed file, or a rename all
/// change the hash and discovery order never does.
public enum DesignCalibrationHash {
  public struct File: Sendable, Equatable {
    public let path: String
    public let contents: Data

    public init(path: String, contents: Data) {
      self.path = path
      self.contents = contents
    }
  }

  /// Whether a repo-relative path is one of the hashed prompt files. Only direct children count.
  public static func isHashed(_ repoRelativePath: String) -> Bool {
    for (directory, suffix) in [
      (DesignCalibrationLayout.agentsDirectory, ".md"),
      (DesignCalibrationLayout.workflowsDirectory, ".js"),
    ] where repoRelativePath.hasPrefix(directory + "/") {
      let name = repoRelativePath.dropFirst(directory.count + 1)
      return !name.contains("/") && name.hasPrefix("design-") && name.hasSuffix(suffix)
    }
    return false
  }

  public static func hash(_ files: [File]) -> String {
    var manifest = ""
    for file in files.sorted(by: { $0.path < $1.path }) {
      manifest += "\(file.path)\0\(CaptureDigest.sha256Hex(file.contents))\n"
    }
    return CaptureDigest.sha256Hex(Data(manifest.utf8))
  }

  /// The hashed files under `root`, sorted by path. A missing agents or workflows
  /// directory contributes nothing; one that exists but can't be listed, or a matched file that
  /// can't be read, throws.
  public static func discover(root: URL) throws -> [File] {
    var files: [File] = []
    for directory in [
      DesignCalibrationLayout.agentsDirectory, DesignCalibrationLayout.workflowsDirectory,
    ] {
      let url = root.appending(path: directory, directoryHint: .isDirectory)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
        let path = "\(directory)/\(name)"
        guard isHashed(path) else { continue }
        files.append(File(path: path, contents: try Data(contentsOf: root.appending(path: path))))
      }
    }
    return files.sorted { $0.path < $1.path }
  }
}

/// The committed proof that every design agent met every label at one content hash
/// (`last-pass.json`). Written only by a full pass; the push check compares `contentHash` with
/// ``DesignCalibrationHash`` over the working tree.
public struct CalibrationRecord: Sendable, Equatable, Codable {
  public static let currentSchemaVersion = 1

  public struct QuestionResult: Sendable, Equatable, Codable {
    public let question: String
    public let expected: String
    /// The agent's most probable option.
    public let answered: String
    public let probability: Double

    public init(question: String, expected: String, answered: String, probability: Double) {
      self.question = question
      self.expected = expected
      self.answered = answered
      self.probability = probability
    }
  }

  public struct CaseResult: Sendable, Equatable, Codable {
    public let agent: String
    public let caseName: String
    public let answers: [QuestionResult]

    public init(agent: String, caseName: String, answers: [QuestionResult]) {
      self.agent = agent
      self.caseName = caseName
      self.answers = answers
    }

    private enum CodingKeys: String, CodingKey {
      case agent
      case caseName = "case"
      case answers
    }
  }

  public let schemaVersion: Int
  public let contentHash: String
  public let hashedFiles: [String]
  public let model: String
  public let passedAt: Date
  public let cases: [CaseResult]

  public init(
    contentHash: String, hashedFiles: [String], model: String, passedAt: Date,
    cases: [CaseResult]
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.contentHash = contentHash
    self.hashedFiles = hashedFiles
    self.model = model
    self.passedAt = passedAt
    self.cases = cases
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, contentHash, hashedFiles, model, passedAt, cases
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .schemaVersion)
    guard version == Self.currentSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: container,
        debugDescription: "unsupported calibration record schemaVersion \(version)")
    }
    schemaVersion = version
    contentHash = try container.decode(String.self, forKey: .contentHash)
    hashedFiles = try container.decode([String].self, forKey: .hashedFiles)
    model = try container.decode(String.self, forKey: .model)
    passedAt = try container.decode(Date.self, forKey: .passedAt)
    cases = try container.decode([CaseResult].self, forKey: .cases)
  }

  /// Pretty, key-sorted JSON with ISO 8601 dates and a trailing newline, so a re-pass diffs
  /// cleanly in review.
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self) + Data("\n".utf8)
  }

  public static func decode(_ data: Data) throws -> CalibrationRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CalibrationRecord.self, from: data)
  }
}
