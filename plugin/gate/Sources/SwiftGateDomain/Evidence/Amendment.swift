import Foundation

/// One line of `<slug>.evidence/amendments.jsonl` (spec §5.5): a change to an approved design,
/// keyed for the committed record by `title` + `at` (the ledger's own local id is a worktree
/// convenience that never leaves it, per §5.1).
public struct Amendment: Sendable, Equatable, Codable {
  /// `amend` changes requirements/tests/claims and carries a review and an approval decision.
  /// `clarify` only removes ambiguity — it carries neither (``Amendment/isValid(_:)``).
  public enum Class: String, Sendable, Equatable, Codable, CaseIterable {
    case amend
    case clarify
  }

  public struct Review: Sendable, Equatable, Codable {
    public let verdict: String
    public let reviewers: [String]

    public init(verdict: String, reviewers: [String]) {
      self.verdict = verdict
      self.reviewers = reviewers
    }
  }

  public struct Approval: Sendable, Equatable, Codable {
    public let decision: String
    public let designSha: String
    public let at: Date

    public init(decision: String, designSha: String, at: Date) {
      self.decision = decision
      self.designSha = designSha
      self.at = at
    }
  }

  public let title: String
  public let at: Date
  public let `class`: Class
  public let fromSha: String
  public let toSha: String
  /// Requirement/test-plan ids the design's meaning changed under (spec §5.1 forms).
  public let changedIds: [String]
  /// Claim ids this amendment introduced.
  public let newClaims: [String]
  public let trigger: String
  public let review: Review?
  public let approval: Approval?

  public init(
    title: String, at: Date, class amendmentClass: Class, fromSha: String, toSha: String,
    changedIds: [String], newClaims: [String], trigger: String, review: Review?,
    approval: Approval?
  ) {
    self.title = title
    self.at = at
    self.class = amendmentClass
    self.fromSha = fromSha
    self.toSha = toSha
    self.changedIds = changedIds
    self.newClaims = newClaims
    self.trigger = trigger
    self.review = review
    self.approval = approval
  }

  /// Spec §5.5: a `clarify` record carries no `review` and no `approval`. `amend` is unconstrained
  /// here — it may not have either yet while still in flight.
  public static func isValid(_ amendment: Amendment) -> Bool {
    guard amendment.class == .clarify else { return true }
    return amendment.review == nil && amendment.approval == nil
  }
}

/// JSON Lines encoding for amendments: one compact, key-sorted, ISO-8601-dated object per record.
public enum AmendmentJSON {
  public static func encodeLine(_ amendment: Amendment) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(amendment)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  /// Decodes every line. Lines that fail to parse (for example one torn by a crash mid-write) are
  /// counted rather than failing the whole file.
  public static func decode(_ data: Data) -> (amendments: [Amendment], invalidLines: Int) {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var amendments: [Amendment] = []
    var invalid = 0
    for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
      if let amendment = try? decoder.decode(Amendment.self, from: Data(line)) {
        amendments.append(amendment)
      } else {
        invalid += 1
      }
    }
    return (amendments, invalid)
  }
}
