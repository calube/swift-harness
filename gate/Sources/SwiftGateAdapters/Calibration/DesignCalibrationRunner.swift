import Foundation
import SwiftGateDomain

/// A seed's `label.json`: the questions asked about the case and the option a correct agent
/// picks for each (spec §12, "labelled by construction").
public struct CalibrationLabel: Sendable, Equatable, Codable {
  public static let currentSchemaVersion = 1

  public struct Question: Sendable, Equatable, Codable {
    public let id: String
    public let text: String
    public let options: [String]
    public let expected: String
  }

  public let schemaVersion: Int
  public let questions: [Question]

  /// Decodes and validates: known schema version, at least one question, unique question ids,
  /// at least two distinct options, and `expected` among them.
  public static func decode(_ data: Data) -> Result<CalibrationLabel, SeedError> {
    let label: CalibrationLabel
    do {
      label = try JSONDecoder().decode(CalibrationLabel.self, from: data)
    } catch {
      return .failure(SeedError(message: "not a calibration label: \(error)"))
    }
    guard label.schemaVersion == currentSchemaVersion else {
      return .failure(SeedError(message: "unsupported schemaVersion \(label.schemaVersion)"))
    }
    guard !label.questions.isEmpty else {
      return .failure(SeedError(message: "a label needs at least one question"))
    }
    var seen: Set<String> = []
    for question in label.questions {
      guard !question.id.isEmpty, seen.insert(question.id).inserted else {
        return .failure(SeedError(message: "question id `\(question.id)` is empty or repeated"))
      }
      guard question.options.count >= 2, Set(question.options).count == question.options.count
      else {
        return .failure(
          SeedError(message: "question `\(question.id)` needs two or more distinct options"))
      }
      guard question.options.contains(question.expected) else {
        return .failure(
          SeedError(
            message: "question `\(question.id)` expects `\(question.expected)`, which isn't one "
              + "of its options \(question.options)"))
      }
    }
    return .success(label)
  }

  public struct SeedError: Error, Sendable, Equatable {
    public let message: String
  }
}

/// The seeds under ``DesignCalibrationLayout/seedsDirectory``: one directory per agent, named
/// after its `agents/<agent>.md`, holding one directory per case.
public struct DesignCalibrationSeeds: Sendable, Equatable {
  public struct Case: Sendable, Equatable {
    public let name: String
    /// Repo-relative case directory.
    public let directory: String
    public let input: String
    public let label: CalibrationLabel
  }

  public struct Agent: Sendable, Equatable {
    public let name: String
    /// The agent file's body after its frontmatter: what the agent runs with.
    public let systemPrompt: String
    public let cases: [Case]
  }

  /// A seed-set defect; `path` is repo-relative. Every one is a fix to the repository, never an
  /// environment problem.
  public enum Problem: Sendable, Equatable {
    case noSeeds(path: String)
    case missingLabel(path: String)
    case missingInput(path: String)
    case invalidLabel(path: String, reason: String)
    /// A seed directory with no `agents/<name>.md`, or not named `design-*`.
    case unknownAgent(path: String)
    /// A hashed agent with no case.
    case uncalibratedAgent(path: String)
    case unreadable(path: String, reason: String)
  }

  public let agents: [Agent]
  public let problems: [Problem]

  public static func load(root: URL) -> DesignCalibrationSeeds {
    let fileManager = FileManager.default
    let seedsRoot = DesignCalibrationLayout.seedsDirectory
    var problems: [Problem] = []
    var agents: [Agent] = []
    // Agents with at least one case directory, labelled or not: a broken case is reported as
    // itself, not also as an uncalibrated agent.
    var seeded: Set<String> = []

    func directories(_ path: String) -> [String]? {
      let url = root.appending(path: path, directoryHint: .isDirectory)
      do {
        return try fileManager.contentsOfDirectory(atPath: url.path).filter { name in
          var isDirectory: ObjCBool = false
          return !name.hasPrefix(".")
            && fileManager.fileExists(
              atPath: url.appending(path: name).path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        }.sorted()
      } catch {
        problems.append(.unreadable(path: path, reason: "\(error)"))
        return nil
      }
    }

    func text(_ path: String) -> String? {
      do {
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
      } catch {
        problems.append(.unreadable(path: path, reason: "\(error)"))
        return nil
      }
    }

    func exists(_ path: String) -> Bool {
      fileManager.fileExists(atPath: root.appending(path: path).path)
    }

    let agentNames = exists(seedsRoot) ? (directories(seedsRoot) ?? []) : []
    for agentName in agentNames {
      let agentSeeds = "\(seedsRoot)/\(agentName)"
      let agentFile = "\(DesignCalibrationLayout.agentsDirectory)/\(agentName).md"
      guard DesignCalibrationHash.isHashed(agentFile), exists(agentFile) else {
        problems.append(.unknownAgent(path: agentSeeds))
        continue
      }
      guard let agentText = text(agentFile), let caseNames = directories(agentSeeds) else {
        continue
      }
      if !caseNames.isEmpty { seeded.insert(agentName) }
      var cases: [Case] = []
      for caseName in caseNames {
        let directory = "\(agentSeeds)/\(caseName)"
        let inputPath = "\(directory)/\(DesignCalibrationLayout.inputFile)"
        let labelPath = "\(directory)/\(DesignCalibrationLayout.labelFile)"
        guard exists(labelPath) else {
          problems.append(.missingLabel(path: directory))
          continue
        }
        guard exists(inputPath) else {
          problems.append(.missingInput(path: directory))
          continue
        }
        guard let input = text(inputPath), let labelText = text(labelPath) else { continue }
        switch CalibrationLabel.decode(Data(labelText.utf8)) {
        case .failure(let error):
          problems.append(.invalidLabel(path: labelPath, reason: error.message))
        case .success(let label):
          cases.append(Case(name: caseName, directory: directory, input: input, label: label))
        }
      }
      agents.append(
        Agent(name: agentName, systemPrompt: body(ofAgent: agentText), cases: cases))
    }

    if let hashed = try? DesignCalibrationHash.discover(root: root) {
      for file in hashed where file.path.hasPrefix("\(DesignCalibrationLayout.agentsDirectory)/") {
        let name = String(file.path.dropFirst("agents/".count).dropLast(".md".count))
        if !seeded.contains(name) {
          problems.append(.uncalibratedAgent(path: file.path))
        }
      }
    } else {
      problems.append(
        .unreadable(
          path: DesignCalibrationLayout.agentsDirectory, reason: "can't list the design agents"))
    }
    if agents.allSatisfy(\.cases.isEmpty), problems.isEmpty {
      problems.append(.noSeeds(path: seedsRoot))
    }
    return DesignCalibrationSeeds(agents: agents, problems: problems)
  }

  /// Strips a leading `---` frontmatter block, then surrounding blank lines.
  static func body(ofAgent text: String) -> String {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    var body = Substring(normalized)
    if normalized.hasPrefix("---\n"),
      let close = normalized.range(
        of: "\n---\n",
        range: normalized.index(normalized.startIndex, offsetBy: 3)..<normalized.endIndex)
    {
      body = normalized[close.upperBound...]
    }
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Runs one design agent on one seed through the Foundation judge's Claude CLI invocation: the
/// same `claude -p` flags, schema and reply parsing, with the agent's own prompt as the system
/// prompt so the calibrated text is the shipped text.
public struct DesignCalibrationRunner: Sendable {
  private let runner: any ProcessRunner
  private let judge: ClaudeCLIJudge

  public init(
    runner: any ProcessRunner, model: String, executable: String = "claude",
    timeout: Duration = .seconds(300)
  ) {
    self.runner = runner
    self.judge = ClaudeCLIJudge(
      runner: runner, model: model, executable: executable, timeout: timeout)
  }

  public var model: String { judge.identity.model }

  public func run(agent: DesignCalibrationSeeds.Agent, seed: DesignCalibrationSeeds.Case)
    async throws(JudgeError) -> CalibrationRecord.CaseResult
  {
    let questions = Self.questionSet(agent: agent.name, seed: seed)
    var invocation = judge.invocation(
      Self.subject(agent: agent.name, seed: seed), questions: questions)
    invocation.arguments += ["--system-prompt", agent.systemPrompt]
    let output: ProcessOutput
    do {
      output = try await runner.run(invocation)
    } catch {
      throw .process(error)
    }
    let answers = try ClaudeJudgeReply.parse(
      output.stdout.bytes, stderr: output.stderr.text, for: questions)
    var results: [CalibrationRecord.QuestionResult] = []
    for question in seed.label.questions {
      guard let answer = answers.first(where: { $0.question == question.id }),
        let answered = answer.mostLikely(among: question.options)
      else {
        throw .malformedReply("no answer to `\(question.id)`")
      }
      results.append(
        CalibrationRecord.QuestionResult(
          question: question.id, expected: question.expected, answered: answered,
          probability: answer.probability(of: answered)))
    }
    return CalibrationRecord.CaseResult(agent: agent.name, caseName: seed.name, answers: results)
  }

  static func questionSet(agent: String, seed: DesignCalibrationSeeds.Case) -> JudgeQuestionSet {
    JudgeQuestionSet(
      id: "calibrate-\(agent)-\(seed.name)", version: seed.label.schemaVersion,
      subjectDescription: "a design review case given to you in your role as \(agent)",
      questions: seed.label.questions.map { question in
        JudgeQuestion(
          id: question.id, text: question.text, kind: .choice(question.options),
          flag: .option(question.expected), mayBlock: false,
          problem: "the agent's answer differs from the label")
      })
  }

  static func subject(agent: String, seed: DesignCalibrationSeeds.Case) -> JudgeSubject {
    JudgeSubject(
      id: "\(agent)/\(seed.name)", file: "\(seed.directory)/\(DesignCalibrationLayout.inputFile)",
      line: 1, source: seed.input, context: "")
  }
}
