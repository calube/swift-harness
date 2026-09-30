import Foundation
import SwiftGateDomain

/// A seed's `label.json`: checks over what a correct agent returns for the case (spec §12,
/// "labelled by construction"). The agent runs on `input.md` alone and answers in its own output
/// contract; the checks read that output, so no label text ever reaches the agent.
public struct CalibrationLabel: Sendable, Equatable {
  public static let currentSchemaVersion = 2

  /// One condition on an element of the returned JSON: the value at `path` (dot-separated keys)
  /// is one of `oneOf`, or starts with `prefix`. A string array at `path` matches when any of
  /// its strings does.
  public struct Condition: Sendable, Equatable {
    public enum Test: Sendable, Equatable {
      case oneOf([String])
      case prefix(String)
    }

    public let path: [String]
    public let test: Test

    func matches(_ element: Any) -> Bool {
      let strings: [String]
      switch JSONPath.value(at: path, in: element) {
      case let string as String: strings = [string]
      case let array as [Any]: strings = array.compactMap { $0 as? String }
      default: return false
      }
      return strings.contains { string in
        switch test {
        case .oneOf(let values): values.contains(string)
        case .prefix(let prefix): string.hasPrefix(prefix)
        }
      }
    }
  }

  /// A question a separate judge answers about the agent's output, for a label no JSON field
  /// carries (a drafter returns a document). Its text never names the expected option, and the
  /// judge never sees which option that is.
  public struct JudgedQuestion: Sendable, Equatable {
    public let text: String
    public let options: [String]
    public let expected: String
  }

  public enum Kind: Sendable, Equatable {
    /// Some element of `array` meets every condition.
    case present(array: String, conditions: [Condition])
    /// No element of `array` meets every condition.
    case absent(array: String, conditions: [Condition])
    /// Every element of `array` that meets the conditions carries `expected` at `field`, and at
    /// least one does.
    case value(array: String, conditions: [Condition], field: [String], expected: String)
    case judge(JudgedQuestion)
  }

  public struct Check: Sendable, Equatable {
    public let id: String
    public let kind: Kind

    /// What the record stores as this check's expected answer.
    public var expected: String {
      switch kind {
      case .present: "present"
      case .absent: "absent"
      case .value(_, _, _, let expected): expected
      case .judge(let question): question.expected
      }
    }
  }

  public let schemaVersion: Int
  public let checks: [Check]

  public var judgeQuestions: [(id: String, question: JudgedQuestion)] {
    checks.compactMap { check in
      guard case .judge(let question) = check.kind else { return nil }
      return (check.id, question)
    }
  }

  /// Decodes and validates: known schema version and keys, at least one check, unique check ids,
  /// and each check well formed. A judge question needs two or more distinct options with
  /// `expected` among them, can't be answered `yes`/`no`, and can't name its expected option in
  /// its text: a question that names the answer leads whoever reads it.
  public static func decode(_ data: Data) -> Result<CalibrationLabel, SeedError> {
    do {
      return .success(try LabelDecoder.label(data))
    } catch let error as SeedError {
      return .failure(error)
    } catch {
      return .failure(SeedError(message: "not a calibration label: \(error)"))
    }
  }

  public struct SeedError: Error, Sendable, Equatable {
    public let message: String
  }
}

/// Strict `label.json` decoding: every object's keys are known, so a typo fails loudly instead
/// of dropping a condition.
private enum LabelDecoder {
  typealias SeedError = CalibrationLabel.SeedError

  static func label(_ data: Data) throws -> CalibrationLabel {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SeedError(message: "a label is a JSON object")
    }
    try keys(object, allowed: ["schemaVersion", "checks"], in: "the label")
    guard let version = object["schemaVersion"] as? Int else {
      throw SeedError(message: "schemaVersion must be an integer")
    }
    guard version == CalibrationLabel.currentSchemaVersion else {
      throw SeedError(message: "unsupported schemaVersion \(version)")
    }
    guard let rawChecks = object["checks"] as? [[String: Any]], !rawChecks.isEmpty else {
      throw SeedError(message: "a label needs at least one check")
    }
    var seen: Set<String> = []
    var checks: [CalibrationLabel.Check] = []
    for raw in rawChecks {
      let check = try self.check(raw)
      guard seen.insert(check.id).inserted else {
        throw SeedError(message: "check id `\(check.id)` is repeated")
      }
      checks.append(check)
    }
    return CalibrationLabel(schemaVersion: version, checks: checks)
  }

  static func check(_ raw: [String: Any]) throws -> CalibrationLabel.Check {
    guard let id = raw["id"] as? String, !id.isEmpty else {
      throw SeedError(message: "every check needs a non-empty `id`")
    }
    guard let kind = raw["kind"] as? String else {
      throw SeedError(message: "check `\(id)` needs a `kind`")
    }
    let place = "check `\(id)`"
    switch kind {
    case "present", "absent":
      try keys(raw, allowed: ["id", "kind", "array", "where"], in: place)
      let array = try string(raw, "array", in: place)
      let conditions = try self.conditions(raw["where"], in: place)
      return .init(
        id: id,
        kind: kind == "present"
          ? .present(array: array, conditions: conditions)
          : .absent(array: array, conditions: conditions))
    case "value":
      try keys(raw, allowed: ["id", "kind", "array", "where", "field", "expected"], in: place)
      return .init(
        id: id,
        kind: .value(
          array: try string(raw, "array", in: place),
          conditions: try conditions(raw["where"], in: place),
          field: try string(raw, "field", in: place).split(separator: ".").map(String.init),
          expected: try string(raw, "expected", in: place)))
    case "judge":
      try keys(raw, allowed: ["id", "kind", "text", "options", "expected"], in: place)
      let text = try string(raw, "text", in: place)
      let expected = try string(raw, "expected", in: place)
      guard let options = raw["options"] as? [String], options.count >= 2,
        Set(options).count == options.count, !options.contains(where: \.isEmpty)
      else {
        throw SeedError(message: "\(place) needs two or more distinct options")
      }
      guard options.contains(expected) else {
        throw SeedError(
          message: "\(place) expects `\(expected)`, which isn't one of its options \(options)")
      }
      guard Set(options.map { $0.lowercased() }) != ["yes", "no"] else {
        throw SeedError(
          message: "\(place) asks yes or no; ask what the output holds, with the answers as "
            + "options")
      }
      guard !text.lowercased().contains(expected.lowercased()) else {
        throw SeedError(message: "\(place) names its expected option `\(expected)` in its text")
      }
      return .init(
        id: id, kind: .judge(.init(text: text, options: options, expected: expected)))
    default:
      throw SeedError(
        message: "\(place) has kind `\(kind)`; use present, absent, value or judge")
    }
  }

  static func conditions(_ raw: Any?, in place: String) throws -> [CalibrationLabel.Condition] {
    guard let raw else { return [] }
    guard let list = raw as? [[String: Any]] else {
      throw SeedError(message: "\(place): `where` is a list of conditions")
    }
    return try list.map { condition in
      try keys(condition, allowed: ["path", "oneOf", "prefix"], in: "\(place) condition")
      let path = try string(condition, "path", in: "\(place) condition")
        .split(separator: ".").map(String.init)
      switch (condition["oneOf"], condition["prefix"]) {
      case (let values as [String], nil)
      where !values.isEmpty && !values.contains(where: \.isEmpty):
        return .init(path: path, test: .oneOf(values))
      case (nil, let prefix as String) where !prefix.isEmpty:
        return .init(path: path, test: .prefix(prefix))
      default:
        throw SeedError(
          message: "\(place): a condition on `\(path.joined(separator: "."))` needs exactly one "
            + "of a non-empty `oneOf` list or a non-empty `prefix`")
      }
    }
  }

  static func string(_ raw: [String: Any], _ key: String, in place: String) throws -> String {
    guard let value = raw[key] as? String, !value.isEmpty else {
      throw SeedError(message: "\(place) needs a non-empty `\(key)`")
    }
    return value
  }

  static func keys(_ raw: [String: Any], allowed: Set<String>, in place: String) throws {
    if let unknown = Set(raw.keys).subtracting(allowed).sorted().first {
      throw SeedError(message: "\(place) has unknown key `\(unknown)`")
    }
  }
}

enum JSONPath {
  static func value(at path: [String], in element: Any) -> Any? {
    var current: Any? = element
    for key in path {
      current = (current as? [String: Any])?[key]
    }
    return current
  }
}

/// The design suite's seeds: every case is an `input.md` and a label of checks.
public typealias DesignCalibrationSeeds = CalibrationSeeds<CalibrationLabel>

extension CalibrationLabel: CalibrationSeedLabel {
  public static let suite = CalibrationSuite.design
  public static func decode(_ data: Data, agent: String) -> Result<CalibrationLabel, SeedError> {
    decode(data)
  }
  public static func requiredEntries(agent: String) -> [String] { [] }
}

/// Where a run keeps each agent's reply, `.harness/runs/<run id>/calibrate-design/<agent>/`:
/// `<seed>.txt` holds the reply exactly as the agent returned it, and `<seed>.json` the model the
/// run asked for and the ones the CLI says served it. A live run keeps them; a replay reads them in
/// place of running the agents.
public struct DesignCalibrationReplies: Sendable, Equatable {
  public enum Mode: Sendable, Equatable {
    case keep
    case replay
  }

  public static let directoryName = "calibrate-design"

  public let runID: String
  public let directory: URL
  public let mode: Mode

  public init(root: URL, runID: String, mode: Mode) {
    self.runID = runID
    self.mode = mode
    self.directory = root.appending(
      path: RunLayout.runDirectory(for: runID) + Self.directoryName, directoryHint: .isDirectory)
  }

  /// A reply's path relative to the worktree root, as messages name it.
  public func replyPath(agent: String, seed: String) -> String {
    path(agent: agent, seed: seed, "txt")
  }

  public func metadataPath(agent: String, seed: String) -> String {
    path(agent: agent, seed: seed, "json")
  }

  private func path(agent: String, seed: String, _ suffix: String) -> String {
    "\(RunLayout.runDirectory(for: runID))\(Self.directoryName)/\(agent)/\(seed).\(suffix)"
  }

  private func file(agent: String, seed: String, _ suffix: String) -> URL {
    directory.appending(path: "\(agent)/\(seed).\(suffix)", directoryHint: .notDirectory)
  }

  /// `<seed>.json`: `requestedModel` is what the run passed to `--model`, often an alias;
  /// `servedModels` are the `modelUsage` keys of the CLI's reply, the ids that actually answered.
  struct Metadata: Codable, Equatable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let requestedModel: String
    let servedModels: [String]
  }

  struct Stored {
    let reply: String
    let metadata: Metadata
  }

  func keep(_ reply: String, metadata: Metadata, agent: String, seed: String)
    throws(CalibrationCaseError)
  {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      try FileManager.default.createDirectory(
        at: directory.appending(path: agent, directoryHint: .isDirectory),
        withIntermediateDirectories: true)
      try Data(reply.utf8).write(to: file(agent: agent, seed: seed, "txt"), options: .atomic)
      try encoder.encode(metadata).write(
        to: file(agent: agent, seed: seed, "json"), options: .atomic)
    } catch {
      throw .blocked("can't keep the reply at \(replyPath(agent: agent, seed: seed)): \(error)")
    }
  }

  /// Every kept `<seed>.json` under `root`'s runs, and each one that couldn't be read, by path.
  public struct Observations: Sendable, Equatable {
    public let observations: [ServedModelObservation]
    public let unreadable: [String]
  }

  /// What every kept run under `root` says each requested model resolved to. No call is made:
  /// these are the served ids the CLI reported when the replies were kept.
  public static func observations(root: URL) -> Observations {
    Observations(observations: [], unreadable: [])
  }

  func stored(agent: String, seed: String) throws(CalibrationCaseError) -> Stored {
    let replyPath = replyPath(agent: agent, seed: seed)
    guard let data = try? Data(contentsOf: file(agent: agent, seed: seed, "txt")) else {
      throw .blocked("no kept reply at \(replyPath) to replay")
    }
    guard let reply = String(data: data, encoding: .utf8) else {
      throw .blocked("the kept reply at \(replyPath) isn't UTF-8")
    }
    let metadataPath = metadataPath(agent: agent, seed: seed)
    let metadata: Metadata
    do {
      metadata = try JSONDecoder().decode(
        Metadata.self, from: Data(contentsOf: file(agent: agent, seed: seed, "json")))
    } catch {
      throw .blocked("can't read the kept models at \(metadataPath): \(error)")
    }
    guard metadata.schemaVersion == Metadata.currentSchemaVersion else {
      throw .blocked(
        "\(metadataPath) has schemaVersion \(metadata.schemaVersion); this swiftgate reads "
          + "\(Metadata.currentSchemaVersion)")
    }
    return Stored(reply: reply, metadata: metadata)
  }
}

/// Runs one design agent on one seed as it ships: its prompt body as the system prompt, the
/// model its frontmatter names, `input.md` verbatim as the whole prompt, and no tools. The agent
/// answers in its own output contract, and the label's checks score that output. A judge
/// question goes to a separate judge that reads only the agent's output.
public struct DesignCalibrationRunner: Sendable {
  public struct CaseRun: Sendable, Equatable {
    public let result: CalibrationRecord.CaseResult
    public let costUSD: Double?
    public let durationMilliseconds: Int?
    /// The ids the CLI says served the agent, beside `result.model`, the one it was asked for.
    public let servedModels: [String]
    /// Where the reply is kept, when the run keeps or replays replies.
    public let replyPath: String?
    /// The ids the judge reported serving its judged labels; empty when it judged none.
    public internal(set) var judgeServedModels: [String] = []
  }

  public static let judgeSubjectDescription =
    "the output a design agent returned for a design task"

  private let runner: any ProcessRunner
  private let judge: any Judge
  private let executable: String
  private let timeout: Duration
  /// The model for an agent whose frontmatter names none.
  public let unpinnedModel: String
  /// Every agent's model for this run in place of its frontmatter's; a pass made with one is
  /// never fresh.
  public let modelOverride: String?
  public let replies: DesignCalibrationReplies?

  public init(
    runner: any ProcessRunner, unpinnedModel: String = CalibrationModel.unpinned,
    modelOverride: String? = nil, judgeModel: String = JudgeFactory.defaultModel,
    executable: String = "claude", timeout: Duration = .seconds(900),
    replies: DesignCalibrationReplies? = nil, judge: (any Judge)? = nil
  ) {
    self.runner = runner
    self.unpinnedModel = unpinnedModel
    self.modelOverride = modelOverride
    self.executable = executable
    self.timeout = timeout
    self.replies = replies
    self.judge = ClaudeCLIJudge(runner: runner, model: judgeModel, executable: executable)
  }

  public func model(of agent: DesignCalibrationSeeds.Agent) -> String {
    modelOverride ?? agent.model ?? unpinnedModel
  }

  public func run(agent: DesignCalibrationSeeds.Agent, seed: DesignCalibrationSeeds.Case)
    async throws(CalibrationCaseError) -> CaseRun
  {
    let reply: Reply
    let model: String
    if let replies, replies.mode == .replay {
      let stored = try replies.stored(agent: agent.name, seed: seed.name)
      reply = Reply(
        result: stored.reply, costUSD: nil, durationMilliseconds: nil,
        servedModels: stored.metadata.servedModels)
      model = stored.metadata.requestedModel
    } else {
      model = self.model(of: agent)
      reply = try await runAgent(agent, input: seed.input)
      try replies?.keep(
        reply.result,
        metadata: .init(
          schemaVersion: DesignCalibrationReplies.Metadata.currentSchemaVersion,
          requestedModel: model, servedModels: reply.servedModels),
        agent: agent.name, seed: seed.name)
    }
    var answers: [CalibrationRecord.QuestionResult] = []
    let returned = Self.jsonObject(in: reply.result)
    for check in seed.label.checks {
      let answered: String
      switch check.kind {
      case .present(let array, let conditions), .absent(let array, let conditions):
        guard let returned else {
          answered = "no JSON object"
          break
        }
        answered =
          Self.elements(array, in: returned).contains { element in
            conditions.allSatisfy { $0.matches(element) }
          } ? "present" : "absent"
      case .value(let array, let conditions, let field, _):
        guard let returned else {
          answered = "no JSON object"
          break
        }
        let matching = Self.elements(array, in: returned).filter { element in
          conditions.allSatisfy { $0.matches(element) }
        }
        let values = Set(
          matching.map { element in
            (JSONPath.value(at: field, in: element) as? String) ?? "missing"
          })
        answered = values.isEmpty ? "no match" : values.sorted().joined(separator: ", ")
      case .judge:
        continue
      }
      answers.append(
        .init(question: check.id, expected: check.expected, answered: answered, probability: 1))
    }

    let judged = seed.label.judgeQuestions
    if !judged.isEmpty {
      let questions = Self.judgeQuestionSet(agent: agent.name, seed: seed.name, judged)
      let replies: [JudgeAnswer]
      do {
        replies = try await judge.answer(
          Self.judgeSubject(agent: agent.name, seed: seed, output: reply.result),
          questions: questions)
      } catch {
        throw .blocked("the judge couldn't answer: \(error)")
      }
      for (id, question) in judged {
        guard let reply = replies.first(where: { $0.question == id }),
          let answered = reply.mostLikely(among: question.options)
        else {
          throw .blocked("the judge gave no answer to `\(id)`")
        }
        answers.append(
          .init(
            question: id, expected: question.expected, answered: answered,
            probability: reply.probability(of: answered)))
      }
    }
    let order = seed.label.checks.map(\.id)
    answers.sort {
      (order.firstIndex(of: $0.question) ?? 0) < (order.firstIndex(of: $1.question) ?? 0)
    }
    return CaseRun(
      result: .init(agent: agent.name, caseName: seed.name, model: model, answers: answers),
      costUSD: reply.costUSD, durationMilliseconds: reply.durationMilliseconds,
      servedModels: reply.servedModels,
      replyPath: replies?.replyPath(agent: agent.name, seed: seed.name))
  }

  // MARK: - The agent

  struct Reply {
    let result: String
    let costUSD: Double?
    let durationMilliseconds: Int?
    let servedModels: [String]
  }

  func invocation(_ agent: DesignCalibrationSeeds.Agent, input: String) -> ProcessInvocation {
    ProcessInvocation(
      executable: executable,
      arguments: [
        "-p", "--output-format", "json", "--system-prompt", agent.systemPrompt,
        // No tools, no user/project settings (so no plugin hooks), no MCP servers, no
        // transcript: every case carries its whole context pack inline.
        "--restricted", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
        // `verbose: true` in the user's global config turns `--output-format json` into an array
        // of stream events; `--settings` overrides it.
        "--settings", #"{"verbose":false}"#,
        "--model", model(of: agent),
      ],
      workingDirectory: FileManager.default.temporaryDirectory.path,
      standardInput: Data(input.utf8), timeout: timeout)
  }

  private func runAgent(_ agent: DesignCalibrationSeeds.Agent, input: String)
    async throws(CalibrationCaseError) -> Reply
  {
    let output: ProcessOutput
    do {
      output = try await runner.run(invocation(agent, input: input))
    } catch {
      throw .blocked("\(executable) didn't finish: \(error)")
    }
    guard
      let object = (try? JSONSerialization.jsonObject(with: output.stdout.bytes))
        as? [String: Any]
    else {
      throw .blocked(
        "\(executable) exited \(output.status) without a JSON result: "
          + String(output.stderr.text.suffix(400)))
    }
    guard output.status.isSuccess, object["is_error"] as? Bool != true,
      let result = object["result"] as? String
    else {
      throw .blocked(
        "\(executable) reported an error (\(output.status)): "
          + String((object["result"] as? String ?? output.stderr.text).suffix(400)))
    }
    return Reply(
      result: result, costUSD: object["total_cost_usd"] as? Double,
      durationMilliseconds: object["duration_ms"] as? Int,
      servedModels: (object["modelUsage"] as? [String: Any] ?? [:]).keys.sorted())
  }

  /// The agent's reply is one JSON object, possibly fenced.
  static func jsonObject(in text: String) -> [String: Any]? {
    guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close
    else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)))
      as? [String: Any]
  }

  static func elements(_ array: String, in object: [String: Any]) -> [Any] {
    object[array] as? [Any] ?? []
  }

  // MARK: - The judge

  /// Built from each question's text and options only; the expected option isn't an input, so
  /// neither the prompt nor the schema can carry it.
  static func judgeQuestionSet(
    agent: String, seed: String, _ judged: [(id: String, question: CalibrationLabel.JudgedQuestion)]
  ) -> JudgeQuestionSet {
    JudgeQuestionSet(
      id: "calibrate-\(agent)-\(seed)", version: CalibrationLabel.currentSchemaVersion,
      subjectDescription: judgeSubjectDescription,
      questions: judged.map { id, question in
        JudgeQuestion(
          id: id, text: question.text, kind: .choice(question.options),
          flag: .option(question.options[0]), mayBlock: false,
          problem: "calibration question")
      })
  }

  static func judgeSubject(agent: String, seed: DesignCalibrationSeeds.Case, output: String)
    -> JudgeSubject
  {
    JudgeSubject(
      id: "\(agent)/\(seed.name)", file: "\(seed.directory)/\(CalibrationSuite.inputFile)",
      line: 1, source: output, context: "")
  }
}
