/// Jev answers first, and per question this decides whether its answer stands or goes to Claude
/// (spec §13.5). An escalated answer is Claude's and carries Claude's authority; a kept Jev answer
/// blocks only under its block calibration.
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
      false
    }
  }

  /// Versioned question set id, then question id, to its band. A question with no band never
  /// escalates as uncertain.
  public static let bands: [String: [String: Band]] = [:]

  public static func bands(for versionedID: String) -> [String: Band] {
    [:]
  }

  public enum Escalation: String, Sendable, Equatable, Codable {
    /// Jev's flagged probability lies inside the question's band.
    case uncertain
    /// Jev's answer would block, and its block calibration doesn't pass.
    case uncalibratedBlock
  }

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
      .keep
    }

    /// The questions to ask Claude, in question set order.
    public var escalated: [String] {
      []
    }

    public var escalations: [String: Escalation] {
      [:]
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

  /// Decides each question's step from Jev's answers.
  public static func plan(
    subject: JudgeSubject, jev: [JudgeAnswer], questions: JudgeQuestionSet,
    bands: [String: Band], blockDecisions: [String: JudgeBlockCalibration.Decision],
    thresholds: JudgeThresholds, atReadyTier: Bool
  ) -> Plan {
    Plan(entries: [])
  }

  /// Each answered question's answer, from Claude when it escalated and Claude answered it, else
  /// from Jev.
  public static func merge(
    plan: Plan, jev: [JudgeAnswer], claude: ClaudeOutcome, jevIdentity: JudgeIdentity,
    claudeIdentity: JudgeIdentity
  ) -> [Decided] {
    []
  }

  /// The findings for the merged answers: Jev's under its block decisions, Claude's with standing
  /// authority, and a failed escalation's Jev answer never above minor.
  public static func findings(
    subject: JudgeSubject, plan: Plan, jev: [JudgeAnswer], claude: ClaudeOutcome,
    questions: JudgeQuestionSet, jevIdentity: JudgeIdentity, claudeIdentity: JudgeIdentity,
    blockDecisions: [String: JudgeBlockCalibration.Decision], thresholds: JudgeThresholds,
    atReadyTier: Bool
  ) throws(ReportContractViolation) -> [Finding] {
    []
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
      nil
    }

    /// Both calls' wall time, which run 1 after the other; `nil` when a call that ran reported
    /// none.
    public var wallMilliseconds: Int? {
      nil
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
    []
  }
}
