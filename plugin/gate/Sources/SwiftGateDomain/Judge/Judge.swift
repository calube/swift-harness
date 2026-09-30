import CryptoKit
import Foundation

/// One typed question the judge answers with a probability distribution (spec §7.4 judge seam).
public struct JudgeQuestion: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    /// Options `yes` / `no`.
    case binary
    /// Exactly one of the options applies.
    case choice([String])
    /// Ordered levels, worst first.
    case score([String])
  }

  /// Which answer marks the subject as a problem.
  public enum Flag: Sendable, Hashable {
    /// The probability of this option.
    case option(String)
    /// One minus the probability of the subject's declared tier (for tier questions).
    case notDeclaredTier
  }

  public let id: String
  public let text: String
  public let kind: Kind
  public let flag: Flag
  /// Whether a confident answer may block at the ready tier; otherwise it is advisory only.
  public let mayBlock: Bool
  /// What the finding says when the flag fires.
  public let problem: String

  public init(
    id: String, text: String, kind: Kind, flag: Flag, mayBlock: Bool, problem: String
  ) {
    self.id = id
    self.text = text
    self.kind = kind
    self.flag = flag
    self.mayBlock = mayBlock
    self.problem = problem
  }

  public var options: [String] {
    switch kind {
    case .binary: ["yes", "no"]
    case .choice(let options), .score(let options): options
    }
  }
}

/// A versioned set of questions. Changing any question's text, options or flag is a new version,
/// which invalidates the cache and must be re-calibrated.
public struct JudgeQuestionSet: Sendable, Hashable {
  public let id: String
  public let version: Int
  /// What the backend is told the subject is.
  public let subjectDescription: String
  public let questions: [JudgeQuestion]

  public init(id: String, version: Int, subjectDescription: String, questions: [JudgeQuestion]) {
    self.id = id
    self.version = version
    self.subjectDescription = subjectDescription
    self.questions = questions
  }

  public var versionedID: String { "\(id)@\(version)" }

  public static let tests = JudgeQuestionSet(
    id: "test-quality", version: 1,
    subjectDescription:
      "a Swift test function from an iOS app built with The Composable Architecture, and the "
      + "production code change it covers",
    questions: [
      JudgeQuestion(
        id: "fails-if-broken",
        text: "Would this test fail if the behavior it names were broken?", kind: .binary,
        flag: .option("no"), mayBlock: true,
        problem: "the test would likely still pass if the behavior it names broke"),
      JudgeQuestion(
        id: "tier",
        text:
          "Which tier does this test belong in? T1: host unit test of logic (reducers, pure "
          + "functions, clients with fakes). T2: simulator test of rendering or platform "
          + "integration (snapshots, views). T3: end-to-end UI flow (XCUITest).",
        kind: .choice(["T1", "T2", "T3"]), flag: .notDeclaredTier, mayBlock: false,
        problem: "the test likely belongs in a different tier"),
      JudgeQuestion(
        id: "name-specificity",
        text:
          "How specific is the regression the test's name says it catches? vague: names no "
          + "symptom or restates the behavior; partial: names an area but not the symptom; "
          + "specific: names a user- or caller-visible symptom.",
        kind: .score(["vague", "partial", "specific"]), flag: .option("vague"), mayBlock: false,
        problem: "the regression name is vague"),
      JudgeQuestion(
        id: "asserts-implementation",
        text:
          "Does the test assert implementation details (private call order, internal state, "
          + "exact log text, which collaborator was called) rather than observable behavior?",
        kind: .binary, flag: .option("yes"), mayBlock: true,
        problem: "the test asserts implementation details rather than behavior"),
    ])

  public static let comments = JudgeQuestionSet(
    id: "comments", version: 1,
    subjectDescription: "a comment added to Swift source, with the code around it",
    questions: [
      JudgeQuestion(
        id: "loses-fact",
        text:
          "If this comment were deleted, would a reader lose a fact they cannot recover from the "
          + "code (a non-obvious why, a footgun warning, a contract, a suppression reason)?",
        kind: .binary, flag: .option("no"), mayBlock: false,
        problem: "CUT: deleting this comment loses nothing the code doesn't already say"),
      JudgeQuestion(
        id: "right-size",
        text:
          "Is the comment the right size for the fact it carries (no restated code, no history "
          + "narration, no padding)?",
        kind: .binary, flag: .option("no"), mayBlock: false,
        problem: "TRIM: the comment is larger than the fact it carries"),
    ])
}

/// What the judge is asked about.
public struct JudgeSubject: Sendable, Hashable {
  /// Stable id: a test id, or `file:line` for a comment.
  public let id: String
  public let file: String
  public let line: Int
  /// The test function or comment text.
  public let source: String
  /// The covered diff (tests) or surrounding code (comments).
  public let context: String
  /// The tier the subject lives in, for tier questions.
  public let declaredTier: String?

  public init(
    id: String, file: String, line: Int, source: String, context: String,
    declaredTier: String? = nil
  ) {
    self.id = id
    self.file = file
    self.line = line
    self.source = source
    self.context = context
    self.declaredTier = declaredTier
  }
}

/// Which backend and model answered; part of the cache key and of every finding.
public struct JudgeIdentity: Sendable, Hashable, Codable {
  public let backend: String
  public let model: String

  public init(backend: String, model: String) {
    self.backend = backend
    self.model = model
  }
}

/// One question's answer: a probability per option.
public struct JudgeAnswer: Sendable, Equatable, Codable {
  public let question: String
  public let distribution: [String: Double]
  public let rationale: String?

  public init(question: String, distribution: [String: Double], rationale: String?) {
    self.question = question
    self.distribution = distribution
    self.rationale = rationale
  }

  public func probability(of option: String) -> Double { distribution[option] ?? 0 }

  /// The most probable option; ties go to the option listed first.
  public func mostLikely(among options: [String]) -> String? {
    options.max { probability(of: $0) < probability(of: $1) }
      .flatMap { best in options.first { probability(of: $0) == probability(of: best) } }
  }
}

public enum JudgeAnswerViolation: Error, Sendable, Equatable {
  case missingQuestion(String)
  case unknownOptions(question: String, options: [String])
  case outOfRange(question: String)
  case notNormalized(question: String, sum: Double)
}

public enum JudgeAnswers {
  /// Tolerance for probabilities that should sum to 1: models round.
  public static let sumTolerance = 0.05

  /// Checks a backend's answers against the question set and renormalizes each distribution.
  public static func validate(_ answers: [JudgeAnswer], for set: JudgeQuestionSet)
    throws(JudgeAnswerViolation) -> [JudgeAnswer]
  {
    var byQuestion: [String: JudgeAnswer] = [:]
    for answer in answers { byQuestion[answer.question] = answer }
    return try set.questions.map { question throws(JudgeAnswerViolation) in
      guard let answer = byQuestion[question.id] else { throw .missingQuestion(question.id) }
      let unknown = Set(answer.distribution.keys).subtracting(question.options)
      guard unknown.isEmpty else {
        throw .unknownOptions(question: question.id, options: unknown.sorted())
      }
      guard answer.distribution.values.allSatisfy({ (0...1).contains($0) }) else {
        throw .outOfRange(question: question.id)
      }
      let sum = answer.distribution.values.reduce(0, +)
      guard abs(sum - 1) <= sumTolerance else {
        throw .notNormalized(question: question.id, sum: sum)
      }
      return JudgeAnswer(
        question: question.id,
        distribution: Dictionary(
          uniqueKeysWithValues: question.options.map { ($0, answer.probability(of: $0) / sum) }),
        rationale: answer.rationale)
    }
  }
}

/// Cache key: hash(subject source, context, question-set version, backend, model) (spec §7.4).
public enum JudgeCacheKey {
  public static func make(
    subject: JudgeSubject, questions: JudgeQuestionSet, identity: JudgeIdentity
  ) -> String {
    let fields = [
      "swiftgate-judge-cache-1", subject.source, subject.context, subject.declaredTier ?? "",
      questions.versionedID, identity.backend, identity.model,
    ]
    // Length-prefixing each field makes the encoding unambiguous without an escape scheme.
    let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined()
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// Turns answers into findings by threshold (spec §7.4 policy): `p >= block` blocks only at the
/// ready tier and only for questions allowed to block; `advisory <= p` is advisory; below is
/// ignored. The judge alone never makes a run RED below ready.
public enum JudgePolicy {
  public static let ruleIDPrefix = "judge."

  public static func findings(
    subject: JudgeSubject, answers: [JudgeAnswer], questions: JudgeQuestionSet,
    thresholds: JudgeThresholds, identity: JudgeIdentity, atReadyTier: Bool,
    blockAuthority: JudgeBlockAuthority = .standing
  ) throws(ReportContractViolation) -> [Finding] {
    let byQuestion = Dictionary(answers.map { ($0.question, $0) }, uniquingKeysWith: { a, _ in a })
    var findings: [Finding] = []
    for question in questions.questions {
      guard let answer = byQuestion[question.id],
        let p = flaggedProbability(question, answer: answer, subject: subject),
        p >= thresholds.advisory
      else { continue }
      let confident = question.mayBlock && p >= thresholds.block
      let refusal =
        confident ? blockAuthority.refusal(question: question.id, identity: identity) : nil
      let blocks = confident && atReadyTier && refusal == nil
      var message =
        "\(question.problem) (p=\(String(format: "%.2f", p)), \(identity.backend)/\(identity.model))"
      if let refusal {
        message +=
          "; advisory: \(identity.backend) has no passing block calibration for \(question.id) "
          + "on \(identity.model): \(refusal)"
      } else if confident, !blocks {
        message += "; blocks at the ready tier"
      }
      findings.append(
        try Finding(
          ruleID: ruleIDPrefix + question.id, severity: blocks ? .major : .minor,
          file: subject.file, line: subject.line, message: message,
          failureScenario: answer.rationale))
    }
    return findings
  }

  /// The probability that the subject has the problem this question looks for, or `nil` when
  /// the question can't be applied (a tier question with no declared tier).
  public static func flaggedProbability(
    _ question: JudgeQuestion, answer: JudgeAnswer, subject: JudgeSubject
  ) -> Double? {
    switch question.flag {
    case .option(let option): return answer.probability(of: option)
    case .notDeclaredTier:
      guard let tier = subject.declaredTier else { return nil }
      return 1 - answer.probability(of: tier)
    }
  }
}
