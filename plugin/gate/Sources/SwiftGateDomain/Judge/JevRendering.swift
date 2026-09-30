/// What a Jev sub-question's `instructions` say.
public enum JevInstructions: Sendable, Equatable {
  case text(String)
  /// Sent as an object: `question`, and `focus` when there is one.
  case prompt(question: String, focus: String?)
}

/// What 1 answer to a Jev sub-question means.
public enum JevCriterion: Sendable, Equatable {
  case text(String)
  /// Sent as `{what, examples}`.
  case examples(what: String, examples: [String])
  /// Sent as `{what, not_for}`: cases that don't count as this answer.
  case exclusions(what: String, notFor: [String])
}

/// 1 entry of a sub-question's `criteria`: `true` or `false` for a Noul, an option for a Choice.
public struct JevCriterionEntry: Sendable, Equatable {
  public let answer: String
  public let criterion: JevCriterion

  public init(_ answer: String, _ criterion: JevCriterion) {
    self.answer = answer
    self.criterion = criterion
  }
}

/// 1 narrow question Jev answers over named state fields (design §13.3).
public struct JevSubQuestion: Sendable, Equatable {
  public enum AnswerType: String, Sendable {
    case noul, choice
  }

  public let id: String
  public let type: AnswerType
  public let instructions: JevInstructions
  /// In the order written; `nil` sends no `criteria`.
  public let criteria: [JevCriterionEntry]?

  public init(
    id: String, type: AnswerType, instructions: JevInstructions, criteria: [JevCriterionEntry]?
  ) {
    self.id = id
    self.type = type
    self.instructions = instructions
    self.criteria = criteria
  }

  /// The Choice options, in the order written.
  public var options: [String] { criteria?.map(\.answer) ?? [] }
}

/// How sub-answers rebuild 1 question's distribution (design §13.3). The result is a score, not
/// the probability of a union.
public enum JevCombination: Sendable, Equatable {
  /// The question goes to Jev as written, under its own id; its answer is the distribution.
  case asked
  /// `p(no) = max(1 - p(sub))` over Noul sub-questions: any 1 failing signal is enough.
  case noWhenAnyFalse([String])
  /// `p(yes) = max(p(sub))` over Noul sub-questions.
  case yesWhenAnyTrue([String])
  /// A Choice sub-question whose options map onto the question's options.
  case optionMap(sub: String, levels: [String: String])
}

/// 1 question of a set, as Jev asks it.
public struct JevNativeQuestion: Sendable, Equatable {
  public let question: String
  public let subQuestions: [JevSubQuestion]
  public let combination: JevCombination

  public init(question: String, subQuestions: [JevSubQuestion], combination: JevCombination) {
    self.question = question
    self.subQuestions = subQuestions
    self.combination = combination
  }

  /// The keys of Jev's answers this question reads.
  public var answerKeys: [String] { [] }
}

/// 1 decoded Jev answer to a sub-question.
public enum JevSubAnswer: Sendable, Equatable {
  case noul(Double)
  case choice([String: Double])
}

public enum JevCombinationError: Error, Sendable, Equatable {
  case missing(key: String)
  case wrongType(key: String)
}

/// The Jev rendering of a question set (design §13): its sub-questions, verbatim, and the rule
/// that recombines each question.
public enum JevRendering {
  /// Where a sub-question goes in the request and comes back in the reply.
  public static func key(question: String, sub: String) -> String { "" }

  /// The rendering for `set`, or `nil` when the set has none.
  public static func questions(for set: JudgeQuestionSet) -> [JevNativeQuestion]? { nil }

  /// `test-quality@2-jev`: the sub-questions from the question design study's `questions.json`.
  public static let testQuality: [JevNativeQuestion] = []

  /// The distribution over `question`'s options that `native`'s rule gives from Jev's answers.
  public static func combine(
    _ native: JevNativeQuestion, question: JudgeQuestion, answers: [String: JevSubAnswer]
  ) throws(JevCombinationError) -> [String: Double] {
    [:]
  }
}
