import Foundation
import SwiftGateDomain

/// One `swiftgate calibrate <suite>`: which agents it runs, where its seeds and pass record live,
/// and which prompt files its content hash covers. The record is committed so every worktree
/// shares one pass (plan Decisions). The harness repository keeps its consumer plugin under
/// `plugin/`, so that's where the prompts and seeds are.
public enum CalibrationSuite: String, Sendable, Equatable, CaseIterable {
  /// Every `plugin/agents/design-*.md` and `plugin/workflows/design-*.js` (spec §6.2).
  case design
  /// `plugin/agents/build-worker.md` and `plugin/agents/build-fixer.md`.
  case build

  public static let pluginDirectory = "plugin"
  public static let agentsDirectory = "\(pluginDirectory)/agents"
  public static let workflowsDirectory = "\(pluginDirectory)/workflows"
  public static let inputFile = "input.md"
  public static let labelFile = "label.json"

  public var seedsDirectory: String {
    "\(Self.pluginDirectory)/gate/Fixtures/calibrate-\(rawValue)"
  }
  public var recordPath: String { "\(seedsDirectory)/last-pass.json" }
  public var command: String { "swiftgate calibrate \(rawValue)" }

  /// The hashed agent files, as a glob or a list, for messages.
  public var agentsDescription: String {
    switch self {
    case .design: "\(Self.agentsDirectory)/design-*.md"
    case .build:
      Self.buildAgents.map { "\(Self.agentsDirectory)/\($0).md" }.joined(separator: " and ")
    }
  }

  static let buildAgents = ["build-fixer", "build-worker"]

  /// Whether a repo-relative path is one of this suite's hashed prompt files. Only direct children
  /// of the agents and workflows directories count.
  public func isHashed(_ repoRelativePath: String) -> Bool {
    for (directory, suffix) in [(Self.agentsDirectory, ".md"), (Self.workflowsDirectory, ".js")]
    where repoRelativePath.hasPrefix(directory + "/") {
      let name = repoRelativePath.dropFirst(directory.count + 1)
      guard !name.contains("/"), name.hasSuffix(suffix) else { return false }
      switch self {
      case .design:
        return name.hasPrefix("design-")
      case .build:
        return directory == Self.agentsDirectory
          && Self.buildAgents.contains(String(name.dropLast(suffix.count)))
      }
    }
    return false
  }

  /// Whether `path` is one of the suite's agent prompts rather than a workflow.
  public func isHashedAgent(_ repoRelativePath: String) -> Bool {
    isHashed(repoRelativePath) && repoRelativePath.hasPrefix("\(Self.agentsDirectory)/")
  }
}

/// Where `calibrate design` reads seeds and writes its pass record, relative to the repository
/// root.
public enum DesignCalibrationLayout {
  public static let pluginDirectory = CalibrationSuite.pluginDirectory
  public static let seedsDirectory = CalibrationSuite.design.seedsDirectory
  public static let recordPath = CalibrationSuite.design.recordPath
  public static let agentsDirectory = CalibrationSuite.agentsDirectory
  public static let workflowsDirectory = CalibrationSuite.workflowsDirectory
  public static let inputFile = CalibrationSuite.inputFile
  public static let labelFile = CalibrationSuite.labelFile
}

/// The content hash a calibration pass is keyed by: each of a suite's prompt files contributes
/// its repo-relative path and the SHA-256 of its bytes, in path order, so an edit, an added or
/// removed file, or a rename all change the hash and discovery order never does.
public enum CalibrationHash {
  public struct File: Sendable, Equatable {
    public let path: String
    public let contents: Data

    public init(path: String, contents: Data) {
      self.path = path
      self.contents = contents
    }
  }

  public static func hash(_ files: [File]) -> String {
    var manifest = ""
    for file in files.sorted(by: { $0.path < $1.path }) {
      manifest += "\(file.path)\0\(CaptureDigest.sha256Hex(file.contents))\n"
    }
    return CaptureDigest.sha256Hex(Data(manifest.utf8))
  }

  /// The suite's hashed files under `root`, sorted by path. A missing agents or workflows
  /// directory contributes nothing; one that exists but can't be listed, or a matched file that
  /// can't be read, throws.
  public static func discover(root: URL, suite: CalibrationSuite) throws -> [File] {
    var files: [File] = []
    for directory in [CalibrationSuite.agentsDirectory, CalibrationSuite.workflowsDirectory] {
      let url = root.appending(path: directory, directoryHint: .isDirectory)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
        let path = "\(directory)/\(name)"
        guard suite.isHashed(path) else { continue }
        files.append(File(path: path, contents: try Data(contentsOf: root.appending(path: path))))
      }
    }
    return files.sorted { $0.path < $1.path }
  }
}

/// ``CalibrationHash`` over the design suite.
public enum DesignCalibrationHash {
  public typealias File = CalibrationHash.File

  public static func isHashed(_ repoRelativePath: String) -> Bool {
    CalibrationSuite.design.isHashed(repoRelativePath)
  }

  public static func hash(_ files: [File]) -> String { CalibrationHash.hash(files) }

  public static func discover(root: URL) throws -> [File] {
    try CalibrationHash.discover(root: root, suite: .design)
  }
}

/// The committed proof that every agent in a suite met every label at one content hash
/// (`last-pass.json`). Written only by a full pass; the push check compares `contentHash` with
/// ``CalibrationHash`` over the working tree.
public struct CalibrationRecord: Sendable, Equatable, Codable {
  public static let currentSchemaVersion = 1

  public struct QuestionResult: Sendable, Equatable, Codable {
    public let question: String
    public let expected: String
    /// The agent's most probable option, or what a build check observed.
    public let answered: String
    /// The option's probability; `1` for a build check, which observes rather than asks.
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
