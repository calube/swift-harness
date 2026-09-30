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
  public var answerKeys: [String] {
    guard combination != .asked else { return [question] }
    return subQuestions.map { JevRendering.key(question: question, sub: $0.id) }
  }
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
  public static func key(question: String, sub: String) -> String { "\(question).\(sub)" }

  /// The rendering for `set`, or `nil` when the set has none: a set rendered for Jev whose base
  /// has no sub-questions written for it has none either.
  public static func questions(for set: JudgeQuestionSet) -> [JevNativeQuestion]? {
    guard set.rendering == .jev else { return nil }
    switch set.basedOn {
    case JudgeQuestionSet.tests.versionedID?: return testQuality
    default: return nil
    }
  }

  /// The distribution over `question`'s options that `native`'s rule gives from Jev's answers.
  public static func combine(
    _ native: JevNativeQuestion, question: JudgeQuestion, answers: [String: JevSubAnswer]
  ) throws(JevCombinationError) -> [String: Double] {
    switch native.combination {
    case .asked:
      switch try answer(question.id, in: answers) {
      case .noul(let p): return ["yes": p, "no": 1 - p]
      case .choice(let probabilities): return probabilities
      }
    case .noWhenAnyFalse(let subs):
      var pNo = 0.0
      for sub in subs {
        pNo = max(pNo, 1 - (try noul(key(question: native.question, sub: sub), in: answers)))
      }
      return ["no": pNo, "yes": 1 - pNo]
    case .yesWhenAnyTrue(let subs):
      var pYes = 0.0
      for sub in subs {
        pYes = max(pYes, try noul(key(question: native.question, sub: sub), in: answers))
      }
      return ["yes": pYes, "no": 1 - pYes]
    case .optionMap(let sub, let levels):
      let key = key(question: native.question, sub: sub)
      guard case .choice(let probabilities) = try answer(key, in: answers) else {
        throw .wrongType(key: key)
      }
      var mapped: [String: Double] = [:]
      for (option, p) in probabilities {
        guard let level = levels[option] else { throw .wrongType(key: key) }
        mapped[level, default: 0] += p
      }
      return mapped
    }
  }

  /// The template reason for `native`'s combined answer (design §13.3): the sub-question whose
  /// answer set the value, what that answer means, and its probability. `nil` for a question Jev
  /// is asked as written, or when a sub-answer is missing.
  public static func reason(_ native: JevNativeQuestion, answers: [String: JevSubAnswer])
    -> String?
  {
    nil
  }

  private static func answer(_ key: String, in answers: [String: JevSubAnswer])
    throws(JevCombinationError) -> JevSubAnswer
  {
    guard let answer = answers[key] else { throw .missing(key: key) }
    return answer
  }

  private static func noul(_ key: String, in answers: [String: JevSubAnswer])
    throws(JevCombinationError) -> Double
  {
    guard case .noul(let p) = try answer(key, in: answers) else { throw .wrongType(key: key) }
    return p
  }

  /// `test-quality@2-jev` (design §13.3): the sub-questions verbatim from the question design
  /// study's `questions.json`. Any change to their wording is a new version.
  public static let testQuality: [JevNativeQuestion] = [
    JevNativeQuestion(
      question: "fails-if-broken",
      subQuestions: [
        JevSubQuestion(
          id: "runs-changed-code", type: .noul,
          instructions: .prompt(
            question:
              "Does `test_source` run a function, property or reducer action that "
              + "`code_under_test` adds or modifies?",
            focus:
              "Calling a method on a fake, stub, mock or spy does not count, even when the method "
              + "has the same name as changed code."),
          criteria: [
            JevCriterionEntry(
              "true", .text("The test runs at least one line the change adds or modifies.")),
            JevCriterionEntry(
              "false",
              .examples(
                what: "The test never runs the changed lines",
                examples: [
                  "it only calls closures, fakes, stubs, mocks or spies it set up itself",
                  "it calls a method on a test double that has the same name as the changed "
                    + "function",
                  "it calls code the change does not touch",
                ])),
          ]),
        JevSubQuestion(
          id: "checks-named-result", type: .noul,
          instructions: .prompt(
            question:
              "Does an assertion in `assertions` compare the result that `test_name.behavior` "
              + "describes with an expected value?",
            focus:
              "Find the value or state the name talks about, then look for an assertion on it."),
          criteria: [
            JevCriterionEntry(
              "true",
              .examples(
                what: "An assertion checks the very value, state or output the name talks about",
                examples: [
                  "the name is about a total and the test asserts the total",
                  "the name is about a message shown and the test asserts that message in state",
                  "the name says a method is called and the test asserts the call",
                ])),
            JevCriterionEntry(
              "false",
              .examples(
                what: "The result the name describes is never compared",
                examples: [
                  "the assertions check other fields of the same object",
                  "the assertions check setup values or a test double's own value",
                  "the only assertion checks that something exists or is true",
                ])),
          ]),
      ],
      combination: .noWhenAnyFalse(["runs-changed-code", "checks-named-result"])),
    JevNativeQuestion(question: "tier", subQuestions: [], combination: .asked),
    JevNativeQuestion(
      question: "name-specificity",
      subQuestions: [
        JevSubQuestion(
          id: "catches-adds", type: .choice,
          instructions: .prompt(
            question: "What does `test_name.catches` say beyond `test_name.behavior`?",
            focus: "Judge the wording of the name only."),
          criteria: [
            JevCriterionEntry(
              "nothing",
              .examples(
                what:
                  "Only that the behavior fails, breaks or does not happen, or failures, bugs, "
                  + "problems or regressions in general; or there is no catches part",
                examples: [
                  "fetchUser returns the user — catches fetchUser not returning the user",
                  "settings works — catches settings bugs",
                  "encodes the date — catches encoding failures",
                  "testRefresh",
                ])),
            JevCriterionEntry(
              "condition",
              .examples(
                what:
                  "A specific input, case or area where it goes wrong, but not what anyone would "
                  + "see",
                examples: [
                  "catches a bug in leap years",
                  "catches wrong handling of offline mode",
                ])),
            JevCriterionEntry(
              "symptom",
              .examples(
                what: "What a user or caller would see go wrong",
                examples: [
                  "catches shoppers billed twice for one order",
                  "catches the map staying blank after location access is granted",
                ])),
          ])
      ],
      combination: .optionMap(
        sub: "catches-adds",
        levels: ["nothing": "vague", "condition": "partial", "symptom": "specific"])),
    JevNativeQuestion(
      question: "asserts-implementation",
      subQuestions: [
        JevSubQuestion(
          id: "call-details", type: .noul,
          instructions: .prompt(
            question:
              "Does an assertion in `assertions` check how many times, in what order, or with "
              + "which arguments the production code called a collaborator, spy or helper?",
            focus: nil),
          criteria: [
            JevCriterionEntry(
              "true",
              .examples(
                what:
                  "Asserts a call count, a call order, a call's arguments, or that a method was "
                  + "called",
                examples: [
                  #"#expect(mock.methodsCalled == ["connect", "send"])"#,
                  "#expect(api.requestCount == 2)",
                  "#expect(queue.didCallFlush)",
                ])),
            JevCriterionEntry(
              "false",
              .exclusions(
                what: "Asserts results the feature produces",
                notFor: [
                  "the test itself calling a mock or stub and comparing what it returns",
                  "the value the feature saves, sends or shows when that value is the feature's "
                    + "result",
                  "TestStore send or receive with the state it produces",
                  "advancing a test clock and checking what happened after the delay",
                ])),
          ]),
        JevSubQuestion(
          id: "private-state", type: .noul,
          instructions: .text(
            "Does an entry in `assertions` read a private, underscored or testing-only property "
              + "that callers of the code cannot see?"),
          criteria: [
            JevCriterionEntry(
              "true",
              .text(
                "Reads a property like `_pendingQueue` or `_retainCountForTesting`, or other "
                  + "internal bookkeeping.")),
            JevCriterionEntry(
              "false", .text("Reads only public results, returned values, or TestStore state.")),
          ]),
        JevSubQuestion(
          id: "log-text", type: .noul,
          instructions: .text(
            "Does an entry in `assertions` compare the exact text of a log or debug message?"),
          criteria: nil),
      ],
      combination: .yesWhenAnyTrue(["call-details", "private-state", "log-text"])),
  ]
}
