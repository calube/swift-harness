import CryptoKit
import Foundation

extension JudgeBackend: Codable {}

/// What a judge event says the judged thing was, without the source itself.
public struct JudgeEventSubject: Sendable, Equatable, Codable {
  public let id: String
  public let file: String
  public let line: Int
  /// SHA-256 of the source sent, so 2 events can be shown to judge the same text.
  public let sourceSHA256: String

  public init(id: String, file: String, line: Int, sourceSHA256: String) {
    self.id = id
    self.file = file
    self.line = line
    self.sourceSHA256 = sourceSHA256
  }

  public init(_ subject: JudgeSubject) {
    self.init(
      id: subject.id, file: subject.file, line: subject.line,
      sourceSHA256: SHA256.hash(data: Data(subject.source.utf8))
        .map { String(format: "%02x", $0) }.joined())
  }
}

public struct JudgeEventQuestion: Sendable, Equatable, Codable {
  public let id: String
  /// Whether a confident answer may block at `ready`.
  public let blocking: Bool

  public init(id: String, blocking: Bool) {
    self.id = id
    self.blocking = blocking
  }
}

/// Why a call or a decision has no answer.
public struct JudgeEventError: Error, Sendable, Equatable, Codable {
  public enum Kind: String, Sendable, Codable, CaseIterable {
    case notConfigured, backend, malformedReply, stateTooLarge
    /// The request got no reply: unreachable or timed out.
    case transport
    case launchFailed, timedOut, cancelled
    /// The backend answered, but not the question asked.
    case noAnswer
    /// The backend answered without the rationale a reason needs.
    case noRationale
    /// No judge was available to ask.
    case noJudge
    /// Never asked or not used: another subject's call failed and stopped the batch.
    case abandoned
  }

  public let kind: Kind
  public let message: String

  public init(kind: Kind, message: String) {
    self.kind = kind
    self.message = message
  }
}

/// Why a backend was called.
public enum JudgeCallRole: String, Sendable, Codable, CaseIterable {
  /// The route's own question set.
  case answer
  /// Claude answering what Jev couldn't settle.
  case escalation
  /// Claude writing the reason on a block another backend decided.
  case reason
}

/// `judge.call`: 1 backend call, or 1 answer from the judge cache.
public struct JudgeCallEvent: Sendable, Equatable, Codable {
  public let role: JudgeCallRole
  public let backend: JudgeBackend
  public let model: String
  public let servedModel: String?
  /// The versioned id of the set asked.
  public let questionSet: String
  public let questions: [JudgeEventQuestion]
  public let subject: JudgeEventSubject
  /// `nil` when the call failed.
  public let answers: [JudgeAnswer]?
  public let cacheHit: Bool
  public let latencyMs: Int
  public let backendMs: Int?
  /// `nil` when the backend reported none; 0 for a cache hit.
  public let costUSD: Double?
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let error: JudgeEventError?

  public init(
    role: JudgeCallRole, backend: JudgeBackend, model: String, servedModel: String?,
    questionSet: String, questions: [JudgeEventQuestion], subject: JudgeEventSubject,
    answers: [JudgeAnswer]?, cacheHit: Bool, latencyMs: Int, backendMs: Int?, costUSD: Double?,
    inputTokens: Int?, outputTokens: Int?, error: JudgeEventError?
  ) {
    self.role = role
    self.backend = backend
    self.model = model
    self.servedModel = servedModel
    self.questionSet = questionSet
    self.questions = questions
    self.subject = subject
    self.answers = answers
    self.cacheHit = cacheHit
    self.latencyMs = latencyMs
    self.backendMs = backendMs
    self.costUSD = costUSD
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.error = error
  }
}

public enum JudgeDecision: String, Sendable, Codable, CaseIterable {
  case block, advisory, pass, error
}

/// Who wrote a decision's reason: Claude, code from a template, or nobody.
public enum JudgeReasonSource: String, Sendable, Codable, CaseIterable {
  case claude, template, none
}

public struct JudgeEventThresholds: Sendable, Equatable, Codable {
  public let advisory: Double
  public let block: Double

  public init(_ thresholds: JudgeThresholds) {
    advisory = thresholds.advisory
    block = thresholds.block
  }
}

/// What Claude said about a question Jev escalated.
public struct JudgeEscalationEvent: Sendable, Equatable, Codable {
  public let backend: JudgeBackend
  public let model: String
  public let servedModel: String?
  public let distribution: [String: Double]?
  public let p: Double?
  public let rationale: String?
  public let error: JudgeEventError?
  /// Why the question went to Claude; `nil` in events written before the cause was recorded,
  /// which all escalated as uncertain.
  public let cause: JudgeCascade.Escalation?
  /// Jev's error, when Jev's failure is the cause.
  public let jevError: JudgeEventError?

  public init(
    backend: JudgeBackend, model: String, servedModel: String?, distribution: [String: Double]?,
    p: Double?, rationale: String?, error: JudgeEventError?,
    cause: JudgeCascade.Escalation? = nil, jevError: JudgeEventError? = nil
  ) {
    self.backend = backend
    self.model = model
    self.servedModel = servedModel
    self.distribution = distribution
    self.p = p
    self.rationale = rationale
    self.error = error
    self.cause = cause
    self.jevError = jevError
  }
}

/// 1 call a decision rests on, by the id of its `judge.call` event.
public struct JudgeCallSummary: Sendable, Equatable, Codable {
  public let eventID: String
  public let role: JudgeCallRole
  public let backend: JudgeBackend
  public let model: String
  public let cacheHit: Bool
  public let latencyMs: Int
  public let costUSD: Double?
  public let error: JudgeEventError?

  public init(eventID: String, call: JudgeCallEvent) {
    self.eventID = eventID
    role = call.role
    backend = call.backend
    model = call.model
    cacheHit = call.cacheHit
    latencyMs = call.latencyMs
    costUSD = call.costUSD
    error = call.error
  }
}

/// `judge.decision`: what the gate decided about 1 question for 1 subject, and why.
public struct JudgeDecisionEvent: Sendable, Equatable, Codable {
  public let subject: JudgeEventSubject
  public let questionSet: String
  public let questionSetVersion: Int
  public let question: String
  public let blocking: Bool
  public let atReadyTier: Bool
  /// The backend asked first.
  public let backend: JudgeBackend
  public let model: String
  public let servedModel: String?
  /// The first backend's answer; `nil` when it gave none.
  public let distribution: [String: Double]?
  /// The first backend's probability of the flagged answer.
  public let p: Double?
  public let thresholds: JudgeEventThresholds
  /// `nil` when the question never escalates.
  public let band: JudgeCascade.Band?
  public let inBand: Bool?
  public let escalated: Bool
  public let escalation: JudgeEscalationEvent?
  public let decision: JudgeDecision
  public let severity: Severity?
  /// `<backend>/<model>` of the answer the decision rests on.
  public let decidedBy: String
  public let reasonSource: JudgeReasonSource
  public let reason: String?
  /// Why the reason call failed, when it did.
  public let reasonError: JudgeEventError?
  /// The deciding answer's own rationale.
  public let rationale: String?
  public let cacheHit: Bool
  public let calls: [JudgeCallSummary]
  public let error: JudgeEventError?

  public init(
    subject: JudgeEventSubject, questionSet: String, questionSetVersion: Int, question: String,
    blocking: Bool, atReadyTier: Bool, backend: JudgeBackend, model: String,
    servedModel: String?, distribution: [String: Double]?, p: Double?,
    thresholds: JudgeEventThresholds, band: JudgeCascade.Band?, inBand: Bool?, escalated: Bool,
    escalation: JudgeEscalationEvent?, decision: JudgeDecision, severity: Severity?,
    decidedBy: String, reasonSource: JudgeReasonSource, reason: String?,
    reasonError: JudgeEventError?, rationale: String?, cacheHit: Bool, calls: [JudgeCallSummary],
    error: JudgeEventError?
  ) {
    self.subject = subject
    self.questionSet = questionSet
    self.questionSetVersion = questionSetVersion
    self.question = question
    self.blocking = blocking
    self.atReadyTier = atReadyTier
    self.backend = backend
    self.model = model
    self.servedModel = servedModel
    self.distribution = distribution
    self.p = p
    self.thresholds = thresholds
    self.band = band
    self.inBand = inBand
    self.escalated = escalated
    self.escalation = escalation
    self.decision = decision
    self.severity = severity
    self.decidedBy = decidedBy
    self.reasonSource = reasonSource
    self.reason = reason
    self.reasonError = reasonError
    self.rationale = rationale
    self.cacheHit = cacheHit
    self.calls = calls
    self.error = error
  }
}

/// Builds each subject's `judge.decision` payloads from what the route asked, what came back, the
/// findings it reported and the calls it made.
public enum JudgeDecisions {
  /// 1 question about 1 subject.
  public struct Key: Sendable, Hashable {
    public let subject: String
    public let question: String

    public init(subject: String, question: String) {
      self.subject = subject
      self.question = question
    }
  }

  /// A `judge.call` event as the route saw it emitted.
  public struct RecordedCall: Sendable, Equatable {
    public let eventID: String
    public let parentID: String?
    public let call: JudgeCallEvent

    public init(eventID: String, parentID: String?, call: JudgeCallEvent) {
      self.eventID = eventID
      self.parentID = parentID
      self.call = call
    }
  }

  /// The cascade's view of 1 subject.
  public struct Cascade: Sendable, Equatable {
    public let plan: JudgeCascade.Plan
    public let claude: JudgeCascade.ClaudeOutcome
    public let claudeIdentity: JudgeIdentity
    public let bands: [String: JudgeCascade.Band]
    /// Why Jev gave no answer, when it gave none and its blocking questions went to Claude.
    public let jevError: JudgeEventError?

    public init(
      plan: JudgeCascade.Plan, claude: JudgeCascade.ClaudeOutcome, claudeIdentity: JudgeIdentity,
      bands: [String: JudgeCascade.Band], jevError: JudgeEventError? = nil
    ) {
      self.plan = plan
      self.claude = claude
      self.claudeIdentity = claudeIdentity
      self.bands = bands
      self.jevError = jevError
    }
  }

  /// What the first backend returned for 1 subject.
  public enum Outcome: Sendable, Equatable {
    case answered(identity: JudgeIdentity, answers: [JudgeAnswer], cascade: Cascade?)
    case failed(identity: JudgeIdentity, JudgeEventError)
  }

  /// How a block's reason call went.
  public enum Reason: Sendable, Equatable {
    case written
    case missing(JudgeEventError)
  }

  public struct Inputs: Sendable {
    public let subjects: [JudgeSubject]
    public let questions: JudgeQuestionSet
    public let thresholds: JudgeThresholds
    public let atReadyTier: Bool
    /// The identity a subject the route never asked about is reported under.
    public let identity: JudgeIdentity
    public let outcomes: [String: Outcome]
    /// Set when a call failed and the route reported no findings; every decision is an error.
    public let batchFailure: JudgeEventError?
    public let findings: [Finding]
    public let reasons: [Key: Reason]
    public let calls: [RecordedCall]
    /// Values no event may carry.
    public let secrets: [String]

    public init(
      subjects: [JudgeSubject], questions: JudgeQuestionSet, thresholds: JudgeThresholds,
      atReadyTier: Bool, identity: JudgeIdentity, outcomes: [String: Outcome],
      batchFailure: JudgeEventError?, findings: [Finding], reasons: [Key: Reason],
      calls: [RecordedCall], secrets: [String]
    ) {
      self.subjects = subjects
      self.questions = questions
      self.thresholds = thresholds
      self.atReadyTier = atReadyTier
      self.identity = identity
      self.outcomes = outcomes
      self.batchFailure = batchFailure
      self.findings = findings
      self.reasons = reasons
      self.calls = calls
      self.secrets = secrets
    }
  }

  /// Every (subject, question) key, in subject then question set order.
  public static func keys(_ subjects: [JudgeSubject], _ questions: JudgeQuestionSet) -> [Key] {
    subjects.flatMap { subject in
      questions.questions.map { Key(subject: subject.id, question: $0.id) }
    }
  }

  /// 1 payload per key, under the event id `ids` gives it, in ``keys(_:_:)`` order.
  public static func make(_ inputs: Inputs, ids: [Key: String]) -> [(
    eventID: String, decision: JudgeDecisionEvent
  )] {
    inputs.subjects.flatMap { subject in
      inputs.questions.questions.compactMap { question -> (String, JudgeDecisionEvent)? in
        let key = Key(subject: subject.id, question: question.id)
        guard let id = ids[key] else { return nil }
        return (id, decision(key: key, id: id, subject: subject, question: question, inputs))
      }
    }
  }

  private static func decision(
    key: Key, id: String, subject: JudgeSubject, question: JudgeQuestion, _ inputs: Inputs
  ) -> JudgeDecisionEvent {
    let secrets = inputs.secrets
    func clean(_ text: String?) -> String? { text.map { redact($0, secrets) } }
    func clean(_ error: JudgeEventError?) -> JudgeEventError? {
      error.map { JudgeEventError(kind: $0.kind, message: redact($0.message, secrets)) }
    }
    let mine = inputs.calls.filter { $0.call.subject.id == subject.id }
    let answerCall = mine.last { $0.call.role == .answer }
    let escalationCalls = mine.filter { $0.call.role == .escalation }
    let reasonCalls = mine.filter { $0.call.role == .reason && $0.parentID == id }
    let outcome = inputs.outcomes[subject.id]
    let identity: JudgeIdentity
    let answers: [JudgeAnswer]?
    let cascade: Cascade?
    var error: JudgeEventError?
    switch outcome {
    case .answered(let who, let found, let found2):
      identity = who
      answers = found
      cascade = found2
    case .failed(let who, let failure):
      identity = who
      answers = nil
      cascade = nil
      error = failure
    case nil:
      identity = inputs.identity
      answers = nil
      cascade = nil
    }
    if error == nil, let batch = inputs.batchFailure {
      error = JudgeEventError(
        kind: .abandoned, message: "the judge stopped after another call failed: \(batch.message)")
    }
    let answer = answers?.first { $0.question == question.id }
    let p = answer.flatMap {
      JudgePolicy.flaggedProbability(question, answer: $0, subject: subject)
    }
    let band = cascade?.bands[question.id]
    let escalated = cascade.map { $0.plan.step(for: question.id) != .keep } ?? false
    var escalation: JudgeEscalationEvent?
    var decidingAnswer = answer
    var decidedBy = identity
    if escalated, let cascade {
      let claudeCall = escalationCalls.last?.call
      let backend = JudgeBackend(rawValue: cascade.claudeIdentity.backend) ?? .claude
      let cause: JudgeCascade.Escalation? =
        if case .escalate(let why) = cascade.plan.step(for: question.id) { why } else { nil }
      let jevError = clean(cascade.jevError)
      switch cascade.claude {
      case .answered(let claudeAnswers):
        if let replaced = claudeAnswers.first(where: { $0.question == question.id }) {
          decidingAnswer = replaced
          decidedBy = cascade.claudeIdentity
          escalation = JudgeEscalationEvent(
            backend: backend, model: cascade.claudeIdentity.model,
            servedModel: claudeCall?.servedModel, distribution: replaced.distribution,
            p: JudgePolicy.flaggedProbability(question, answer: replaced, subject: subject),
            rationale: clean(replaced.rationale), error: nil, cause: cause, jevError: jevError)
        } else {
          escalation = JudgeEscalationEvent(
            backend: backend, model: cascade.claudeIdentity.model,
            servedModel: claudeCall?.servedModel, distribution: nil, p: nil, rationale: nil,
            error: JudgeEventError(
              kind: .noAnswer, message: "claude gave no answer for \(question.id)"),
            cause: cause, jevError: jevError)
        }
      case .failed(let why):
        escalation = JudgeEscalationEvent(
          backend: backend, model: cascade.claudeIdentity.model, servedModel: nil,
          distribution: nil, p: nil, rationale: nil,
          error: clean(claudeCall?.error ?? JudgeEventError(kind: .noJudge, message: why)),
          cause: cause, jevError: jevError)
      }
    }
    // Jev gave no answer, and no Claude answer stands in for it: nothing was decided.
    if error == nil, decidingAnswer == nil, let jevError = cascade?.jevError {
      error = jevError
    }
    let finding = inputs.findings.first {
      $0.ruleID == JudgePolicy.ruleIDPrefix + question.id && $0.file == subject.file
        && $0.line == subject.line
    }
    let decision: JudgeDecision =
      if error != nil {
        .error
      } else if let finding {
        finding.severity.failsGate ? .block : .advisory
      } else {
        .pass
      }
    let reason = error == nil ? clean(finding?.failureScenario) : nil
    var reasonError: JudgeEventError?
    let reasonSource: JudgeReasonSource
    if decision == .error || finding == nil || reason == nil {
      reasonSource = .none
    } else if let written = inputs.reasons[key] {
      switch written {
      case .written: reasonSource = .claude
      case .missing(let why):
        reasonSource = .template
        reasonError = clean(why)
      }
    } else if JudgeBackend(rawValue: decidedBy.backend)?.writesReasons == true {
      reasonSource = .claude
    } else {
      reasonSource = .template
    }
    let used = ([answerCall] + (escalated ? escalationCalls : []) + reasonCalls).compactMap { $0 }
    return JudgeDecisionEvent(
      subject: JudgeEventSubject(subject), questionSet: inputs.questions.versionedID,
      questionSetVersion: inputs.questions.version, question: question.id,
      blocking: question.mayBlock, atReadyTier: inputs.atReadyTier,
      backend: JudgeBackend(rawValue: identity.backend) ?? .claude, model: identity.model,
      servedModel: answerCall?.call.servedModel, distribution: answer?.distribution, p: p,
      thresholds: JudgeEventThresholds(inputs.thresholds), band: band,
      inBand: band.map { band in p.map(band.contains) ?? false }, escalated: escalated,
      escalation: escalation, decision: decision, severity: error == nil ? finding?.severity : nil,
      decidedBy: "\(decidedBy.backend)/\(decidedBy.model)", reasonSource: reasonSource,
      reason: reason, reasonError: reasonError, rationale: clean(decidingAnswer?.rationale),
      cacheHit: answerCall?.call.cacheHit ?? false,
      calls: used.map { JudgeCallSummary(eventID: $0.eventID, call: $0.call) }, error: clean(error))
  }

  /// `text` with every secret replaced.
  public static func redact(_ text: String, _ secrets: [String]) -> String {
    secrets.filter { !$0.isEmpty }.reduce(text) { $0.replacing($1, with: "<redacted>") }
  }
}
