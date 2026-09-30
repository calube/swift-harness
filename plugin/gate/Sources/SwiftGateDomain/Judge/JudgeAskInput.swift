import Foundation

/// What `swiftgate judge ask` reads (design §8): a question set, named or written inline in the
/// judge dataset's format, and the subjects to ask it about.
public struct JudgeAskInput: Sendable, Equatable {
  public static let schemaVersion = 1
  /// A Score question's levels past this many stop being a scale a backend can rank.
  public static let maxScoreLevels = 10
  /// Jev's limit on a Choice question's options.
  public static let maxChoiceOptions = 255

  public let questions: JudgeQuestionSet
  public let subjects: [JudgeSubject]

  public init(questions: JudgeQuestionSet, subjects: [JudgeSubject]) {
    self.questions = questions
    self.subjects = subjects
  }

  static let keys: Set = ["schemaVersion", "questionSet", "inlineQuestionSet", "subjects"]
  static let subjectKeys: Set = ["id", "source", "context", "declaredTier"]

  /// Reads and checks the whole input before anything is asked: an unknown key, a wrong type, a
  /// repeated id or a question past a limit fails naming its field.
  public static func decode(_ data: Data) throws(JudgeAskInputError) -> JudgeAskInput {
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw .invalid(field: "input", reason: "isn't JSON: \(error.localizedDescription)")
    }
    let top = try object(parsed, keys: keys, at: "input")
    guard let version = top["schemaVersion"] else {
      throw .invalid(field: "schemaVersion", reason: "missing")
    }
    guard let version = version as? Int else {
      throw .invalid(field: "schemaVersion", reason: "isn't an integer")
    }
    guard version == schemaVersion else { throw .unsupportedSchema(version) }
    return JudgeAskInput(
      questions: try questionSet(named: top["questionSet"], inline: top["inlineQuestionSet"]),
      subjects: try subjects(top["subjects"]))
  }

  private static func questionSet(named: Any?, inline: Any?) throws(JudgeAskInputError)
    -> JudgeQuestionSet
  {
    switch (named, inline) {
    case (let named?, nil):
      guard let id = named as? String, let set = JudgeDataset.builtIn(id) else {
        throw .invalid(
          field: "questionSet",
          reason: "names no built-in set; use 1 of "
            + JudgeDataset.builtInQuestionSets.map(\.versionedID).joined(separator: ", ")
            + ", or write the set as inlineQuestionSet")
      }
      return set
    case (nil, let inline?):
      let set: JudgeQuestionSet
      do {
        set = try JudgeDataset.inlineQuestionSet(inline, at: "inlineQuestionSet")
      } catch {
        throw invalid(error, inline: inline)
      }
      try checkLimits(set)
      return set
    default:
      throw .invalid(
        field: "questionSet", reason: "name exactly 1 of `questionSet` and `inlineQuestionSet`")
    }
  }

  /// The dataset reader's error, placed at the question it's about when it names one.
  private static func invalid(_ error: JudgeDatasetError, inline: Any) -> JudgeAskInputError {
    guard case .invalidQuestion(let id, let reason) = error else {
      return .invalid(field: "inlineQuestionSet", reason: "\(error)")
    }
    let ids = ((inline as? [String: Any])?["questions"] as? [Any] ?? []).map {
      ($0 as? [String: Any])?["id"] as? String
    }
    let indices = ids.indices.filter { ids[$0] == id }
    // A repeated id is the fault of its second use.
    let index = indices.dropFirst().first ?? indices.first
    return .invalid(
      field: "inlineQuestionSet.questions" + (index.map { "[\($0)]" } ?? ""),
      reason: "question `\(id)`: \(reason)")
  }

  private static func checkLimits(_ set: JudgeQuestionSet) throws(JudgeAskInputError) {
    for (index, question) in set.questions.enumerated() {
      let field = "inlineQuestionSet.questions[\(index)].options"
      switch question.kind {
      case .binary: continue
      case .score(let levels) where levels.count > maxScoreLevels:
        throw .invalid(
          field: field, reason: "\(levels.count) score levels; at most \(maxScoreLevels)")
      case .choice(let options) where options.count > maxChoiceOptions:
        throw .invalid(
          field: field, reason: "\(options.count) choice options; at most \(maxChoiceOptions)")
      case .score, .choice: continue
      }
    }
  }

  private static func subjects(_ value: Any?) throws(JudgeAskInputError) -> [JudgeSubject] {
    guard let value else { throw .invalid(field: "subjects", reason: "missing") }
    guard let list = value as? [Any] else {
      throw .invalid(field: "subjects", reason: "isn't an array")
    }
    guard !list.isEmpty else { throw .invalid(field: "subjects", reason: "names no subject") }
    var seen: Set<String> = []
    var subjects: [JudgeSubject] = []
    for (index, entry) in list.enumerated() {
      let place = "subjects[\(index)]"
      let fields = try object(entry, keys: subjectKeys, at: place)
      func text(_ key: String) throws(JudgeAskInputError) -> String {
        guard let found = fields[key] else {
          throw .invalid(field: "\(place).\(key)", reason: "missing")
        }
        guard let text = found as? String else {
          throw .invalid(field: "\(place).\(key)", reason: "isn't a string")
        }
        return text
      }
      let id = try text("id")
      guard !id.isEmpty else { throw .invalid(field: "\(place).id", reason: "is empty") }
      guard seen.insert(id).inserted else {
        throw .invalid(field: "\(place).id", reason: "`\(id)` appears more than once")
      }
      let tier = fields["declaredTier"] == nil ? nil : try text("declaredTier")
      subjects.append(
        JudgeSubject(
          id: id, file: id, line: 1, source: try text("source"), context: try text("context"),
          declaredTier: tier))
    }
    return subjects
  }

  private static func object(_ value: Any, keys allowed: Set<String>, at place: String)
    throws(JudgeAskInputError) -> [String: Any]
  {
    guard let object = value as? [String: Any] else {
      throw .invalid(field: place, reason: "isn't an object")
    }
    if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
      throw .invalid(field: place, reason: "unknown key `\(unknown)`")
    }
    return object
  }
}

public enum JudgeAskInputError: Error, Sendable, Equatable {
  case unsupportedSchema(Int)
  /// `field` is the JSON path of the value that's wrong, such as `subjects[2].id`.
  case invalid(field: String, reason: String)
}

extension JudgeAskInputError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .unsupportedSchema(let version):
      "schemaVersion: \(version); this swiftgate reads \(JudgeAskInput.schemaVersion)"
    case .invalid(let field, let reason): "\(field): \(reason)"
    }
  }
}

/// What `swiftgate judge ask` prints: each subject's validated distribution per question and what
/// asking cost, with no policy applied.
public struct JudgeAskOutput: Sendable, Equatable {
  public static let schemaVersion = 1

  public struct Subject: Sendable, Equatable {
    public let id: String
    public let answers: [JudgeAnswer]
    /// `nil` when the backend reported none.
    public let usage: JudgeUsage?

    public init(id: String, answers: [JudgeAnswer], usage: JudgeUsage?) {
      self.id = id
      self.answers = answers
      self.usage = usage
    }
  }

  /// The versioned id of the question set asked.
  public let questionSet: String
  public let identity: JudgeIdentity
  /// In input order.
  public let subjects: [Subject]

  public init(questionSet: String, identity: JudgeIdentity, subjects: [Subject]) {
    self.questionSet = questionSet
    self.identity = identity
    self.subjects = subjects
  }

  /// Sorted keys, so the same answers always print the same bytes.
  public var json: Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Strings, numbers and collections of them always encode.
    return (try? encoder.encode(self)) ?? Data()
  }
}

extension JudgeAskOutput: Encodable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, questionSet, identity, subjects
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(questionSet, forKey: .questionSet)
    try container.encode(identity, forKey: .identity)
    try container.encode(subjects, forKey: .subjects)
  }
}

extension JudgeAskOutput.Subject: Encodable {
  private enum CodingKeys: String, CodingKey {
    case id, answers, usage
  }

  /// `usage` prints as null when the backend reported none, so a reader never takes its absence
  /// for a free call.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(answers, forKey: .answers)
    try container.encode(usage, forKey: .usage)
  }
}
