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

/// Which model a calibrated agent runs on. Every agent is calibrated on the model its
/// frontmatter names, so the pass measures the agent as it ships; an agent that pins none runs on
/// ``unpinned``. A `--model` override exists for experiments, and a pass made with one is never
/// fresh.
public enum CalibrationModel {
  public static let unpinned = JudgeFactory.defaultModel

  /// The model an agent ships on, given its frontmatter's `model`.
  public static func shipped(frontmatterModel: String?) -> String {
    frontmatterModel ?? unpinned
  }
}

/// What one kept reply says a requested model resolved to, read from its `<seed>.json`.
public struct ServedModelObservation: Sendable, Equatable {
  public let requestedModel: String
  public let servedModels: [String]
  /// The run that kept it; its id starts with the time it began.
  public let runID: String
  /// The kept file, relative to the repository root.
  public let path: String

  public init(requestedModel: String, servedModels: [String], runID: String, path: String) {
    self.requestedModel = requestedModel
    self.servedModels = servedModels
    self.runID = runID
    self.path = path
  }
}

/// Reads an agent file's leading `---` frontmatter block.
public enum AgentFrontmatter {
  /// A top-level `key: value` line of the frontmatter, trimmed; `nil` when absent or empty.
  public static func value(_ key: String, in text: String) -> String? {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard let frontmatter = closingRange(normalized) else { return nil }
    for line in normalized[..<frontmatter.lowerBound].split(separator: "\n")
    where line.hasPrefix("\(key):") {
      let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
      return value.isEmpty ? nil : value
    }
    return nil
  }

  /// Strips a leading frontmatter block, then surrounding blank lines.
  public static func body(of text: String) -> String {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    var body = Substring(normalized)
    if let frontmatter = closingRange(normalized) {
      body = normalized[frontmatter.upperBound...]
    }
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The closing `\n---\n` of a leading frontmatter block.
  private static func closingRange(_ normalized: String) -> Range<String.Index>? {
    guard normalized.hasPrefix("---\n") else { return nil }
    return normalized.range(
      of: "\n---\n",
      range: normalized.index(normalized.startIndex, offsetBy: 3)..<normalized.endIndex)
  }
}

/// The committed proof that every agent in a suite met every label at one content hash
/// (`last-pass.json`), each case on the model it ran on. Written only by a full pass; the push
/// check compares `contentHash` with ``CalibrationHash`` over the working tree and each case's
/// model with its agent's frontmatter.
public struct CalibrationRecord: Sendable, Equatable, Codable {
  /// Version 3 added each case's served models and the judge; a version 2 record still reads.
  public static let currentSchemaVersion = 3
  public static let readableSchemaVersions: Set<Int> = [2, 3]

  public struct QuestionResult: Sendable, Equatable, Codable {
    /// A judged answer counts only at this probability or above, so a coin-flip answer that
    /// happens to land on the label fails instead of passing by luck.
    public static let passMargin = 0.7

    public let question: String
    public let expected: String
    /// The agent's most probable option, or what a check of its output observed.
    public let answered: String
    /// The option's probability; `1` for a check that observes rather than asks.
    public let probability: Double

    public init(question: String, expected: String, answered: String, probability: Double) {
      self.question = question
      self.expected = expected
      self.answered = answered
      self.probability = probability
    }

    public var met: Bool { answered == expected && probability >= Self.passMargin }
  }

  public struct CaseResult: Sendable, Equatable, Codable {
    public let agent: String
    public let caseName: String
    /// The model the agent was asked to run on, often an alias such as `opus`.
    public let model: String
    /// The ids the CLI says answered, which an alias can move between; `nil` when not recorded.
    public let servedModels: [String]?
    /// The answers of the attempt that decided the case.
    public let answers: [QuestionResult]
    /// How each attempt went, in order, such as `[miss, pass, pass]`; `nil` in a record from
    /// before attempts were recorded, when every case had one.
    public let attempts: [CalibrationAttemptOutcome]?

    public init(
      agent: String, caseName: String, model: String, servedModels: [String]? = nil,
      answers: [QuestionResult], attempts: [CalibrationAttemptOutcome]? = nil
    ) {
      self.agent = agent
      self.caseName = caseName
      self.model = model
      self.servedModels = servedModels
      self.answers = answers
      self.attempts = attempts
    }

    private enum CodingKeys: String, CodingKey {
      case agent
      case caseName = "case"
      case model
      case servedModels
      case answers
      case attempts
    }
  }

  /// The judge that answered the pass's judged labels.
  public struct JudgeRecord: Sendable, Equatable, Codable {
    public let backend: JudgeBackend
    /// The model the judge was asked for.
    public let model: String
    /// The ids that answered; `nil` when not recorded.
    public let servedModels: [String]?

    /// The judge `calibrate design` uses unless told otherwise.
    public static let shipped = JudgeRecord(
      backend: .claude, model: JudgeFactory.defaultModel, servedModels: nil)

    public init(backend: JudgeBackend, model: String, servedModels: [String]?) {
      self.backend = backend
      self.model = model
      self.servedModels = servedModels
    }

    /// `backend/model`, as messages name a judge.
    public var name: String { "\(backend.rawValue)/\(model)" }

    /// Whether this is the judge the command ships with, whatever ids served it.
    public var isShipped: Bool { backend == Self.shipped.backend && model == Self.shipped.model }

    private enum CodingKeys: String, CodingKey {
      case backend, model, servedModels
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let raw = try container.decode(String.self, forKey: .backend)
      guard let backend = JudgeBackend(rawValue: raw) else {
        throw DecodingError.dataCorruptedError(
          forKey: .backend, in: container, debugDescription: "unknown judge backend `\(raw)`")
      }
      self.backend = backend
      model = try container.decode(String.self, forKey: .model)
      servedModels = try container.decodeIfPresent([String].self, forKey: .servedModels)
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(backend.rawValue, forKey: .backend)
      try container.encode(model, forKey: .model)
      try container.encodeIfPresent(servedModels, forKey: .servedModels)
    }
  }

  public let schemaVersion: Int
  public let contentHash: String
  public let hashedFiles: [String]
  /// The `--model` every agent ran on instead of its own; `nil` for a pass on shipped models.
  public let modelOverride: String?
  public let passedAt: Date
  public let cases: [CaseResult]
  /// The judge of the pass's judged labels; `nil` for a suite with no judge, or a record from
  /// before the judge was recorded, when only the shipped judge could run.
  public let judge: JudgeRecord?

  public init(
    contentHash: String, hashedFiles: [String], modelOverride: String?, passedAt: Date,
    cases: [CaseResult], judge: JudgeRecord? = nil
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.contentHash = contentHash
    self.hashedFiles = hashedFiles
    self.modelOverride = modelOverride
    self.passedAt = passedAt
    self.cases = cases
    self.judge = judge
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, contentHash, hashedFiles, modelOverride, passedAt, cases, judge
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .schemaVersion)
    guard Self.readableSchemaVersions.contains(version) else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: container,
        debugDescription: "unsupported calibration record schemaVersion \(version)")
    }
    schemaVersion = version
    contentHash = try container.decode(String.self, forKey: .contentHash)
    hashedFiles = try container.decode([String].self, forKey: .hashedFiles)
    modelOverride = try container.decodeIfPresent(String.self, forKey: .modelOverride)
    passedAt = try container.decode(Date.self, forKey: .passedAt)
    cases = try container.decode([CaseResult].self, forKey: .cases)
    judge = version >= 3 ? try container.decodeIfPresent(JudgeRecord.self, forKey: .judge) : nil
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

  /// Why an alias this record ran on no longer serves what it served in the pass: for each
  /// requested model, the newest observation from a run started at or after ``passedAt`` whose
  /// served ids differ from the recorded ones. Empty when nothing newer disagrees.
  public func servedModelProblems(observed: [ServedModelObservation]) -> [String] {
    var recorded: [String: Set<String>] = [:]
    for result in cases {
      guard let served = result.servedModels, !served.isEmpty else { continue }
      recorded[result.model, default: []].formUnion(served)
    }
    // Kept replies come from the Claude CLI, so they speak only for a Claude judge's alias.
    if let judge, judge.backend == .claude, let served = judge.servedModels, !served.isEmpty {
      recorded[judge.model, default: []].formUnion(served)
    }
    let since = String(RunID.make(startedAt: passedAt, suffix: 0).prefix(Self.runIDTimeLength))
    var problems: [String] = []
    for (alias, servedThen) in recorded.sorted(by: { $0.key < $1.key }) {
      let newest =
        observed
        .filter {
          $0.requestedModel == alias && !$0.servedModels.isEmpty
            && Self.runIDTime($0.runID).map { $0 >= since } == true
        }
        .max { ($0.runID, $0.path) < ($1.runID, $1.path) }
      guard let newest, Set(newest.servedModels) != servedThen else { continue }
      problems.append(
        "`\(alias)` served \(servedThen.sorted().joined(separator: ", ")) in the pass, but "
          + "\(newest.servedModels.sorted().joined(separator: ", ")) in run \(newest.runID) "
          + "(\(newest.path))")
    }
    return problems
  }

  /// `yyyyMMddTHHmmssZ`, the start time every run id begins with.
  static let runIDTimeLength = 16

  static func runIDTime(_ runID: String) -> String? {
    let time = runID.prefix(runIDTimeLength)
    guard time.count == runIDTimeLength else { return nil }
    let shape = time.enumerated().allSatisfy { index, character in
      switch index {
      case 8: character == "T"
      case 15: character == "Z"
      default: character.isASCII && character.isNumber
      }
    }
    return shape ? String(time) : nil
  }

  /// Why this record doesn't show each hashed agent calibrated on the model it ships on: a
  /// `--model` override, an agent with no case, or a case run on another model than the agent's
  /// frontmatter names. Empty when every agent passed on its own model.
  public func modelProblems(agents: [CalibrationHash.File], suite: CalibrationSuite) -> [String] {
    var problems: [String] = []
    if let judge, !judge.isShipped {
      problems.append(
        "the pass was judged by \(judge.name), not the shipped judge "
          + "\(JudgeRecord.shipped.name), and only a pass on the shipped judge counts")
    }
    if let modelOverride {
      return problems + [
        "the pass ran every agent on `--model \(modelOverride)`, and a pass on an override never "
          + "counts"
      ]
    }
    for file in agents where suite.isHashedAgent(file.path) {
      let name = String(
        file.path.dropFirst(CalibrationSuite.agentsDirectory.count + 1).dropLast(".md".count))
      let shipped = CalibrationModel.shipped(
        frontmatterModel: AgentFrontmatter.value(
          "model", in: String(decoding: file.contents, as: UTF8.self)))
      let recorded = cases.filter { $0.agent == name }
      if recorded.isEmpty {
        problems.append("\(name) has no case in the record")
        continue
      }
      let wrong = recorded.filter { $0.model != shipped }
      if !wrong.isEmpty {
        let runs = wrong.map { "\($0.caseName) on \($0.model)" }.joined(separator: ", ")
        problems.append("\(name) ships on \(shipped) but its cases passed as \(runs)")
      }
    }
    return problems
  }
}
