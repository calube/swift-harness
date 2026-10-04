extension JudgeQuestionSet {
  /// `mayBlock` because a `blocking` answer stops a merge: when Jev gives no answer, the cascade
  /// sends the question to Claude instead of leaving it unasked.
  public static let findingSeverity = JudgeQuestionSet(
    id: "finding-severity", version: 1,
    subjectDescription: "1 code review finding about a change, with the diff it was raised on",
    questions: [
      JudgeQuestion(
        id: FindingSeverity.questionID,
        text:
          "How severe is this review finding? blocking: the change must not merge as it is (a "
          + "defect users hit in ordinary use, data loss, a security hole, a broken build or "
          + "test); major: a real defect or design problem to fix before merging, with a narrow "
          + "trigger; minor: worth fixing, but safe to merge; nit: style, naming or preference.",
        kind: .score(FindingSeverity.levels.map(\.option)), flag: .option("blocking"),
        mayBlock: true, problem: "the finding blocks the merge",
        levelDescriptions: [
          "blocking: the change must not merge as it is (a defect users hit in ordinary use, data "
            + "loss, a security hole, a broken build or test)",
          "major: a real defect or design problem to fix before merging, with a narrow trigger",
          "minor: worth fixing, but safe to merge",
          "nit: style, naming or preference",
        ])
    ])
}

public enum FindingSeverity {
  public static let questionID = "severity"

  /// Each level as the question names it, worst first, with the severity it reads as.
  static let levels: [(option: String, severity: Severity)] = [
    ("blocking", .blocker), ("major", .major), ("minor", .minor), ("nit", .nit),
  ]

  /// What the judge reads: the finding's message and failure scenario as the subject, and the
  /// diff it was raised on as context. The finding's own severity stays out, so the judge can't
  /// echo it.
  public static func subject(_ finding: Finding, diff: String) -> JudgeSubject {
    let location = finding.line.map { "\(finding.file):\($0)" } ?? finding.file
    let scenario = finding.failureScenario.map { "\n\nFailure scenario: \($0)" } ?? ""
    return JudgeSubject(
      id: "\(location) \(finding.ruleID)", file: finding.file, line: finding.line ?? 1,
      source: "\(finding.ruleID) at \(location): \(finding.message)\(scenario)", context: diff)
  }

  public static func severity(from answers: [JudgeAnswer]) throws(JudgeClassificationError)
    -> Severity
  {
    let question = JudgeQuestionSet.findingSeverity.questions[0]
    let level = try JudgeLevelReading.level(question, in: answers)
    guard let severity = levels.first(where: { $0.option == level })?.severity else {
      throw .unreadable("\(question.id) answered \(level), which isn't a severity")
    }
    return severity
  }

  /// Rates `finding`. `ask` is the judge, normally the cascade.
  public static func classify(
    _ finding: Finding, diff: String,
    ask: (JudgeSubject, JudgeQuestionSet) async throws -> [JudgeAnswer]
  ) async throws(JudgeClassificationError) -> Severity {
    let answers = try await JudgeLevelReading.answers(
      subject(finding, diff: diff), .findingSeverity, ask: ask)
    return try severity(from: answers)
  }
}
