import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Claude's reason on a blocking finding that a backend without reasons decided (design §6 point
/// 2). Claude writes the reason and never changes the finding's severity.
enum JudgeBlockReason {
  /// Starts `failureScenario` when Claude couldn't write the reason; the rest says why.
  static let missingPrefix = "Claude's reason is missing: "

  /// The Claude judge that writes reasons, behind the judge cache under `root`. Its `claude`
  /// never sees the Jev key.
  static func liveJudge(root: URL, runner: any ProcessRunner = LiveProcessRunner()) -> any Judge {
    CachingJudge(
      ClaudeCLIJudge(runner: KeylessProcessRunner(inner: runner), model: JudgeFactory.defaultModel),
      cache: FileJudgeCache(directory: root.appending(path: FileJudgeCache.directoryName)))
  }

  /// `findings` with Claude's reason on each major finding `identity` decided, when `identity`'s
  /// backend gives no reason of its own. Claude answers only that finding's question about that
  /// subject; its rationale becomes `failureScenario` and its probability joins the message. The
  /// severity never changes, so a block stands however Claude answers or fails.
  static func attach(
    _ findings: [Finding], subjects: [JudgeSubject], answers: [String: [JudgeAnswer]],
    questions: JudgeQuestionSet, identity: JudgeIdentity, reasonJudge: (any Judge)?,
    redacting secrets: [String]
  ) async -> [Finding] {
    guard JudgeBackend(rawValue: identity.backend)?.writesReasons == false else {
      return findings
    }
    let bySite = Dictionary(
      subjects.map { (Site(file: $0.file, line: $0.line), $0) }, uniquingKeysWith: { a, _ in a })
    var requests: [Request] = []
    for (index, finding) in findings.enumerated() where finding.severity == .major {
      guard
        let question = questions.questions.first(where: {
          JudgePolicy.ruleIDPrefix + $0.id == finding.ruleID
        }),
        let line = finding.line, let subject = bySite[Site(file: finding.file, line: line)]
      else { continue }
      requests.append(Request(index: index, subject: subject, question: question))
    }
    guard !requests.isEmpty else { return findings }
    let outcomes = await reasons(for: requests, set: questions, judge: reasonJudge)
    var result = findings
    for (index, outcome) in outcomes {
      let finding = findings[index]
      let message: String
      let reason: String
      switch outcome {
      case .written(let rationale, let p, let by):
        message =
          finding.message + "; reason from \(by.backend)/\(by.model) (claude p="
          + String(format: "%.2f", p) + ")"
        reason = rationale
      case .missing(let why):
        message = finding.message
        reason = missingPrefix + why
      }
      // Rebuilt from a valid finding's own fields, so the report contract still holds.
      result[index] =
        (try? Finding(
          ruleID: finding.ruleID, severity: finding.severity, file: finding.file,
          line: finding.line, message: redact(message, secrets),
          failureScenario: redact(reason, secrets))) ?? finding
    }
    return result
  }

  /// The set Claude is asked for 1 finding's reason: that question alone, under its own id so its
  /// cache entries never stand in for the whole set's.
  static func questions(asking question: JudgeQuestion, from set: JudgeQuestionSet)
    -> JudgeQuestionSet
  {
    JudgeQuestionSet(
      id: "\(set.id).\(question.id)", version: set.version,
      subjectDescription: set.subjectDescription, questions: [question])
  }

  private struct Site: Hashable {
    let file: String
    let line: Int
  }

  private struct Request: Sendable {
    let index: Int
    let subject: JudgeSubject
    let question: JudgeQuestion
  }

  private enum Outcome: Sendable {
    case written(String, p: Double, by: JudgeIdentity)
    case missing(String)
  }

  private static func reasons(
    for requests: [Request], set: JudgeQuestionSet, judge: (any Judge)?
  ) async -> [(Int, Outcome)] {
    guard let judge else {
      return requests.map { ($0.index, .missing("no Claude judge is available")) }
    }
    return await withTaskGroup(of: (Int, Outcome).self) { group in
      var pending = requests[...]
      var outcomes: [(Int, Outcome)] = []
      func enqueue() {
        guard let request = pending.popFirst() else { return }
        group.addTask { (request.index, await reason(for: request, set: set, judge: judge)) }
      }
      for _ in 0..<JudgeBatch.maxConcurrent { enqueue() }
      for await outcome in group {
        outcomes.append(outcome)
        enqueue()
      }
      return outcomes
    }
  }

  private static func reason(for request: Request, set: JudgeQuestionSet, judge: any Judge) async
    -> Outcome
  {
    let asked = questions(asking: request.question, from: set)
    let answers: [JudgeAnswer]
    do throws(JudgeError) {
      answers = try await judge.answer(request.subject, questions: asked)
    } catch {
      return .missing(error.explanation(by: judge.identity))
    }
    let name = judge.identity.backend
    guard let answer = answers.first(where: { $0.question == request.question.id }),
      let p = JudgePolicy.flaggedProbability(
        request.question, answer: answer, subject: request.subject)
    else { return .missing("\(name) gave no answer to \(request.question.id)") }
    guard let rationale = answer.rationale, !rationale.isEmpty else {
      return .missing("\(name) answered without a rationale")
    }
    return .written(rationale, p: p, by: judge.identity)
  }

  static func redact(_ text: String, _ secrets: [String]) -> String {
    secrets.filter { !$0.isEmpty }.reduce(text) { $0.replacing($1, with: "<redacted>") }
  }
}

/// Runs every command without the Jev key in its environment, so a `claude` child never sees it.
struct KeylessProcessRunner: ProcessRunner {
  let inner: any ProcessRunner

  func run(_ invocation: ProcessInvocation) async throws(ProcessRunnerError) -> ProcessOutput {
    var keyless = invocation
    for variable in JudgeBackend.allCases.compactMap(\.keyVariable) {
      keyless.environmentOverlay[variable] = .some(nil)
    }
    return try await inner.run(keyless)
  }
}
