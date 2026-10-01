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

  /// A safe id is its own key, so a built-in set's request is unchanged. Any other id goes out as
  /// its safe characters plus a hash of the whole id. If 2 keys still coincide, every question
  /// goes out under its position instead, so no 2 questions ever share a key.
  public init(_ questions: JudgeQuestionSet) {
    var ids: [String] = []
    var seen: Set<String> = []
    for question in questions.questions where seen.insert(question.id).inserted {
      ids.append(question.id)
    }
    var keys = ids.map { Self.isSafe($0) ? $0 : Self.derivedKey($0) }
    if Set(keys).count != keys.count {
      keys = ids.indices.map { "q-\($0 + 1)" }
    }
    keyByID = Dictionary(uniqueKeysWithValues: zip(ids, keys))
    idByKey = Dictionary(uniqueKeysWithValues: zip(keys, ids))
  }

  static let hashLength = 12

  /// The id's safe characters, each other one as `_`, cut so that `-` and the first 12 hex digits
  /// of the id's SHA-256 fit in 64.
  static func derivedKey(_ id: String) -> String {
    let readable = String(
      String.UnicodeScalarView(id.unicodeScalars.map { isSafe($0) ? $0 : "_" })
    ).prefix(maxLength - 1 - hashLength)
    let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    return "\(readable)-\(hash.prefix(hashLength))"
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
