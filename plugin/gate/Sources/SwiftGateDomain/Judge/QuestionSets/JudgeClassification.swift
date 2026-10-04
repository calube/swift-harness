/// Why a classifying question set gave no level. A caller never reads a level from this: no answer
/// is no answer, never the lowest level.
public enum JudgeClassificationError: Error, Sendable, Equatable {
  /// The judge didn't answer; the text says why.
  case noAnswer(String)
  /// The judge answered, but not the question asked, or with options outside its levels.
  case unreadable(String)
}

enum JudgeLevelReading {
  /// `ask`'s answers, or `.noAnswer` naming why it threw.
  static func answers(
    _ subject: JudgeSubject, _ questions: JudgeQuestionSet,
    ask: (JudgeSubject, JudgeQuestionSet) async throws -> [JudgeAnswer]
  ) async throws(JudgeClassificationError) -> [JudgeAnswer] {
    throw .noAnswer("")
  }

  /// The most probable level of `question` in `answers`. Levels are listed worst first, so a tie
  /// reads as the worse level.
  static func level(_ question: JudgeQuestion, in answers: [JudgeAnswer])
    throws(JudgeClassificationError) -> String
  {
    throw .unreadable("")
  }
}
