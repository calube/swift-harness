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
  private let asked = Mutex<[JudgeSubject]>([])

  public init(
    identity: JudgeIdentity = JudgeIdentity(backend: "fake", model: "fake"),
    handler: @escaping Handler
  ) {
    self.identity = identity
    self.handler = handler
  }

  public var subjects: [JudgeSubject] { asked.withLock { $0 } }

  public func answer(_ subject: JudgeSubject, questions: JudgeQuestionSet) async throws(JudgeError)
    -> [JudgeAnswer]
  {
    asked.withLock { $0.append(subject) }
    let answers = try handler(subject, questions)
    do {
      return try JudgeAnswers.validate(answers, for: questions)
    } catch {
      throw .malformedReply("\(error)")
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
