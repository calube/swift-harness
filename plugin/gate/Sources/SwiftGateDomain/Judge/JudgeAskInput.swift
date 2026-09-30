import Foundation

/// What `swiftgate judge ask` reads (design §8): a question set, named or written inline in the
/// judge dataset's format, and the subjects to ask it about.
public struct JudgeAskInput: Sendable, Equatable {
  public static let schemaVersion = 1
  /// A Score question's levels past this many stop being a scale a backend can rank.
  public static let maxScoreLevels = 10
  /// Jev's limit on a Choice question's options.
  public static let maxChoiceOptions = 255

  public let questions: JudgeQuestionSet
  public let subjects: [JudgeSubject]

  public init(questions: JudgeQuestionSet, subjects: [JudgeSubject]) {
    self.questions = questions
    self.subjects = subjects
  }

  public static func decode(_ data: Data) throws(JudgeAskInputError) -> JudgeAskInput {
    JudgeAskInput(
      questions: JudgeQuestionSet(id: "", version: 0, subjectDescription: "", questions: []),
      subjects: [])
  }
}

public enum JudgeAskInputError: Error, Sendable, Equatable {
  case unsupportedSchema(Int)
  /// `field` is the JSON path of the value that's wrong, such as `subjects[2].id`.
  case invalid(field: String, reason: String)
}

extension JudgeAskInputError: CustomStringConvertible {
  public var description: String { "" }
}

/// What `swiftgate judge ask` prints: each subject's validated distribution per question and what
/// asking cost, with no policy applied.
public struct JudgeAskOutput: Sendable, Equatable {
  public static let schemaVersion = 1

  public struct Subject: Sendable, Equatable {
    public let id: String
    public let answers: [JudgeAnswer]
    /// `nil` when the backend reported none.
    public let usage: JudgeUsage?

    public init(id: String, answers: [JudgeAnswer], usage: JudgeUsage?) {
      self.id = id
      self.answers = answers
      self.usage = usage
    }
  }

  /// The versioned id of the question set asked.
  public let questionSet: String
  public let identity: JudgeIdentity
  /// In input order.
  public let subjects: [Subject]

  public init(questionSet: String, identity: JudgeIdentity, subjects: [Subject]) {
    self.questionSet = questionSet
    self.identity = identity
    self.subjects = subjects
  }

  /// Sorted keys, so the same answers always print the same bytes.
  public var json: Data { Data() }
}
