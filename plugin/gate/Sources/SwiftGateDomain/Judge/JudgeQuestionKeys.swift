import CryptoKit
import Foundation

/// The key a backend request names each question of a set by, and the way back from a key to the
/// question's id. Claude's API refuses a top-level schema property key outside
/// `^[a-zA-Z0-9_.-]{1,64}$` with a 400, and a calibrate design question's id is
/// `<agent>/<seed>/<check>`, often longer than 64 characters.
public struct JudgeQuestionKeys: Sendable, Equatable {
  /// The longest key a backend accepts.
  public static let maxLength = 64

  private let keyByID: [String: String]
  private let idByKey: [String: String]

  public init(_ questions: JudgeQuestionSet) {
    var keyByID: [String: String] = [:]
    for question in questions.questions { keyByID[question.id] = question.id }
    self.keyByID = keyByID
    idByKey = Dictionary(keyByID.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// Whether `key` is 1 to 64 ASCII letters, digits, `_` or `-`: inside what Claude's API accepts,
  /// with no `.`, which a Jev rendering uses to join a question to its sub-question.
  public static func isSafe(_ key: String) -> Bool {
    (1...maxLength).contains(key.unicodeScalars.count)
      && key.unicodeScalars.allSatisfy(isSafe)
  }

  static func isSafe(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9", "_", "-": true
    default: false
    }
  }

  /// The key `id` goes out under; an id the set doesn't ask is its own key.
  public func key(for id: String) -> String { keyByID[id] ?? id }

  /// The id of the question `key` names, or `nil` for a key no question of the set goes out under.
  public func id(for key: String) -> String? { idByKey[key] }
}
