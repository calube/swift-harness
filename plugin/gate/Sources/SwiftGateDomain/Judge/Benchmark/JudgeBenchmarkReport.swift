import Foundation

/// 1 arm of a benchmark (design §10.6): a backend at a pinned model, asking a question set.
public struct JudgeBenchmarkArm: Sendable, Hashable, CustomStringConvertible {
  public let backend: JudgeBackend
  public let model: String
  /// A built-in set's versioned id, written after `#`; `nil` asks the dataset's own set.
  public let questionSet: String?
  /// For a cascade arm, the Claude model that answers the questions Jev escalates; `backend` and
  /// `model` are then Jev's. `nil` for an arm of 1 backend.
  public let claudeModel: String?

  public init(
    backend: JudgeBackend, model: String, questionSet: String? = nil, claudeModel: String? = nil
  ) {
    self.backend = backend
    self.model = model
    self.questionSet = questionSet
    self.claudeModel = claudeModel
  }

  /// The built-in sets an arm may name after `#`.
  public static let questionSets: [JudgeQuestionSet] = [.tests, .testsJev, .comments]

  /// `<backend>:<model>` or `<backend>:<model>#<set id>@<version>`.
  public static func parse(_ text: String) throws(JudgeBenchmarkArmError) -> JudgeBenchmarkArm {
    let parts = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    let head = parts[0]
    let set = parts.count > 1 ? String(parts[1]) : nil
    guard let colon = head.firstIndex(of: ":"), set?.isEmpty != true else {
      throw .malformed(text)
    }
    let name = String(head[..<colon])
    let model = String(head[head.index(after: colon)...])
    guard !name.isEmpty, !model.isEmpty else { throw .malformed(text) }
    // A cascade arm plugs in here as a third backend whose model names both of its judges.
    guard let backend = JudgeBackend(rawValue: name) else {
      throw .unknownBackend(arm: text, backend: name)
    }
    guard pinned(model, on: backend) else { throw .notPinned(arm: text, model: model) }
    if let set, !questionSets.contains(where: { $0.versionedID == set }) {
      throw .unknownQuestionSet(
        arm: text, questionSet: set, known: questionSets.map(\.versionedID))
    }
    return JudgeBenchmarkArm(backend: backend, model: model, questionSet: set)
  }

  /// Claude's aliases (`sonnet`, `opus`) move to new models; only a full `claude-…` id is pinned.
  static func pinned(_ model: String, on backend: JudgeBackend) -> Bool {
    switch backend {
    case .claude: model.hasPrefix("claude-")
    case .jev: backend.isPinned(model)
    }
  }

  public var description: String {
    "\(backend.rawValue):\(model)" + (questionSet.map { "#\($0)" } ?? "")
  }

  /// The set this arm asks on `dataset`. It must read the dataset's labels, and a set rendered
  /// for 1 backend is asked only of that backend.
  public func questions(for dataset: JudgeDataset) throws(JudgeBenchmarkArmError)
    -> JudgeQuestionSet
  {
    let set =
      questionSet.flatMap { id in Self.questionSets.first { $0.versionedID == id } }
      ?? dataset.questions
    guard set.labelsVersion == dataset.labelsVersion else {
      throw .otherLabels(
        arm: description, questionSet: set.versionedID, labels: set.labelsVersion,
        dataset: dataset.labelsVersion)
    }
    if let rendering = set.rendering, rendering.rawValue != backend.rawValue {
      throw .renderedForOtherBackend(
        arm: description, questionSet: set.versionedID, rendering: rendering.rawValue)
    }
    return set
  }

  /// `set` cut to the questions `item` is labelled on under `labelsVersion`, keeping the set's
  /// rendering and base, so a rendered set is still asked as rendered.
  public static func questions(
    _ set: JudgeQuestionSet, for item: JudgeDatasetCase, labelsVersion: String
  ) -> JudgeQuestionSet {
    let labelled = item.labels[labelsVersion]?.expected ?? [:]
    return JudgeQuestionSet(
      id: set.id, version: set.version, subjectDescription: set.subjectDescription,
      questions: set.questions.filter { labelled[$0.id] != nil }, rendering: set.rendering,
      basedOn: set.basedOn)
  }
}

public enum JudgeBenchmarkArmError: Error, Sendable, Equatable, CustomStringConvertible {
  /// Not `<backend>:<model>[#<set>]`.
  case malformed(String)
  case unknownBackend(arm: String, backend: String)
  /// A moving alias, such as `sonnet` or `jev-latest`, where the benchmark needs a pinned id.
  case notPinned(arm: String, model: String)
  case unknownQuestionSet(arm: String, questionSet: String, known: [String])
  /// The set reads other labels than the dataset carries.
  case otherLabels(arm: String, questionSet: String, labels: String, dataset: String)
  /// A set rendered for 1 backend, asked of another.
  case renderedForOtherBackend(arm: String, questionSet: String, rendering: String)

  public var description: String {
    switch self {
    case .malformed(let arm):
      "--backend \(arm): write <backend>:<model>, optionally followed by #<set id>@<version>"
    case .unknownBackend(let arm, let backend):
      "--backend \(arm): unknown backend `\(backend)`; use "
        + JudgeBackend.allCases.map(\.rawValue).joined(separator: " or ")
    case .notPinned(let arm, let model):
      "--backend \(arm): `\(model)` is an alias that can move; name a pinned model id, such as "
        + "claude-sonnet-5-5 or jev-1.13.0"
    case .unknownQuestionSet(let arm, let questionSet, let known):
      "--backend \(arm): unknown question set `\(questionSet)`; known: "
        + known.joined(separator: ", ")
    case .otherLabels(let arm, let questionSet, let labels, let dataset):
      "--backend \(arm): \(questionSet) is scored on \(labels) labels, but the dataset carries "
        + "\(dataset) labels"
    case .renderedForOtherBackend(let arm, let questionSet, let rendering):
      "--backend \(arm): \(questionSet) is rendered for \(rendering) and only \(rendering) asks it"
    }
  }
}

/// Why a benchmark ran: a measurement, or a smoke run of a few cases that proves the path works.
public enum JudgeBenchmarkPurpose: String, Sendable, Equatable, Codable {
  case benchmark
  case smoke
}

/// Which labels a view of the metrics reads.
public enum JudgeBenchmarkLabels: String, Sendable, Equatable, Codable, CaseIterable {
  /// Only a person's labels.
  case person
  /// Every label: a person's, an agent's and a seed's.
  case all

  var heading: String {
    switch self {
    case .person: "Person labels"
    case .all: "All labels"
    }
  }
}

/// The backend, the model the run asked for, and the model that answered.
public struct JudgeBenchmarkIdentity: Sendable, Equatable, Codable {
  public let backend: String
  public let requestedModel: String
  /// The model every reply named; `nil` when no reply named one.
  public let servedModel: String?

  public init(backend: String, requestedModel: String, servedModel: String?) {
    self.backend = backend
    self.requestedModel = requestedModel
    self.servedModel = servedModel
  }
}

/// 1 question of the labels' set, as much of it as scoring reads.
public struct JudgeBenchmarkQuestion: Sendable, Equatable, Codable {
  public enum Kind: String, Sendable, Equatable, Codable {
    case binary, choice, score
  }

  public let id: String
  public let kind: Kind
  /// `nil` for a binary question, whose options are yes and no.
  public let options: [String]?
  /// The option that marks a problem; `nil` for a question that flags any tier but the declared one.
  public let flaggedOption: String?

  public init(_ question: JudgeQuestion) {
    id = question.id
    switch question.kind {
    case .binary: (kind, options) = (.binary, nil)
    case .choice(let values): (kind, options) = (.choice, values)
    case .score(let values): (kind, options) = (.score, values)
    }
    switch question.flag {
    case .option(let option): flaggedOption = option
    case .notDeclaredTier: flaggedOption = nil
    }
  }

  public var question: JudgeQuestion {
    let built: JudgeQuestion.Kind =
      switch kind {
      case .binary: .binary
      case .choice: .choice(options ?? [])
      case .score: .score(options ?? [])
      }
    return JudgeQuestion(
      id: id, text: "", kind: built, flag: flaggedOption.map { .option($0) } ?? .notDeclaredTier,
      mayBlock: false, problem: "")
  }

  /// Why the question can't be scored as written, or `nil`.
  var problem: String? {
    switch (kind, options) {
    case (.binary, _?): return "question `\(id)` is binary and lists options"
    case (.choice, nil), (.score, nil):
      return "question `\(id)` is \(kind.rawValue) with no options"
    default: break
    }
    if let flaggedOption, !question.options.contains(flaggedOption) {
      return "question `\(id)` flags `\(flaggedOption)`, which isn't one of its options"
    }
    return nil
  }
}

/// A labelled case as the benchmark recorded it: who labelled it and what they chose.
public struct JudgeBenchmarkLabelledCase: Sendable, Equatable, Codable {
  public let id: String
  public let labeller: JudgeDatasetLabeller
  public let declaredTier: String?
  public let expected: [String: String]

  public init(
    id: String, labeller: JudgeDatasetLabeller, declaredTier: String?, expected: [String: String]
  ) {
    self.id = id
    self.labeller = labeller
    self.declaredTier = declaredTier
    self.expected = expected
  }

  public var benchmarkCase: JudgeBenchmarkCase {
    JudgeBenchmarkCase(id: id, declaredTier: declaredTier, expected: expected)
  }
}

/// 1 request's raw answers and usage.
public struct JudgeBenchmarkReply: Sendable, Equatable, Codable {
  public let answers: [JudgeAnswer]
  public let usage: JudgeUsage?
  /// On a cascade arm's Claude reply, each question Jev escalated and why; `nil` on every other
  /// reply.
  public var escalations: [String: JudgeCascade.Escalation]? = nil

  public init(_ reply: JudgeReply) {
    answers = reply.answers
    usage = reply.usage
  }

  public var reply: JudgeReply { JudgeReply(answers: answers, usage: usage) }
}

/// 1 arm's raw answers: per repeat, case id → the requests that answered it once.
public struct JudgeBenchmarkArmResult: Sendable, Equatable, Codable {
  /// The arm as written on the command line.
  public let arm: String
  public let identity: JudgeBenchmarkIdentity
  /// The versioned set the arm asked.
  public let questionSet: String
  /// The versioned set whose labels score it.
  public let labelsVersion: String
  public let repeats: [[String: [JudgeBenchmarkReply]]]

  public init(
    arm: String, identity: JudgeBenchmarkIdentity, questionSet: String, labelsVersion: String,
    repeats: [[String: [JudgeBenchmarkReply]]]
  ) {
    self.arm = arm
    self.identity = identity
    self.questionSet = questionSet
    self.labelsVersion = labelsVersion
    self.repeats = repeats
  }

  public var run: JudgeBenchmarkRun {
    JudgeBenchmarkRun(
      identity: JudgeIdentity(backend: identity.backend, model: identity.requestedModel),
      repeats: repeats.map { $0.mapValues { $0.map(\.reply) } })
  }
}

/// 1 arm's numbers in 1 view.
public struct JudgeBenchmarkArmMetrics: Sendable, Equatable, Codable {
  public let arm: String
  public let questions: [JudgeQuestionBenchmark]
  public let usage: JudgeUsageBenchmark
}

/// 2 arms compared on every question, first minus second.
public struct JudgeBenchmarkPairMetrics: Sendable, Equatable, Codable {
  public let first: String
  public let second: String
  public let questions: [JudgeBackendComparison]
}

/// The metrics over 1 kind of label.
public struct JudgeBenchmarkView: Sendable, Equatable, Codable {
  public enum Outcome: Sendable, Equatable, Codable {
    case measured(arms: [JudgeBenchmarkArmMetrics], pairs: [JudgeBenchmarkPairMetrics])
    /// No case carries a label of this kind, so the view reports nothing rather than another
    /// kind's numbers.
    case noLabels
  }

  public let labels: JudgeBenchmarkLabels
  /// Labelled cases of this kind in the report split.
  public let reportCases: Int
  public let outcome: Outcome
}

public struct JudgeBenchmarkMetricsSection: Sendable, Equatable, Codable {
  /// `person`, then `all`.
  public let views: [JudgeBenchmarkView]
}

public enum JudgeBenchmarkReportError: Error, Sendable, Equatable, CustomStringConvertible {
  case malformed(String)
  case unsupportedSchema(Int)
  /// The stored metrics differ from those the raw answers give, at each named place.
  case metricsDiffer([String])

  public var description: String {
    switch self {
    case .malformed(let reason): "not a judge bench result: \(reason)"
    case .unsupportedSchema(let version):
      "schemaVersion \(version); this swiftgate reads \(JudgeBenchmarkReport.schemaVersion)"
    case .metricsDiffer(let places):
      "the stored metrics differ from those the raw answers give, at: "
        + places.joined(separator: "; ")
    }
  }
}

/// `swiftgate judge bench`'s versioned result (design §10.6): the raw answers and the metrics
/// computed from them.
public struct JudgeBenchmarkReport: Sendable, Equatable, Codable {
  public static let schemaVersion = 1

  public let schemaVersion: Int
  public let swiftgateVersion: String
  /// ISO 8601, UTC.
  public let startedAt: String
  public let purpose: JudgeBenchmarkPurpose
  public let dataset: JudgeDatasetSummary
  /// The labels' question set, as scoring reads it.
  public let questions: [JudgeBenchmarkQuestion]
  public let cases: [JudgeBenchmarkLabelledCase]
  public let threshold: Double
  public let repeats: Int
  public let arms: [JudgeBenchmarkArmResult]
  public let metrics: JudgeBenchmarkMetricsSection

  /// Computes `metrics` from the raw answers.
  public init(
    swiftgateVersion: String, startedAt: String, purpose: JudgeBenchmarkPurpose,
    dataset: JudgeDatasetSummary, questions: [JudgeQuestion], cases: [JudgeBenchmarkLabelledCase],
    threshold: Double, repeats: Int, arms: [JudgeBenchmarkArmResult]
  ) {
    schemaVersion = Self.schemaVersion
    self.swiftgateVersion = swiftgateVersion
    self.startedAt = startedAt
    self.purpose = purpose
    self.dataset = dataset
    self.questions = questions.map(JudgeBenchmarkQuestion.init)
    self.cases = cases
    self.threshold = threshold
    self.repeats = repeats
    self.arms = arms
    metrics = Self.metrics(
      questions: self.questions.map(\.question), cases: cases, arms: arms, threshold: threshold)
  }

  /// Every view's metrics from the raw answers, by ``JudgeBenchmarkMetrics``.
  public static func metrics(
    questions: [JudgeQuestion], cases: [JudgeBenchmarkLabelledCase],
    arms: [JudgeBenchmarkArmResult], threshold: Double
  ) -> JudgeBenchmarkMetricsSection {
    let runs = arms.map(\.run)
    return JudgeBenchmarkMetricsSection(
      views: JudgeBenchmarkLabels.allCases.map { labels in
        let chosen = labels == .person ? cases.filter { $0.labeller == .person } : cases
        let report = JudgeReportCases(chosen.map(\.benchmarkCase))
        guard !chosen.isEmpty else {
          return JudgeBenchmarkView(labels: labels, reportCases: 0, outcome: .noLabels)
        }
        let armMetrics = zip(arms, runs).map { arm, run in
          JudgeBenchmarkArmMetrics(
            arm: arm.arm,
            questions: questions.map {
              JudgeBenchmarkMetrics.question($0, cases: report, run: run, threshold: threshold)
            },
            usage: JudgeBenchmarkMetrics.usage(cases: report, run: run))
        }
        var pairs: [JudgeBenchmarkPairMetrics] = []
        for first in arms.indices {
          for second in arms.indices where second > first {
            pairs.append(
              JudgeBenchmarkPairMetrics(
                first: arms[first].arm, second: arms[second].arm,
                questions: questions.map {
                  JudgeBenchmarkMetrics.compare(
                    $0, cases: report, runs[first], runs[second], threshold: threshold)
                }))
          }
        }
        return JudgeBenchmarkView(
          labels: labels, reportCases: report.cases.count,
          outcome: .measured(arms: armMetrics, pairs: pairs))
      })
  }

  /// Rejects a key this version doesn't write, and a schema it doesn't read.
  public static func decode(_ data: Data) throws(JudgeBenchmarkReportError) -> JudgeBenchmarkReport
  {
    let raw: Any
    do {
      raw = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw .malformed("not JSON: \(error)")
    }
    if let object = raw as? [String: Any], let version = object["schemaVersion"] as? Int,
      version != schemaVersion
    {
      throw .unsupportedSchema(version)
    }
    let report: JudgeBenchmarkReport
    do {
      report = try JSONDecoder().decode(JudgeBenchmarkReport.self, from: data)
    } catch {
      throw .malformed("\(error)")
    }
    // Synthesized decoding skips a key it doesn't know, so a misspelt field would read as
    // absent. Every key must be one encoding the decoded value writes back.
    if let path = unknownKey(raw, known: try? JSONSerialization.jsonObject(with: report.json)) {
      throw .malformed("unknown key `\(path)`")
    }
    if let problem = report.questions.lazy.compactMap(\.problem).first {
      throw .malformed(problem)
    }
    return report
  }

  static func unknownKey(_ raw: Any, known: Any?, at path: String = "") -> String? {
    if let object = raw as? [String: Any] {
      let written = known as? [String: Any] ?? [:]
      for key in object.keys.sorted() {
        let here = path.isEmpty ? key : "\(path).\(key)"
        guard let inner = written[key] else {
          // An explicit null reads as absent, which is what encoding an absent value omits.
          if object[key] is NSNull { continue }
          return here
        }
        if let found = unknownKey(object[key] as Any, known: inner, at: here) { return found }
      }
    } else if let array = raw as? [Any], let written = known as? [Any] {
      for (index, element) in array.enumerated() where index < written.count {
        if let found = unknownKey(element, known: written[index], at: "\(path)[\(index)]") {
          return found
        }
      }
    }
    return nil
  }

  /// Sorted keys, so the same result always has the same bytes.
  public var json: Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    // Every number is finite: an undefined metric is `nil` with a reason, never NaN.
    return (try? encoder.encode(self)) ?? Data()
  }

  /// Recomputes the metrics and throws naming each place the stored ones differ.
  public func verify() throws(JudgeBenchmarkReportError) {
    let fresh = Self.metrics(
      questions: questions.map(\.question), cases: cases, arms: arms, threshold: threshold)
    guard fresh != metrics else { return }
    throw .metricsDiffer(Self.differences(stored: metrics, fresh: fresh))
  }

  static func differences(
    stored: JudgeBenchmarkMetricsSection, fresh: JudgeBenchmarkMetricsSection
  ) -> [String] {
    guard stored.views.count == fresh.views.count else { return ["the views"] }
    var places: [String] = []
    for (old, new) in zip(stored.views, fresh.views) where old != new {
      let view = "\(new.labels.heading.lowercased())"
      guard old.labels == new.labels, old.reportCases == new.reportCases,
        case .measured(let oldArms, let oldPairs) = old.outcome,
        case .measured(let newArms, let newPairs) = new.outcome,
        oldArms.count == newArms.count, oldPairs.count == newPairs.count
      else {
        places.append(view)
        continue
      }
      for (a, b) in zip(oldArms, newArms) where a != b {
        guard a.arm == b.arm, a.questions.count == b.questions.count else {
          places.append("\(view), \(b.arm)")
          continue
        }
        for (q, r) in zip(a.questions, b.questions) where q != r {
          places.append("\(view), \(b.arm), \(r.question)")
        }
        if a.usage != b.usage { places.append("\(view), \(b.arm), usage") }
      }
      for (a, b) in zip(oldPairs, newPairs) where a != b {
        places.append("\(view), \(b.first) against \(b.second)")
      }
    }
    return places.isEmpty ? ["the metrics"] : places
  }

  /// The comparison page: per view and question, every arm side by side.
  public var markdown: String {
    JudgeBenchmarkPage(report: self).text
  }
}

/// What a set of arms would cost before any call, from usage a past run recorded.
public struct JudgeBenchmarkEstimate: Sendable, Equatable {
  /// Usage recorded for 1 backend and model.
  public struct Recorded: Sendable, Equatable {
    public let backend: String
    public let model: String
    public let usages: [JudgeUsage]
    /// The file it came from, for the estimate to name.
    public let source: String

    public init(backend: String, model: String, usages: [JudgeUsage], source: String) {
      self.backend = backend
      self.model = model
      self.usages = usages
      self.source = source
    }
  }

  public enum Basis: Sendable, Equatable {
    /// The mean cost of `calls` recorded, uncached calls at the arm's model.
    case recorded(meanPerCall: Double, calls: Int, sources: [String])
    case noRecordedUsage
  }

  public struct Arm: Sendable, Equatable {
    public let arm: String
    public let backend: JudgeBackend
    public let calls: Int
    public let judgments: Int
    public let costUSD: Double?
    public let basis: Basis
  }

  public let arms: [Arm]

  /// `judgments[i]` is the questions case `i` is asked; each arm asks every case once per repeat.
  public static func make(
    arms: [JudgeBenchmarkArm], judgments: [Int], repeats: Int, recorded: [Recorded]
  ) -> JudgeBenchmarkEstimate {
    let calls = judgments.count * repeats
    let asked = judgments.reduce(0, +) * repeats
    return JudgeBenchmarkEstimate(
      arms: arms.map { arm in
        // Only the same backend at the same model prices an arm; a cache hit cost nothing and
        // says nothing about the price.
        let matching = recorded.filter {
          $0.backend == arm.backend.rawValue && $0.model == arm.model
        }
        let costs = matching.flatMap(\.usages).filter { !$0.cached }.compactMap(\.costUSD)
        guard !costs.isEmpty else {
          return Arm(
            arm: arm.description, backend: arm.backend, calls: calls, judgments: asked,
            costUSD: nil, basis: .noRecordedUsage)
        }
        let mean = costs.reduce(0, +) / Double(costs.count)
        return Arm(
          arm: arm.description, backend: arm.backend, calls: calls, judgments: asked,
          costUSD: mean * Double(calls),
          basis: .recorded(
            meanPerCall: mean, calls: costs.count, sources: Set(matching.map(\.source)).sorted()))
      })
  }

  /// Every usage a bench result or a judge recording holds, by backend and model.
  public static func recorded(from data: Data, source: String) throws(JudgeBenchmarkReportError)
    -> [Recorded]
  {
    if let report = try? JudgeBenchmarkReport.decode(data) {
      return report.arms.map { arm in
        Recorded(
          backend: arm.identity.backend, model: arm.identity.requestedModel,
          usages: arm.repeats.flatMap { answered in
            answered.keys.sorted().flatMap { answered[$0] ?? [] }.compactMap(\.usage)
          }, source: source)
      }
    }
    if let recording = try? JSONDecoder().decode(JudgeCalibrationRecording.self, from: data) {
      let usage = recording.usage ?? [:]
      return [
        Recorded(
          backend: recording.identity.backend, model: recording.identity.model,
          usages: usage.keys.sorted().compactMap { usage[$0] }, source: source)
      ]
    }
    throw .malformed("\(source) is neither a judge bench result nor a judge recording")
  }

  /// The Claude spend, or `nil` when a Claude arm has no recorded usage to estimate from.
  public var claudeCostUSD: Double? {
    var total = 0.0
    for arm in arms where arm.backend == .claude {
      guard let cost = arm.costUSD else { return nil }
      total += cost
    }
    return total
  }

  public var text: String {
    var lines = ["judge bench estimate: no calls made"]
    for arm in arms {
      let cost: String
      switch arm.basis {
      case .recorded(let mean, let calls, let sources):
        cost =
          "$\(Self.dollars(arm.costUSD ?? 0)) (mean $\(Self.dollars(mean)) per call over \(calls) "
          + "recorded calls in \(sources.joined(separator: ", ")))"
      case .noRecordedUsage:
        cost =
          "unknown: no recorded usage at this model; pass --usage-from <bench result or judge "
          + "recording>"
      }
      lines.append("\(arm.arm): \(arm.calls) calls, \(arm.judgments) judgments, \(cost)")
    }
    lines.append(
      "Claude spend: " + (claudeCostUSD.map { "$\(Self.dollars($0))" } ?? "unknown"))
    return lines.joined(separator: "\n")
  }

  static func dollars(_ value: Double) -> String { String(format: "%.4f", value) }
}

// MARK: - The page

/// The markdown comparison page (design §10.5 and §10.6).
struct JudgeBenchmarkPage {
  let report: JudgeBenchmarkReport

  var text: String {
    var lines: [String] = ["# Judge benchmark: \(report.dataset.id)", ""]
    if report.purpose == .smoke {
      lines += [
        "**Smoke run**: \(report.repeats) repeat(s) over \(report.cases.count) cases. It shows the "
          + "path works and measures nothing.",
        "",
      ]
    }
    let dataset = report.dataset
    lines += [
      "- Dataset `\(dataset.id)`, question set `\(dataset.questionSet)`, hash `\(dataset.hash)`",
      "- Cases: \(dataset.cases), \(dataset.unlabelled) unlabelled; split: tune "
        + "\(dataset.splits.tune), report \(dataset.splits.report)",
      "- Labellers: person \(dataset.labellers.person), agent \(dataset.labellers.agent), seed "
        + "\(dataset.labellers.seed)",
      "- Run: \(report.cases.count) cases, \(report.repeats) repeats, decision threshold "
        + "\(Self.fixed(report.threshold, 2)); swiftgate \(report.swiftgateVersion), started "
        + "\(report.startedAt)",
      "",
      "| Arm | Backend | Requested model | Served model | Asks | Scored against |",
      "|---|---|---|---|---|---|",
    ]
    for arm in report.arms {
      lines.append(
        "| `\(arm.arm)` | \(arm.identity.backend) | \(arm.identity.requestedModel) | "
          + "\(arm.identity.servedModel ?? "not named") | \(arm.questionSet) | \(arm.labelsVersion) |"
      )
    }
    lines += [
      "",
      "Every number reads the report split only. A rate shows its count out of n with a Wilson 95% "
        + "interval; Brier, calibration error, κ and each difference show a paired bootstrap 95% "
        + "interval (\(JudgeBootstrap.resamples) resamples, seed \(JudgeBootstrap.seed)).",
    ]
    for view in report.metrics.views {
      lines += ["", "## \(view.labels.heading)", ""]
      switch view.outcome {
      case .noLabels:
        lines.append(
          view.labels == .person
            ? "No person labels: every label in this dataset is an agent's or a seed's, so this "
              + "view has no numbers. The all-labels view below is not a person-labelled result."
            : "No labelled cases.")
      case .measured(let arms, let pairs):
        lines += measured(view, arms: arms, pairs: pairs)
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  func measured(
    _ view: JudgeBenchmarkView, arms: [JudgeBenchmarkArmMetrics],
    pairs: [JudgeBenchmarkPairMetrics]
  ) -> [String] {
    var lines = ["Report-split cases: \(view.reportCases)."]
    let header = "| Metric | " + arms.map { "`\($0.arm)`" }.joined(separator: " | ") + " |"
    let rule = "|---|" + String(repeating: "---|", count: arms.count)
    let chosen =
      view.labels == .person ? report.cases.filter { $0.labeller == .person } : report.cases
    let cases = JudgeReportCases(chosen.map(\.benchmarkCase))
    for (index, question) in report.questions.enumerated() {
      let numbers = arms.map { $0.questions[index] }
      func row(_ name: String, _ cell: (JudgeQuestionBenchmark) -> String) -> String {
        "| \(name) | " + numbers.map(cell).joined(separator: " | ") + " |"
      }
      lines += [
        "", "### \(question.id)", "", header, rule,
        row("Precision") { Self.rate($0.precision) },
        row("True-positive rate (recall)") { Self.rate($0.truePositiveRate) },
        row("True-negative rate") { Self.rate($0.trueNegativeRate) },
        row("Accuracy") { Self.rate($0.accuracy) },
        row("Brier score") { Self.estimate($0.brier) },
        row("Calibration error") { Self.estimate($0.calibrationError) },
        row("Flips over repeats") { Self.flips($0.stability) },
        row("Mean SD of the flagged p") { Self.spread($0.stability) },
      ]
      lines += differences(pairs, question: index)
      lines += reliability(numbers, arms: arms)
      lines += disagreements(question.question, cases: cases)
    }
    lines += ["", "### Usage", "", header, rule]
    func row(_ name: String, _ cell: (JudgeUsageBenchmark) -> String) -> String {
      "| \(name) | " + arms.map { cell($0.usage) }.joined(separator: " | ") + " |"
    }
    lines += [
      row("Request latency p50 / p95") { Self.latency($0.requestLatency) },
      row("Case latency p50 / p95") { Self.latency($0.caseLatency) },
      row("Backend latency p50 / p95") { Self.latency($0.backendLatency) },
      row("Input tokens per case") { Self.estimate($0.inputTokensPerCase, digits: 0) },
      row("Output tokens per case") { Self.estimate($0.outputTokensPerCase, digits: 0) },
      row("Cost per case (USD)") { Self.estimate($0.costPerCase, digits: 5) },
      row("Cost per 1,000 judgments (USD)") {
        Self.estimate($0.costPerThousandJudgments, digits: 4)
      },
    ]
    return lines
  }

  func differences(_ pairs: [JudgeBenchmarkPairMetrics], question index: Int) -> [String] {
    guard !pairs.isEmpty else { return [] }
    var lines = [
      "",
      "| Difference (first − second) | κ | Brier | Calibration error | Accuracy | "
        + "True-positive rate | True-negative rate |",
      "|---|---|---|---|---|---|---|",
    ]
    var crossings: [String] = []
    for pair in pairs {
      let compared = pair.questions[index]
      let named: [(String, JudgeEstimate)] = [
        ("Brier", compared.brierDifference),
        ("calibration error", compared.calibrationErrorDifference),
        ("accuracy", compared.accuracyDifference),
        ("true-positive rate", compared.truePositiveRateDifference),
        ("true-negative rate", compared.trueNegativeRateDifference),
      ]
      lines.append(
        "| `\(pair.first)` − `\(pair.second)` | \(Self.estimate(compared.kappa)) | "
          + named.map { Self.estimate($0.1) }.joined(separator: " | ") + " |")
      for (name, difference) in named {
        guard let interval = difference.interval, interval.lower <= 0, interval.upper >= 0
        else { continue }
        crossings.append(
          "The 95% interval of the \(name) difference between `\(pair.first)` and "
            + "`\(pair.second)` runs from \(Self.fixed(interval.lower, 3)) to "
            + "\(Self.fixed(interval.upper, 3)) and crosses 0: these \(difference.n) cases can't "
            + "tell the 2 arms apart on it.")
      }
    }
    if !crossings.isEmpty { lines += [""] + crossings }
    return lines
  }

  func reliability(_ numbers: [JudgeQuestionBenchmark], arms: [JudgeBenchmarkArmMetrics])
    -> [String]
  {
    var lines = [
      "", "Reliability of the flagged probability:", "",
      "| Bin | " + arms.map { "`\($0.arm)`" }.joined(separator: " | ") + " |",
      "|---|" + String(repeating: "---|", count: arms.count),
    ]
    for bin in 0..<JudgeBenchmarkMetrics.bins {
      let cells = numbers.map { number -> String in
        guard bin < number.reliability.count else { return "none (n=0)" }
        let found = number.reliability[bin]
        guard let predicted = found.meanPredicted else { return "none (n=0)" }
        return "predicted \(Self.fixed(predicted, 2)), observed \(Self.rate(found.observed))"
      }
      lines.append(
        "| \(Self.fixed(Double(bin) / 10, 1))–\(Self.fixed(Double(bin + 1) / 10, 1)) | "
          + cells.joined(separator: " | ") + " |")
    }
    return lines
  }

  /// Every scored case where the arms' majority decisions differ, with each arm's mean flagged
  /// probability.
  func disagreements(_ question: JudgeQuestion, cases: JudgeReportCases) -> [String] {
    guard report.arms.count > 1 else { return [] }
    let scored = report.arms.map { arm in
      Dictionary(
        JudgeBenchmarkMetrics.score(question, cases: cases.cases, run: arm.run).scored.map {
          ($0.id, $0)
        }, uniquingKeysWith: { kept, _ in kept })
    }
    var rows: [String] = []
    for item in cases.cases {
      let found = scored.map { $0[item.id] }
      let decisions = Set(found.compactMap { $0?.decision(at: report.threshold) })
      guard decisions.count > 1 else { continue }
      rows.append(
        "| \(item.id) | "
          + found.map { scoredCase -> String in
            guard let scoredCase else { return "not scored" }
            let verdict = scoredCase.decision(at: report.threshold) ? "flags" : "passes"
            return "\(Self.fixed(scoredCase.meanFlagged, 2)) (\(verdict))"
          }.joined(separator: " | ") + " |")
    }
    guard !rows.isEmpty else {
      return ["", "Disagreements: none; every arm made the same decision on every scored case."]
    }
    return [
      "", "Disagreements (mean flagged probability and majority decision):", "",
      "| Case | " + report.arms.map { "`\($0.arm)`" }.joined(separator: " | ") + " |",
      "|---|" + String(repeating: "---|", count: report.arms.count),
    ] + rows
  }

  static func fixed(_ value: Double, _ digits: Int) -> String {
    String(format: "%.\(digits)f", value)
  }

  static func interval(_ interval: JudgeInterval?, digits: Int) -> String {
    guard let interval else { return "" }
    return ", 95% [\(fixed(interval.lower, digits)), \(fixed(interval.upper, digits))]"
  }

  static func undefined(_ reason: JudgeUndefined?, n: Int) -> String {
    let why =
      switch reason {
      case .chanceAgreementIsCertain?: "chance agreement is certain"
      case .noCases?, nil: "no cases"
      }
    return "undefined: \(why) (n=\(n))"
  }

  static func rate(_ proportion: JudgeProportion) -> String {
    guard let value = proportion.value else {
      return undefined(proportion.undefined, n: proportion.n)
    }
    return "\(fixed(value, 2)) (n=\(proportion.n): \(proportion.count)/\(proportion.n))"
      + interval(proportion.wilson, digits: 2)
  }

  static func estimate(_ estimate: JudgeEstimate, digits: Int = 3) -> String {
    guard let value = estimate.value else { return undefined(estimate.undefined, n: estimate.n) }
    return "\(fixed(value, digits)) (n=\(estimate.n))" + interval(estimate.interval, digits: digits)
  }

  static func latency(_ percentiles: JudgePercentiles) -> String {
    guard let p50 = percentiles.p50, let p95 = percentiles.p95 else {
      return "none (n=\(percentiles.n))"
    }
    return "\(p50) / \(p95) ms (n=\(percentiles.n))"
  }

  static func flips(_ stability: JudgeStability) -> String {
    switch stability {
    case .measured(_, let flips, _): rate(flips)
    case .tooFewRepeats(let repeats): "too few repeats (\(repeats))"
    }
  }

  static func spread(_ stability: JudgeStability) -> String {
    switch stability {
    case .measured(_, _, let deviation): estimate(deviation)
    case .tooFewRepeats(let repeats): "too few repeats (\(repeats))"
    }
  }
}
