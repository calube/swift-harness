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

/// The design suite's seeds: every case is an `input.md` and a question label.
public typealias DesignCalibrationSeeds = CalibrationSeeds<CalibrationLabel>

extension CalibrationLabel: CalibrationSeedLabel {
  public static let suite = CalibrationSuite.design
  public static func decode(_ data: Data, agent: String) -> Result<CalibrationLabel, SeedError> {
    decode(data)
  }
  public static func requiredEntries(agent: String) -> [String] { [] }
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
