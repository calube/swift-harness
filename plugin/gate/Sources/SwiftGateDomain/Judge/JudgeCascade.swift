/// Jev answers first, and per question this decides whether its answer stands or goes to Claude
/// (spec §13.5). An escalated answer is Claude's; a kept Jev answer blocks as Claude's would.
public enum JudgeCascade {
  /// The flagged probabilities too uncertain for Jev's answer to stand.
  public struct Band: Sendable, Equatable, Codable {
    public let lower: Double
    public let upper: Double

    public init(lower: Double, upper: Double) {
      self.lower = lower
      self.upper = upper
    }

    /// Open at both ends: an answer on an edge is confident enough to stand.
    public func contains(_ p: Double) -> Bool {
      lower < p && p < upper
    }
  }

  /// Versioned question set id, then question id, to its band. A question with no band never
  /// escalates as uncertain.
  /// Each band is the one the committed benchmark's tune-split sweep picked, as its summary states;
  /// a test holds the two together.
  public static let bands: [String: [String: Band]] = [
    "test-quality@2-jev": [
      "fails-if-broken": Band(lower: 0.4, upper: 0.9),
      "asserts-implementation": Band(lower: 0.3, upper: 0.95),
    ]
  ]

  public static func bands(for versionedID: String) -> [String: Band] {
    bands[versionedID] ?? [:]
  }

  public enum Escalation: String, Sendable, Equatable, Codable, CaseIterable {
    /// Jev's flagged probability lies inside the question's band.
    case uncertain
    /// Jev gave no answer at all: no key, no reply, or a reply that couldn't be read.
    case jevFailed
  }

  /// Neither backend answered a blocking question at `ready`, so the gate has no evidence either
  /// way: BLOCKED, never RED.
  public static let blockedRuleID = "judge.blocked"

  public enum Step: Sendable, Equatable {
    case keep
    case escalate(Escalation)
  }

  /// Each question's step, in question set order.
  public struct Plan: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
      public let question: String
      public let step: Step

      public init(question: String, step: Step) {
        self.question = question
        self.step = step
      }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
      self.entries = entries
    }

    public func step(for question: String) -> Step {
      entries.first { $0.question == question }?.step ?? .keep
    }

    /// The questions to ask Claude, in question set order.
    public var escalated: [String] {
      entries.compactMap { $0.step == .keep ? nil : $0.question }
    }

    public var escalations: [String: Escalation] {
      Dictionary(
        uniqueKeysWithValues: entries.compactMap { entry in
          guard case .escalate(let why) = entry.step else { return nil }
          return (entry.question, why)
        })
    }
  }

  /// What Claude returned for a subject's escalated questions.
  public enum ClaudeOutcome: Sendable, Equatable {
    case answered([JudgeAnswer])
    /// Claude couldn't answer at all; the reason names why.
    case failed(String)
  }

  /// 1 question's answer with the identity that decided it.
  public struct Decided: Sendable, Equatable {
    public let answer: JudgeAnswer
    public let identity: JudgeIdentity
    public let escalation: Escalation?
    /// Why an escalated question kept Jev's answer; `nil` when Claude answered or none was asked.
    public let escalationFailure: String?

    public init(
      answer: JudgeAnswer, identity: JudgeIdentity, escalation: Escalation?,
      escalationFailure: String?
    ) {
      self.answer = answer
      self.identity = identity
      self.escalation = escalation
      self.escalationFailure = escalationFailure
    }
  }

  /// Decides each question's step from Jev's answers: a blocking question whose flagged
  /// probability lies in its band escalates, and every other answer stands.
  public static func plan(
    subject: JudgeSubject, jev: [JudgeAnswer], questions: JudgeQuestionSet,
    bands: [String: Band], thresholds: JudgeThresholds, atReadyTier: Bool
  ) -> Plan {
    let byQuestion = Dictionary(jev.map { ($0.question, $0) }, uniquingKeysWith: { a, _ in a })
    return Plan(
      entries: questions.questions.map { question in
        guard question.mayBlock, let answer = byQuestion[question.id],
          let p = JudgePolicy.flaggedProbability(question, answer: answer, subject: subject),
          bands[question.id]?.contains(p) == true
        else { return Plan.Entry(question: question.id, step: .keep) }
        return Plan.Entry(question: question.id, step: .escalate(.uncertain))
      })
  }

  /// Each answered question's answer, from Claude when it escalated and Claude answered it, else
  /// from Jev.
  public static func merge(
    plan: Plan, jev: [JudgeAnswer], claude: ClaudeOutcome, jevIdentity: JudgeIdentity,
    claudeIdentity: JudgeIdentity
  ) -> [Decided] {
    jev.map { answer in
      guard case .escalate(let why) = plan.step(for: answer.question) else {
        return Decided(
          answer: answer, identity: jevIdentity, escalation: nil, escalationFailure: nil)
      }
      switch claude {
      case .failed(let reason):
        return Decided(
          answer: answer, identity: jevIdentity, escalation: why, escalationFailure: reason)
      case .answered(let answers):
        guard let replaced = answers.first(where: { $0.question == answer.question }) else {
          return Decided(
            answer: answer, identity: jevIdentity, escalation: why,
            escalationFailure: "claude gave no answer for \(answer.question)")
        }
        return Decided(
          answer: replaced, identity: claudeIdentity, escalation: why, escalationFailure: nil)
      }
    }
  }

  /// The findings for the merged answers, each under the identity that decided it; a failed
  /// escalation's Jev answer never above minor.
  public static func findings(
    subject: JudgeSubject, plan: Plan, jev: [JudgeAnswer], claude: ClaudeOutcome,
    questions: JudgeQuestionSet, jevIdentity: JudgeIdentity, claudeIdentity: JudgeIdentity,
    thresholds: JudgeThresholds, atReadyTier: Bool
  ) throws(ReportContractViolation) -> [Finding] {
    let decided = merge(
      plan: plan, jev: jev, claude: claude, jevIdentity: jevIdentity,
      claudeIdentity: claudeIdentity)
    let byClaude = decided.filter { $0.escalation != nil && $0.escalationFailure == nil }
    let byJev = decided.filter { $0.escalation == nil || $0.escalationFailure != nil }
    let failures = Dictionary(
      byJev.compactMap { item in
        item.escalation.flatMap { why in
          item.escalationFailure.map { (item.answer.question, (why, $0)) }
        }
      }, uniquingKeysWith: { a, _ in a })
    let jevFindings = try JudgePolicy.findings(
      subject: subject, answers: byJev.map(\.answer), questions: questions,
      thresholds: thresholds, identity: jevIdentity, atReadyTier: atReadyTier
    ).map { finding throws(ReportContractViolation) in
      let question = String(finding.ruleID.dropFirst(JudgePolicy.ruleIDPrefix.count))
      guard let (why, reason) = failures[question] else { return finding }
      // Claude was asked because Jev's answer couldn't stand, so it never blocks on its own.
      return try Finding(
        ruleID: finding.ruleID, severity: .minor, file: finding.file, line: finding.line,
        message: finding.message + "; escalated to claude as \(describe(why)), which failed: "
          + reason,
        failureScenario: finding.failureScenario)
    }
    let claudeFindings = try JudgePolicy.findings(
      subject: subject, answers: byClaude.map(\.answer), questions: questions,
      thresholds: thresholds, identity: claudeIdentity, atReadyTier: atReadyTier)
    let order = Dictionary(
      questions.questions.enumerated().map { (JudgePolicy.ruleIDPrefix + $1.id, $0) },
      uniquingKeysWith: { a, _ in a })
    return (jevFindings + claudeFindings).sorted {
      (order[$0.ruleID] ?? .max) < (order[$1.ruleID] ?? .max)
    }
  }

  static func describe(_ escalation: Escalation) -> String {
    switch escalation {
    case .uncertain: "uncertain"
    case .jevFailed: "jev gave no answer"
    }
  }

  /// The plan when Jev gave no answer: every blocking question goes to Claude, and every advisory
  /// question stays unasked.
  public static func jevFailedPlan(questions: JudgeQuestionSet) -> Plan {
    Plan(
      entries: questions.questions.map {
        Plan.Entry(question: $0.id, step: $0.mayBlock ? .escalate(.jevFailed) : .keep)
      })
  }

  /// The findings when Jev gave no answer (`jevError` says why): Claude's on the blocking
  /// questions, or, when Claude failed too, 1 ``blockedRuleID`` finding naming both errors.
  public static func jevFailedFindings(
    subject: JudgeSubject, jevError: String, claude: ClaudeOutcome, questions: JudgeQuestionSet,
    claudeIdentity: JudgeIdentity, thresholds: JudgeThresholds
  ) throws(ReportContractViolation) -> [Finding] {
    let blocking = questions.questions.filter(\.mayBlock).map(\.id)
    func blocked(_ ids: [String], claudeError: String) throws(ReportContractViolation) -> Finding {
      try Finding(
        ruleID: blockedRuleID, severity: .minor, file: subject.file, line: subject.line,
        message:
          "neither judge answered \(subject.id) on \(ids.joined(separator: ", ")): jev: "
          + "\(jevError); claude: \(claudeError). Ready stays BLOCKED until 1 of them can answer",
        failureScenario: nil)
    }
    guard !blocking.isEmpty else { return [] }
    switch claude {
    case .failed(let why):
      return [try blocked(blocking, claudeError: why)]
    case .answered(let answers):
      let answered = answers.filter { blocking.contains($0.question) }
      let missing = blocking.filter { id in !answered.contains { $0.question == id } }
      let found = try JudgePolicy.findings(
        subject: subject, answers: answered, questions: questions, thresholds: thresholds,
        identity: claudeIdentity, atReadyTier: true
      ).map { finding throws(ReportContractViolation) in
        try Finding(
          ruleID: finding.ruleID, severity: finding.severity, file: finding.file,
          line: finding.line,
          message: finding.message + "; escalated to claude because jev gave no answer: "
            + jevError,
          failureScenario: finding.failureScenario)
      }
      guard !missing.isEmpty else { return found }
      return found
        + [
          try blocked(
            missing,
            claudeError: "claude gave no answer for \(missing.joined(separator: ", "))")
        ]
    }
  }

  /// What 1 subject's cascade asked and what it cost, so the benchmark can report the escalation
  /// share and the combined cost and latency.
  public struct Record: Sendable, Equatable, Codable {
    public let escalations: [String: Escalation]
    public let jev: JudgeUsage?
    /// `nil` when nothing escalated, or when Claude reported no usage.
    public let claude: JudgeUsage?

    public init(escalations: [String: Escalation], jev: JudgeUsage?, claude: JudgeUsage?) {
      self.escalations = escalations
      self.jev = jev
      self.claude = claude
    }

    /// Both calls' cost; `nil` when a call that ran reported none.
    public var costUSD: Double? {
      guard let jevCost = jev?.costUSD else { return nil }
      guard !escalations.isEmpty else { return jevCost }
      return claude?.costUSD.map { jevCost + $0 }
    }

    /// Both calls' wall time, which run 1 after the other; `nil` when a call that ran reported
    /// none.
    public var wallMilliseconds: Int? {
      guard let jevWall = jev?.wallMilliseconds else { return nil }
      guard !escalations.isEmpty else { return jevWall }
      return claude.map { jevWall + $0.wallMilliseconds }
    }
  }

  /// 1 candidate band scored on tune-split cases.
  public struct BandPoint: Sendable, Equatable, Codable {
    public let band: Band
    /// Cases whose mean flagged probability lies inside the band.
    public let escalated: JudgeProportion
    /// Of the cases outside the band, those whose decision at the threshold matches the label.
    public let keptCorrect: JudgeProportion

    public init(band: Band, escalated: JudgeProportion, keptCorrect: JudgeProportion) {
      self.band = band
      self.escalated = escalated
      self.keptCorrect = keptCorrect
    }
  }

  /// Scores candidate bands for 1 question. It takes only tune cases, so no band is fitted to the
  /// cases the benchmark reports.
  public static func sweep(
    _ question: JudgeQuestion, cases: JudgeTuneCases, run: JudgeBenchmarkRun, threshold: Double,
    bands: [Band]
  ) -> [BandPoint] {
    let (scored, _) = JudgeBenchmarkMetrics.score(question, cases: cases.cases, run: run)
    return bands.map { band in
      let kept = scored.filter { !band.contains($0.meanFlagged) }
      return BandPoint(
        band: band,
        escalated: JudgeProportion(count: scored.count - kept.count, n: scored.count),
        keptCorrect: JudgeProportion(
          count: kept.filter { $0.decision(at: threshold) == $0.positive }.count, n: kept.count))
    }
  }
}
