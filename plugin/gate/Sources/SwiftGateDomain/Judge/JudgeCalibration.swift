import Foundation

/// The labeled calibration set under `gate/Fixtures/judge/` (spec §7.4): each case names the
/// answer a correct judge gives per question.
public struct JudgeCalibrationSet: Sendable, Equatable, Codable {
  public struct Case: Sendable, Equatable, Codable {
    public enum Label: String, Sendable, Codable {
      case good
      case useless
    }

    /// Who chose the case's labels. Only a person's labels count toward person-labelled metrics.
    public enum Labeller: String, Sendable, Codable {
      case person
      case agent
    }

    public let id: String
    public let label: Label
    public let declaredTier: String
    /// Question id → the option a correct judge picks.
    public let expected: [String: String]
    public let labeller: Labeller

    public init(
      id: String, label: Label, declaredTier: String, expected: [String: String],
      labeller: Labeller = .agent
    ) {
      self.id = id
      self.label = label
      self.declaredTier = declaredTier
      self.expected = expected
      self.labeller = labeller
    }

    private enum CodingKeys: String, CodingKey {
      case id, label, declaredTier, expected, labeller
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(String.self, forKey: .id)
      label = try container.decode(Label.self, forKey: .label)
      declaredTier = try container.decode(String.self, forKey: .declaredTier)
      expected = try container.decode([String: String].self, forKey: .expected)
      // A case without a labeller carries the tuning agent's labels.
      labeller = try container.decodeIfPresent(Labeller.self, forKey: .labeller) ?? .agent
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      try container.encode(label, forKey: .label)
      try container.encode(declaredTier, forKey: .declaredTier)
      try container.encode(expected, forKey: .expected)
      try container.encode(labeller, forKey: .labeller)
    }
  }

  public let schema: Int
  public let questionSet: String
  public let cases: [Case]

  public init(schema: Int = 1, questionSet: String, cases: [Case]) {
    self.schema = schema
    self.questionSet = questionSet
    self.cases = cases
  }
}

/// Minimum precision and recall per question; `self-test --judge` fails below them. One baseline
/// per backend, beside that backend's recording.
public struct JudgeBaseline: Sendable, Equatable, Codable {
  public struct Minimum: Sendable, Equatable, Codable {
    public let precision: Double
    public let recall: Double

    public init(precision: Double, recall: Double) {
      self.precision = precision
      self.recall = recall
    }
  }

  public let questionSet: String
  public let minimums: [String: Minimum]
  /// The model ids that answered when the minimums were set, sorted; `nil` in a baseline set
  /// before served models were recorded.
  public let servedModels: [String]?

  public init(questionSet: String, minimums: [String: Minimum], servedModels: [String]? = nil) {
    self.questionSet = questionSet
    self.minimums = minimums
    self.servedModels = servedModels
  }
}

/// A backend's answers to the calibration set as `self-test --judge --record` writes them: the
/// requested identity, the model ids that actually answered, and each subject's usage. The same
/// file decodes as a ``JudgeRecording`` too, since that ignores the extra keys.
public struct JudgeCalibrationRecording: Sendable, Equatable, Codable {
  public let questionSet: String
  /// The requested backend and model, which may be an alias.
  public let identity: JudgeIdentity
  /// Every model id the replies name as having answered, sorted; `nil` when no reply named one.
  public let servedModels: [String]?
  public let answers: [String: [JudgeAnswer]]
  /// Subject id → what answering it cost; `nil` in a recording written before usage was kept.
  public let usage: [String: JudgeUsage]?

  public init(
    questionSet: String, identity: JudgeIdentity, servedModels: [String]?,
    answers: [String: [JudgeAnswer]], usage: [String: JudgeUsage]?
  ) {
    self.questionSet = questionSet
    self.identity = identity
    self.servedModels = servedModels
    self.answers = answers
    self.usage = usage
  }

  /// From live replies, taking the served models and usage from each reply's usage.
  public init(questionSet: String, identity: JudgeIdentity, replies: [String: JudgeReply]) {
    let served = Set(replies.values.compactMap { $0.usage?.servedModel }).sorted()
    self.init(
      questionSet: questionSet, identity: identity, servedModels: served.isEmpty ? nil : served,
      answers: replies.mapValues(\.answers), usage: replies.compactMapValues(\.usage))
  }

  /// The recording as 1 benchmark repeat, so the benchmark's metrics can score it.
  public var run: JudgeBenchmarkRun {
    JudgeBenchmarkRun(
      identity: identity,
      repeats: [
        Dictionary(
          uniqueKeysWithValues: answers.map { id, found in
            (id, [JudgeReply(answers: found, usage: usage?[id])])
          })
      ])
  }
}

/// Why a recording may no longer describe the backend it names (spec §10.8).
public enum JudgeRecordingStaleness: Sendable, Equatable {
  /// The file holds another backend's answers.
  case wrongBackend(file: String, expected: JudgeBackend, found: JudgeIdentity)
  /// A pinned backend's recording asked for a model other than the current pin.
  case offPin(file: String, found: JudgeIdentity, pin: String)
  /// A pinned backend's recording was answered by a model other than the current pin.
  case servedOffPin(file: String, served: [String], pin: String)
  /// The file names no served model, so staleness can't be checked offline.
  case servedUnrecorded(file: String)
  /// The recording was answered by other models than the ones its baseline was set against.
  case baselineServedDiffers(
    file: String, baselineFile: String, baseline: [String], recording: [String])
  /// The live backend now serves other models than the ones that answered the recording.
  case liveServedDiffers(file: String, recording: [String], live: [String])
  /// The recording answers another question set version than the one its backend is asked now.
  case questionSetDiffers(file: String, found: String, expected: String)
  /// Labelled cases the recording has no answer for, so they aren't scored.
  case labelledNotRecorded(file: String, backend: JudgeBackend, cases: Int)

  /// Whether the finding fails the gate. A missing served model or unrecorded labels only
  /// narrow what self-test can check, and fixing them needs a live call, so they're notes.
  public var gates: Bool {
    switch self {
    case .wrongBackend, .offPin, .servedOffPin, .baselineServedDiffers, .liveServedDiffers,
      .questionSetDiffers:
      true
    case .servedUnrecorded, .labelledNotRecorded: false
    }
  }

  /// The file the finding is about.
  public var file: String {
    switch self {
    case .wrongBackend(let file, _, _), .offPin(let file, _, _), .servedOffPin(let file, _, _),
      .servedUnrecorded(let file), .baselineServedDiffers(let file, _, _, _),
      .liveServedDiffers(let file, _, _), .questionSetDiffers(let file, _, _),
      .labelledNotRecorded(let file, _, _):
      file
    }
  }
}

extension JudgeRecordingStaleness: CustomStringConvertible {
  public var description: String {
    func ids(_ models: [String]) -> String { models.joined(separator: ", ") }
    func rerecord(_ backend: JudgeBackend) -> String {
      "re-record with --judge-backend \(backend.rawValue) --record"
    }
    switch self {
    case .wrongBackend(let file, let expected, let found):
      return "\(file) holds \(found.backend)/\(found.model) answers, not \(expected.rawValue)'s; "
        + rerecord(expected)
    case .offPin(let file, let found, let pin):
      return "\(file) was recorded from \(found.backend)/\(found.model), not the pinned "
        + "\(found.backend)/\(pin); re-record with --judge-backend \(found.backend) --record"
    case .servedOffPin(let file, let served, let pin):
      return "\(file) was answered by \(ids(served)), not the pinned \(pin); re-record with "
        + "--record once the backend serves \(pin)"
    case .servedUnrecorded(let file):
      return "\(file) names no served model, so a model change behind its alias can't be "
        + "caught offline; re-record, or set servedModels"
    case .baselineServedDiffers(let file, let baselineFile, let baseline, let recording):
      return "\(file) was answered by \(ids(recording)), but \(baselineFile) was set against "
        + "\(ids(baseline)); check the metrics, then set \(baselineFile) servedModels to "
        + "\(ids(recording))"
    case .liveServedDiffers(let file, let recording, let live):
      return "the live backend now serves \(ids(live)), but \(file) was answered by "
        + "\(ids(recording)); re-record with --record"
    case .questionSetDiffers(let file, let found, let expected):
      return "\(file) answers \(found), but its backend is now asked \(expected), so it isn't "
        + "scored; re-record with --record"
    case .labelledNotRecorded(let file, let backend, let cases):
      return "\(cases) labelled but not recorded in \(file), so self-test doesn't score them; "
        + rerecord(backend)
    }
  }
}

/// The metrics of 1 recording over the labelled set.
public struct JudgeCalibrationScore: Sendable, Equatable {
  public let metrics: [JudgeQuestionMetrics]
  /// Labelled cases with no recorded answer to at least 1 question they're labelled on, sorted.
  public let unrecorded: [String]

  public init(metrics: [JudgeQuestionMetrics], unrecorded: [String]) {
    self.metrics = metrics
    self.unrecorded = unrecorded
  }
}

extension JudgeCalibrationSet {
  /// The set's cases as the benchmark scores them.
  public var benchmarkCases: [JudgeBenchmarkCase] {
    cases.map {
      JudgeBenchmarkCase(id: $0.id, declaredTier: $0.declaredTier, expected: $0.expected)
    }
  }
}

/// Precision and recall of one question, treating "the flag fires" as the positive class.
public struct JudgeQuestionMetrics: Sendable, Equatable, Codable {
  public let question: String
  public let truePositives: Int
  public let falsePositives: Int
  public let falseNegatives: Int
  public let trueNegatives: Int
  /// Cases with no label for this question or no answer from the backend.
  public let unscored: Int

  /// `nil` when the judge flagged nothing.
  public var precision: Double? {
    truePositives + falsePositives == 0
      ? nil : Double(truePositives) / Double(truePositives + falsePositives)
  }

  /// `nil` when no case is labeled positive.
  public var recall: Double? {
    truePositives + falseNegatives == 0
      ? nil : Double(truePositives) / Double(truePositives + falseNegatives)
  }

  /// `nil` when no case is labeled negative.
  public var trueNegativeRate: Double? {
    JudgeProportion(count: trueNegatives, n: trueNegatives + falsePositives).value
  }
}

public enum JudgeCalibration {
  /// The judge "flags" a subject when the flagged probability reaches this.
  public static let decisionThreshold = 0.5

  /// The block thresholds `self-test --judge` sweeps, 0.50 to 0.95 in steps of 0.05.
  public static let sweepThresholds: [Double] = (10...19).map { Double($0 * 5) / 100 }

  /// Scores `answers` against every label; a case with no label for a question isn't counted for
  /// it, and a labelled case with no recorded answer is listed as unrecorded.
  public static func score(
    set: JudgeCalibrationSet, questions: JudgeQuestionSet, answers: [String: [JudgeAnswer]]
  ) -> JudgeCalibrationScore {
    // Scoring reads only the answers, never the run's identity.
    let run = JudgeBenchmarkRun(
      identity: JudgeIdentity(backend: "labels", model: "answers"),
      repeats: [answers.mapValues { [JudgeReply(answers: $0, usage: nil)] }])
    var unrecorded: Set<String> = []
    let metrics = questions.questions.map { question in
      let labelled = set.benchmarkCases.filter { $0.expected[question.id] != nil }
      let answered = labelled.filter { item in
        answers[item.id]?.contains { $0.question == question.id } == true
      }
      unrecorded.formUnion(Set(labelled.map(\.id)).subtracting(answered.map(\.id)))
      let (scored, unscored) = JudgeBenchmarkMetrics.score(question, cases: answered, run: run)
      return JudgeBenchmarkMetrics.tally(
        question.id, scored, unscored: unscored, threshold: decisionThreshold)
    }
    return JudgeCalibrationScore(metrics: metrics, unrecorded: unrecorded.sorted())
  }

  /// Offline checks that `recording`, stored in `file` for `backend`, still describes that
  /// backend and its baseline.
  public static func staleness(
    recording: JudgeCalibrationRecording, file: String, backend: JudgeBackend,
    baseline: JudgeBaseline?, baselineFile: String
  ) -> [JudgeRecordingStaleness] {
    guard recording.identity.backend == backend.rawValue else {
      return [.wrongBackend(file: file, expected: backend, found: recording.identity)]
    }
    var found: [JudgeRecordingStaleness] = []
    if let pin = backend.pinnedModel {
      if recording.identity.model != pin {
        found.append(.offPin(file: file, found: recording.identity, pin: pin))
      }
      if let served = recording.servedModels, served != [pin] {
        found.append(.servedOffPin(file: file, served: served, pin: pin))
      }
    }
    switch (recording.servedModels, baseline?.servedModels) {
    case (let served?, let set?) where served != set:
      found.append(
        .baselineServedDiffers(
          file: file, baselineFile: baselineFile, baseline: set, recording: served))
    case (let served, let set):
      if served == nil { found.append(.servedUnrecorded(file: file)) }
      if baseline != nil, set == nil { found.append(.servedUnrecorded(file: baselineFile)) }
    }
    return found
  }

  /// Whether the models a live run was answered by differ from the committed recording's; `nil`
  /// when there's nothing to compare against.
  public static func liveStaleness(
    committed: JudgeCalibrationRecording?, file: String, live: JudgeCalibrationRecording
  ) -> JudgeRecordingStaleness? {
    guard let committed else { return nil }
    guard let recorded = committed.servedModels else { return .servedUnrecorded(file: file) }
    guard let live = live.servedModels else {
      return .servedUnrecorded(file: "the live replies")
    }
    return live == recorded
      ? nil : .liveServedDiffers(file: file, recording: recorded, live: live)
  }

  /// The lowest of ``sweepThresholds`` whose precision on the tune split reaches
  /// `minimumPrecision`; `nil` when none does.
  public static func lowestBlockThreshold(
    _ question: JudgeQuestion, cases: JudgeTuneCases, run: JudgeBenchmarkRun,
    minimumPrecision: Double
  ) -> Double? {
    JudgeBenchmarkMetrics.sweep(question, cases: cases, run: run, thresholds: sweepThresholds)
      .first { point in
        let counts = point.counts
        let hasPositives = counts.truePositives + counts.falseNegatives > 0
        return (counts.precision ?? (hasPositives ? 0 : 1)) >= minimumPrecision
      }?.threshold
  }

  /// Latency, tokens and cost of the recording over the set's report split.
  public static func usage(set: JudgeCalibrationSet, recording: JudgeCalibrationRecording)
    -> JudgeUsageBenchmark
  {
    JudgeBenchmarkMetrics.usage(cases: JudgeReportCases(set.benchmarkCases), run: recording.run)
  }

  public static func metrics(
    set: JudgeCalibrationSet, questions: JudgeQuestionSet, answers: [String: [JudgeAnswer]]
  ) -> [JudgeQuestionMetrics] {
    score(set: set, questions: questions, answers: answers).metrics
  }

  /// One line per question that fell below its baseline. A question with labeled positives but no
  /// flags scores precision 0; an unscored case, one whose recorded answer can't be read, is a
  /// regression because every recorded answer must score.
  public static func regressions(_ metrics: [JudgeQuestionMetrics], baseline: JudgeBaseline)
    -> [String]
  {
    metrics.compactMap { metric -> String? in
      var problems: [String] = []
      if metric.unscored > 0 { problems.append("\(metric.unscored) cases unscored") }
      if let minimum = baseline.minimums[metric.question] {
        let hasPositives = metric.truePositives + metric.falseNegatives > 0
        let precision = metric.precision ?? (hasPositives ? 0 : 1)
        let recall = metric.recall ?? 1
        if precision < minimum.precision {
          problems.append(
            "precision \(format(precision)) < \(format(minimum.precision))")
        }
        if recall < minimum.recall {
          problems.append("recall \(format(recall)) < \(format(minimum.recall))")
        }
      }
      return problems.isEmpty ? nil : "\(metric.question): " + problems.joined(separator: ", ")
    }
  }

  static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}
