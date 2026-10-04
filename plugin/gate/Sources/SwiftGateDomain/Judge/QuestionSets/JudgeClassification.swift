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
    do {
      return try await ask(subject, questions)
    } catch {
      throw .noAnswer("\(error)")
    }
  }

  /// The most probable level of `question` in `answers`. Levels are listed worst first, so a tie
  /// reads as the worse level.
  static func level(_ question: JudgeQuestion, in answers: [JudgeAnswer])
    throws(JudgeClassificationError) -> String
  {
    guard let answer = answers.first(where: { $0.question == question.id }) else {
      throw .unreadable(
        "no answer for \(question.id); answered \(answers.map(\.question).sorted())")
    }
    let unknown = Set(answer.distribution.keys).subtracting(question.options)
    guard unknown.isEmpty else {
      throw .unreadable(
        "\(question.id) answered \(unknown.sorted()), outside its levels \(question.options)")
    }
    guard answer.distribution.values.contains(where: { $0 > 0 }),
      let level = answer.mostLikely(among: question.options)
    else { throw .unreadable("\(question.id) put no weight on any level") }
    return level
  }
}
