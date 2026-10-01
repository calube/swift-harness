import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `swiftgate judge ask` (design §8): any caller's question set, answered by the gate's judge,
/// with no policy.
enum JudgeAsk {
  static let badInputStatus: Int32 = 2
  static let backendFailedStatus: Int32 = 3

  /// Why nothing was answered, and the exit status that says so.
  struct Refusal: Error, Equatable {
    let status: Int32
    let message: String
  }

  /// The backend and model that answer.
  struct Choice: Equatable {
    let backend: JudgeBackend
    let model: String
  }

  /// The backend and model the flags and the repository's config name, or why they may not be
  /// used. `config` is the repository's config as it loaded.
  static func choose(
    backend: JudgeBackend?, model: String?, sendTo: String?,
    config: Result<Config?, StaticCheckInputs.ConfigFailure>
  ) -> Result<Choice, Refusal> {
    let loaded: Config?
    switch config {
    case .failure(let failure):
      switch failure.outcome {
      case .invalid(let reason, let file): return refuse("\(file): \(reason)")
      case .blocked(let reason): return refuse(reason)
      case .checked: return refuse("\(ConfigLoader.fileName) could not be read")
      }
    case .success(let found): loaded = found
    }
    var configured: (backend: JudgeBackend, model: String?)?
    if case .enabled(let found, _, let foundModel) = loaded?.judge {
      configured = (found, foundModel)
    }
    guard let chosen = backend ?? configured?.backend else {
      return refuse(
        "no judge backend: set [judge] backend in \(ConfigLoader.fileName), or pass --backend "
          + JudgeBackend.allCases.map(\.rawValue).joined(separator: "|"))
    }
    // A config that loaded has already had its `send_to` checked against its backend's host.
    let configNamesHost =
      sendTo == nil && configured?.backend == chosen && chosen.egressHost != nil
    if !configNamesHost, let issue = chosen.egressIssue(sendTo: sendTo, path: "--send-to") {
      guard case .judgeHostNotNamed(_, _, let host) = issue else { return refuse("\(issue)") }
      return refuse("\(issue), or pass --send-to \(host)")
    }
    let resolved =
      model ?? (configured?.backend == chosen ? configured?.model : nil) ?? chosen.pinnedModel
      ?? JudgeFactory.defaultModel
    guard chosen.isPinned(resolved) else {
      let pin = chosen.pinnedModel ?? resolved
      return refuse(
        "\(ConfigIssue.judgeModelNotPinned(path: "--model", value: resolved, backend: chosen, pin: pin))"
      )
    }
    return .success(Choice(backend: chosen, model: resolved))
  }

  private static func refuse(_ message: String) -> Result<Choice, Refusal> {
    .failure(Refusal(status: badInputStatus, message: message))
  }

  /// `judge` behind the answer cache under `root`, unless `noCache`.
  static func caching(_ judge: any Judge, root: URL, noCache: Bool) -> any Judge {
    guard !noCache else { return judge }
    return CachingJudge(
      judge, cache: FileJudgeCache(directory: root.appending(path: FileJudgeCache.directoryName)))
  }

  /// Every subject's answers as ``JudgeAskOutput`` JSON, or why the input or backend refused.
  /// `secrets` never appear in a refusal's message.
  static func answer(_ input: Data, judge: any Judge, secrets: [String]) async -> Result<
    Data, Refusal
  > {
    let parsed: JudgeAskInput
    do throws(JudgeAskInputError) {
      parsed = try JudgeAskInput.decode(input)
    } catch {
      return .failure(Refusal(status: badInputStatus, message: "\(error)"))
    }
    func failed(_ reason: String) -> Result<Data, Refusal> {
      let named = "\(judge.identity.backend)/\(judge.identity.model): \(reason)"
      return .failure(
        Refusal(
          status: backendFailedStatus,
          message: secrets.filter { !$0.isEmpty }.reduce(named) {
            $0.replacingOccurrences(of: $1, with: "<redacted>")
          }))
    }
    let replies: [String: JudgeReply]
    switch await JudgeBatch.measuredAnswer(
      parsed.subjects, questions: parsed.questions, judge: judge)
    {
    case .failure(let error): return failed("\(error)")
    case .success(let found): replies = found
    }
    var subjects: [JudgeAskOutput.Subject] = []
    for subject in parsed.subjects {
      guard let reply = replies[subject.id] else { return failed("no reply for \(subject.id)") }
      do throws(JudgeAnswerViolation) {
        subjects.append(
          JudgeAskOutput.Subject(
            id: subject.id,
            answers: try JudgeAnswers.validate(reply.answers, for: parsed.questions),
            usage: reply.usage))
      } catch {
        return failed("the reply for \(subject.id) doesn't fit the question set: \(error)")
      }
    }
    return .success(
      JudgeAskOutput(
        questionSet: parsed.questions.versionedID, identity: judge.identity, subjects: subjects
      ).json)
  }
}

struct JudgeAskCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ask",
    abstract: "Ask the judge any question set about any subjects, and print the answers as JSON.",
    discussion:
      "Input: {\"schemaVersion\": 1, \"inlineQuestionSet\": {\"id\", \"version\", "
      + "\"subjectDescription\", \"questions\": [{\"id\", \"text\", \"kind\": binary|choice|score, "
      + "\"options\" (choice and score), \"flag\": {\"option\"} | {\"notDeclaredTier\": true}}]}, "
      + "\"subjects\": [{\"id\", \"source\", \"context\", \"declaredTier\" (optional)}]}; the question "
      + "set is the judge dataset's, and `\"questionSet\": \"<id>@<version>\"` names a built-in one "
      + "instead. At most \(JudgeAskInput.maxScoreLevels) score levels and "
      + "\(JudgeAskInput.maxChoiceOptions) choice options per question. Output: {\"schemaVersion\": "
      + "1, \"questionSet\", \"identity\": {\"backend\", \"model\"}, \"subjects\": [{\"id\", "
      + "\"answers\": [{\"question\", \"distribution\": {option: p}, \"rationale\" (when given)}], "
      + "\"usage\": {...} | null}]} in input order. No policy: the caller picks its threshold. "
      + "An eval runner asks 1 rubric, 1 binary question per clause: `swiftgate judge ask --input "
      + "rubric.json --backend claude --model claude-sonnet-5-5`, or `--backend jev --send-to "
      + "api.typesafe.ai` with TYPESAFE_API_KEY set, since Jev sends the input to that host. "
      + "Exit 0 answered, 2 for bad input, a flag or config that can't be used, or a host not "
      + "named (the message names the field), 3 when the backend can't answer.")

  @Option(help: ArgumentHelp("The input JSON, or - for standard input.", valueName: "file|-"))
  var input: String

  @Option(
    name: [.customLong("backend"), .customLong("judge-backend")],
    help: "The backend that answers; the [judge] config's when unset.")
  var backend: JudgeBackend?

  @Option(
    name: [.customLong("model"), .customLong("judge-model")],
    help: "The backend's model; the config's, or the backend's default, when unset.")
  var model: String?

  @Option(
    help: ArgumentHelp(
      "The host a remote backend may send the input to; `--backend jev` needs it, or a [judge] "
        + "config naming it.",
      valueName: "host"))
  var sendTo: String?

  @Flag(help: "Ask the backend even when .harness/judge-cache/ holds the answers.")
  var noCache = false

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let choice: JudgeAsk.Choice
    switch JudgeAsk.choose(
      backend: backend, model: model, sendTo: sendTo,
      config: StaticCheckInputs.loadConfig(root: root))
    {
    case .failure(let refusal): throw Self.fail(refusal)
    case .success(let found): choice = found
    }
    let data: Data
    do {
      data =
        input == "-"
        ? FileHandle.standardInput.readDataToEndOfFile()
        : try Data(contentsOf: URL(filePath: input, relativeTo: root))
    } catch {
      throw Self.fail(
        JudgeAsk.Refusal(
          status: JudgeAsk.badInputStatus, message: "--input: can't read \(input): \(error)"))
    }
    let environment = ProcessInfo.processInfo.environment
    let runner = LiveProcessRunner()
    let config = JudgeConfig.enabled(
      backend: choice.backend, thresholds: JudgeThresholds(advisory: 0, block: 1),
      model: choice.model)
    // `make` returns nil only for a disabled config, which this never is.
    let judge =
      JudgeFactory.make(config, runner: runner, cacheDirectory: nil, environment: environment)
      ?? ClaudeCLIJudge(runner: runner, model: choice.model)
    let answered = try await JudgeEventRoute.run(root: root, route: .judgeAsk) {
      await JudgeAsk.answer(
        data, judge: JudgeAsk.caching(judge, root: root, noCache: noCache),
        secrets: JudgeBackend.allCases.compactMap { $0.keyVariable.flatMap { environment[$0] } })
    }
    switch answered {
    case .failure(let refusal): throw Self.fail(refusal)
    case .success(let json): Console.write(String(decoding: json, as: UTF8.self))
    }
  }

  private static func fail(_ refusal: JudgeAsk.Refusal) -> ExitCode {
    FileHandle.standardError.write(Data("swiftgate judge ask: \(refusal.message)\n".utf8))
    return ExitCode(refusal.status)
  }
}
