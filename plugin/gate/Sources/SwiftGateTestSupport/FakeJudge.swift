import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// A scripted ``Judge``: answers each subject with `handler` and records which subjects it was
/// asked about, so tests can prove what reached the backend (and that nothing did).
public final class FakeJudge: Judge {
  public typealias Handler =
    @Sendable (JudgeSubject, JudgeQuestionSet) throws(JudgeError) -> [JudgeAnswer]

  public let identity: JudgeIdentity
  private let handler: Handler
  private let usage: JudgeUsage?
  private let asked = Mutex<[JudgeSubject]>([])

  /// - Parameter usage: what every call reports it cost; `nil` reports only the wall time.
  public init(
    identity: JudgeIdentity = JudgeIdentity(backend: "fake", model: "fake"),
    usage: JudgeUsage? = nil, handler: @escaping Handler
  ) {
    self.identity = identity
    self.usage = usage
    self.handler = handler
  }

  public var subjects: [JudgeSubject] { asked.withLock { $0 } }

  public func answer(_ subject: JudgeSubject, questions: JudgeQuestionSet) async throws(JudgeError)
    -> [JudgeAnswer]
  {
    try await measuredAnswer(subject, questions: questions).answers
  }

  /// Reports itself like a real backend, so a route's events can be tested with fakes.
  public func measuredAnswer(_ subject: JudgeSubject, questions: JudgeQuestionSet)
    async throws(JudgeError) -> JudgeReply
  {
    try await JudgeCallEvents.observe(identity, subject: subject, questions: questions) {
      () throws(JudgeError) -> JudgeReply in
      asked.withLock { $0.append(subject) }
      let answers = try handler(subject, questions)
      do {
        return JudgeReply(
          answers: try JudgeAnswers.validate(answers, for: questions),
          usage: usage ?? JudgeUsage(wallMilliseconds: 0))
      } catch {
        throw .malformedReply("\(error)")
      }
    }
  }

  /// The same distribution for every question: `flagged` on each question's flagged option.
  public static func answering(flagged p: Double) -> FakeJudge {
    FakeJudge { subject, questions throws(JudgeError) in
      questions.questions.map { question in
        let options = question.options
        let flaggedOption: String =
          switch question.flag {
          case .option(let option): option
          case .notDeclaredTier: options.first { $0 != subject.declaredTier } ?? options[0]
          }
        let rest = options.filter { $0 != flaggedOption }
        var distribution = [flaggedOption: p]
        for option in rest { distribution[option] = (1 - p) / Double(rest.count) }
        return JudgeAnswer(question: question.id, distribution: distribution, rationale: "fake")
      }
    }
  }
}
