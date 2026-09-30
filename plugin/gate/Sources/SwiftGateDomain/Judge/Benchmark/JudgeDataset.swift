import CryptoKit
import Foundation

/// Who chose a case's labels. Only `person` labels count toward a person-only benchmark or a
/// block calibration; `seed` labels come from a calibration seed's expected option.
public enum JudgeDatasetLabeller: String, Sendable, Equatable, Codable, CaseIterable {
  case person
  case agent
  case seed
}

/// Which labels a benchmark view reads.
public enum JudgeDatasetLabels: Sendable, Equatable {
  case personOnly
  case all
}

/// One case's labels for one question set version.
public struct JudgeDatasetLabel: Sendable, Equatable {
  public let labeller: JudgeDatasetLabeller
  /// Question id → the option a correct judge picks.
  public let expected: [String: String]

  public init(labeller: JudgeDatasetLabeller, expected: [String: String]) {
    self.labeller = labeller
    self.expected = expected
  }
}

public struct JudgeDatasetCase: Sendable, Equatable {
  public let id: String
  public let source: String
  public let context: String
  /// `nil` for a subject with no tier, such as a comment or an agent's reply.
  public let declaredTier: String?
  /// Versioned question set id (`test-quality@1`) → the case's labels for that set, so 2 versions
  /// of a question set share the same cases.
  public let labels: [String: JudgeDatasetLabel]

  public init(
    id: String, source: String, context: String, declaredTier: String?,
    labels: [String: JudgeDatasetLabel]
  ) {
    self.id = id
    self.source = source
    self.context = context
    self.declaredTier = declaredTier
    self.labels = labels
  }

  public var split: JudgeCaseSplit { JudgeCaseSplit.of(id) }
}

/// A dataset's question set: a built-in set named by its versioned id, or one written inline.
public enum JudgeDatasetQuestionSet: Sendable, Equatable {
  case builtIn(JudgeQuestionSet)
  case inline(JudgeQuestionSet)
}

public enum JudgeDatasetError: Error, Sendable, Equatable {
  case malformed(reason: String)
  case unsupportedSchema(Int)
  case unknownQuestionSet(String)
  case invalidQuestion(question: String, reason: String)
  case duplicateCase(String)
  case unknownQuestion(caseID: String, questionSet: String, question: String)
  case unknownOption(caseID: String, question: String, option: String, options: [String])
  case unreadable(path: String, reason: String)
  case missingReply(agent: String, seed: String, path: String)
  case invalidSeeds(reason: String)
  indirect case at(path: String, JudgeDatasetError)
}

extension JudgeDatasetError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .malformed(let reason): "not a judge dataset: \(reason)"
    case .unsupportedSchema(let version):
      "schemaVersion \(version); this swiftgate reads \(JudgeDataset.schemaVersion)"
    case .unknownQuestionSet(let id):
      "labels for question set `\(id)`, which is neither the dataset's nor a built-in set"
    case .invalidQuestion(let question, let reason): "question `\(question)`: \(reason)"
    case .duplicateCase(let id): "case `\(id)` appears more than once"
    case .unknownQuestion(let caseID, let questionSet, let question):
      "case `\(caseID)` labels question `\(question)`, which \(questionSet) doesn't ask"
    case .unknownOption(let caseID, let question, let option, let options):
      "case `\(caseID)` labels question `\(question)` as `\(option)`, which isn't one of its "
        + "options \(options)"
    case .unreadable(let path, let reason): "can't read \(path): \(reason)"
    case .missingReply(let agent, let seed, let path):
      "seed `\(seed)` of \(agent) has no kept reply at \(path)"
    case .invalidSeeds(let reason): "the calibrate design seeds are broken: \(reason)"
    case .at(let path, let error): "\(path): \(error)"
    }
  }
}

public struct JudgeDatasetSplitCounts: Sendable, Equatable, Codable {
  public let tune: Int
  public let report: Int
}

public struct JudgeDatasetLabellerMix: Sendable, Equatable, Codable {
  public let person: Int
  public let agent: Int
  public let seed: Int
}

/// What a benchmark result records about the dataset it ran on.
public struct JudgeDatasetSummary: Sendable, Equatable, Codable {
  public let id: String
  public let questionSet: String
  public let hash: String
  public let cases: Int
  /// Cases with no labels for the dataset's question set; the benchmark can't score them.
  public let unlabelled: Int
  /// Over the labelled cases.
  public let splits: JudgeDatasetSplitCounts
  public let labellers: JudgeDatasetLabellerMix
}

/// A labelled set a judge backend is measured on (spec §10.2).
public struct JudgeDataset: Sendable, Equatable {
  public static let schemaVersion = 1
  public static let builtInQuestionSets: [JudgeQuestionSet] = [.tests, .comments]

  public let id: String
  public let questionSet: JudgeDatasetQuestionSet
  public let cases: [JudgeDatasetCase]

  /// Validates every label against its question set: a known set, a known question, and one of
  /// that question's options. An unknown one fails naming itself, never drops the label.
  public init(id: String, questionSet: JudgeDatasetQuestionSet, cases: [JudgeDatasetCase])
    throws(JudgeDatasetError)
  {
    let own: JudgeQuestionSet
    switch questionSet {
    case .builtIn(let set):
      guard Self.builtIn(set.versionedID) == set else {
        throw .unknownQuestionSet(set.versionedID)
      }
      own = set
    case .inline(let set):
      try Self.validate(inline: set)
      own = set
    }
    var seen: Set<String> = []
    for item in cases {
      guard seen.insert(item.id).inserted else { throw .duplicateCase(item.id) }
      for (version, label) in item.labels {
        guard let set = version == own.versionedID ? own : Self.builtIn(version) else {
          throw .unknownQuestionSet(version)
        }
        for (questionID, option) in label.expected {
          guard let question = set.questions.first(where: { $0.id == questionID }) else {
            throw .unknownQuestion(caseID: item.id, questionSet: version, question: questionID)
          }
          guard question.options.contains(option) else {
            throw .unknownOption(
              caseID: item.id, question: questionID, option: option, options: question.options)
          }
        }
      }
    }
    self.id = id
    self.questionSet = questionSet
    self.cases = cases
  }

  public static func builtIn(_ versionedID: String) -> JudgeQuestionSet? {
    builtInQuestionSets.first { $0.versionedID == versionedID }
  }

  static func validate(inline set: JudgeQuestionSet) throws(JudgeDatasetError) {
    guard builtIn(set.versionedID) == nil else {
      throw .malformed(
        reason: "the inline question set \(set.versionedID) has a built-in set's id; name it by "
          + "id instead")
    }
    var ids: Set<String> = []
    for question in set.questions {
      guard ids.insert(question.id).inserted else {
        throw .invalidQuestion(question: question.id, reason: "appears more than once")
      }
      let options = question.options
      guard options.count >= 2, Set(options).count == options.count else {
        throw .invalidQuestion(question: question.id, reason: "needs 2 or more distinct options")
      }
      if case .option(let flagged) = question.flag, !options.contains(flagged) {
        throw .invalidQuestion(
          question: question.id,
          reason: "flags `\(flagged)`, which isn't one of its options \(options)")
      }
    }
    guard !set.questions.isEmpty else {
      throw .malformed(reason: "the inline question set \(set.versionedID) asks no question")
    }
  }

  public static func decode(_ data: Data) throws(JudgeDatasetError) -> JudgeDataset {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw .malformed(reason: "\(error)")
    }
    try WireKeys.check(object)
    let wire: Wire
    do {
      wire = try JSONDecoder().decode(Wire.self, from: data)
    } catch {
      throw .malformed(reason: "\(error)")
    }
    guard wire.schemaVersion == schemaVersion else {
      throw .unsupportedSchema(wire.schemaVersion)
    }
    let questionSet: JudgeDatasetQuestionSet
    switch (wire.questionSet, wire.inlineQuestionSet) {
    case (let id?, nil):
      guard let set = builtIn(id) else { throw .unknownQuestionSet(id) }
      questionSet = .builtIn(set)
    case (nil, let inline?):
      questionSet = .inline(try inline.questionSet())
    default:
      throw .malformed(reason: "name exactly 1 of `questionSet` and `inlineQuestionSet`")
    }
    return try JudgeDataset(
      id: wire.id, questionSet: questionSet,
      cases: wire.cases.map { item in
        JudgeDatasetCase(
          id: item.id, source: item.source, context: item.context,
          declaredTier: item.declaredTier,
          labels: item.labels.mapValues { label in
            // A label without a labeller is an agent's: only a named person counts as one.
            JudgeDatasetLabel(labeller: label.labeller ?? .agent, expected: label.expected)
          })
      })
  }

  public var questions: JudgeQuestionSet {
    switch questionSet {
    case .builtIn(let set), .inline(let set): set
    }
  }

  /// Sorted keys, no escaped slashes, cases in id order, and every labeller written out, so the
  /// same dataset always has the same bytes however its file was written.
  public var canonicalJSON: Data {
    let wire = Wire(
      schemaVersion: Self.schemaVersion, id: id,
      questionSet: { if case .builtIn(let set) = questionSet { set.versionedID } else { nil } }(),
      inlineQuestionSet: {
        if case .inline(let set) = questionSet { WireQuestionSet(set) } else { nil }
      }(),
      cases: cases.sorted { $0.id < $1.id }.map { item in
        WireCase(
          id: item.id, source: item.source, context: item.context,
          declaredTier: item.declaredTier,
          labels: item.labels.mapValues {
            WireLabel(labeller: $0.labeller, expected: $0.expected)
          })
      })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Every field is a string, an integer or a collection of them, which always encode.
    return (try? encoder.encode(wire)) ?? Data()
  }

  /// SHA-256 of the canonical JSON, lowercase hex: a relabel, a new labeller or an edited source
  /// is a new dataset.
  public var hash: String {
    SHA256.hash(data: canonicalJSON).map { String(format: "%02x", $0) }.joined()
  }

  /// The cases labelled for the dataset's question set, in dataset order; `.personOnly` keeps
  /// only a person's labels.
  public func benchmarkCases(_ labels: JudgeDatasetLabels) -> [JudgeBenchmarkCase] {
    let version = questions.versionedID
    return cases.compactMap { item in
      guard let label = item.labels[version] else { return nil }
      if labels == .personOnly, label.labeller != .person { return nil }
      return JudgeBenchmarkCase(
        id: item.id, declaredTier: item.declaredTier, expected: label.expected)
    }
  }

  /// The dataset's question set cut to the questions `item` has labels for, so a case is never
  /// asked a question only another case is labelled on.
  public func questions(for item: JudgeDatasetCase) -> JudgeQuestionSet {
    let set = questions
    let labelled = item.labels[set.versionedID]?.expected ?? [:]
    return JudgeQuestionSet(
      id: set.id, version: set.version, subjectDescription: set.subjectDescription,
      questions: set.questions.filter { labelled[$0.id] != nil })
  }

  public var summary: JudgeDatasetSummary {
    let version = questions.versionedID
    let labelled = cases.compactMap { item in item.labels[version].map { (item, $0) } }
    func count(_ labeller: JudgeDatasetLabeller) -> Int {
      labelled.filter { $0.1.labeller == labeller }.count
    }
    let tune = labelled.filter { $0.0.split == .tune }.count
    return JudgeDatasetSummary(
      id: id, questionSet: version, hash: hash, cases: cases.count,
      unlabelled: cases.count - labelled.count,
      splits: JudgeDatasetSplitCounts(tune: tune, report: labelled.count - tune),
      labellers: JudgeDatasetLabellerMix(
        person: count(.person), agent: count(.agent), seed: count(.seed)))
  }
}

// MARK: - JSON

private struct Wire: Codable {
  let schemaVersion: Int
  let id: String
  /// A built-in set's versioned id.
  let questionSet: String?
  let inlineQuestionSet: WireQuestionSet?
  let cases: [WireCase]
}

private struct WireQuestionSet: Codable {
  let id: String
  let version: Int
  let subjectDescription: String
  let questions: [WireQuestion]

  init(_ set: JudgeQuestionSet) {
    id = set.id
    version = set.version
    subjectDescription = set.subjectDescription
    questions = set.questions.map(WireQuestion.init)
  }

  func questionSet() throws(JudgeDatasetError) -> JudgeQuestionSet {
    var built: [JudgeQuestion] = []
    for question in questions { built.append(try question.question()) }
    return JudgeQuestionSet(
      id: id, version: version, subjectDescription: subjectDescription, questions: built)
  }
}

private struct WireQuestion: Codable {
  enum Kind: String, Codable {
    case binary, choice, score
  }

  /// Exactly 1 of the 2: the option that marks a problem, or `notDeclaredTier: true`.
  struct Flag: Codable {
    let option: String?
    let notDeclaredTier: Bool?
  }

  let id: String
  let text: String
  let kind: Kind
  let options: [String]?
  let flag: Flag

  init(_ question: JudgeQuestion) {
    id = question.id
    text = question.text
    switch question.kind {
    case .binary: (kind, options) = (.binary, nil)
    case .choice(let values): (kind, options) = (.choice, values)
    case .score(let values): (kind, options) = (.score, values)
    }
    switch question.flag {
    case .option(let option): flag = Flag(option: option, notDeclaredTier: nil)
    case .notDeclaredTier: flag = Flag(option: nil, notDeclaredTier: true)
    }
  }

  func question() throws(JudgeDatasetError) -> JudgeQuestion {
    let built: JudgeQuestion.Kind
    switch (kind, options) {
    case (.binary, nil): built = .binary
    case (.choice, let values?): built = .choice(values)
    case (.score, let values?): built = .score(values)
    case (.binary, _?):
      throw .invalidQuestion(question: id, reason: "a binary question's options are yes and no")
    case (_, nil):
      throw .invalidQuestion(question: id, reason: "a \(kind.rawValue) question needs `options`")
    }
    let builtFlag: JudgeQuestion.Flag
    switch (flag.option, flag.notDeclaredTier) {
    case (let option?, nil): builtFlag = .option(option)
    case (nil, true?): builtFlag = .notDeclaredTier
    default:
      throw .invalidQuestion(
        question: id, reason: "`flag` needs exactly 1 of `option` and `notDeclaredTier: true`")
    }
    // An inline question benchmarks a backend and never gates, so it never blocks, and its
    // finding text is the question itself.
    return JudgeQuestion(
      id: id, text: text, kind: built, flag: builtFlag, mayBlock: false, problem: text)
  }
}

private struct WireCase: Codable {
  let id: String
  let source: String
  let context: String
  let declaredTier: String?
  /// Versioned question set id → labels.
  let labels: [String: WireLabel]
}

private struct WireLabel: Codable {
  let labeller: JudgeDatasetLabeller?
  let expected: [String: String]
}

/// Synthesized decoding ignores a key it doesn't know, so a misspelt `labeller` would read as
/// absent and the label as an agent's. Every object's keys are checked first.
private enum WireKeys {
  static let dataset: Set = ["schemaVersion", "id", "questionSet", "inlineQuestionSet", "cases"]
  static let questionSet: Set = ["id", "version", "subjectDescription", "questions"]
  static let question: Set = ["id", "text", "kind", "options", "flag"]
  static let flag: Set = ["option", "notDeclaredTier"]
  static let item: Set = ["id", "source", "context", "declaredTier", "labels"]
  static let label: Set = ["labeller", "expected"]

  static func check(_ object: Any) throws(JudgeDatasetError) {
    let top = try keys(object, dataset, in: "the dataset")
    if let inline = top["inlineQuestionSet"] {
      let set = try keys(inline, questionSet, in: "inlineQuestionSet")
      for (index, entry) in (set["questions"] as? [Any] ?? []).enumerated() {
        let place = "inlineQuestionSet.questions[\(index)]"
        let fields = try keys(entry, question, in: place)
        if let value = fields["flag"] { _ = try keys(value, flag, in: "\(place).flag") }
      }
    }
    for (index, entry) in (top["cases"] as? [Any] ?? []).enumerated() {
      let fields = try keys(entry, item, in: "cases[\(index)]")
      for (version, value) in fields["labels"] as? [String: Any] ?? [:] {
        _ = try keys(value, label, in: "cases[\(index)].labels.\(version)")
      }
    }
  }

  static func keys(_ value: Any, _ allowed: Set<String>, in place: String)
    throws(JudgeDatasetError) -> [String: Any]
  {
    guard let object = value as? [String: Any] else {
      throw .malformed(reason: "\(place) isn't an object")
    }
    if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
      throw .malformed(reason: "\(place) has unknown key `\(unknown)`")
    }
    return object
  }
}
