import Foundation

/// `.harness/plans/<slug>/plan.json` (spec §5.6): the plan's identity and approval chain. The
/// ledger alongside it (``Ledger``) holds tasks and waves, so a plan can ride out an amendment's
/// `clarifyChain` without touching task state or the wave schedule.
public struct PlanFile: Sendable, Equatable, Codable {
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

  /// One design amendment the plan rode out (spec §5.5): the design moved from `fromSha` to
  /// `toSha` without invalidating the plan's identity.
  public struct ClarifyChainEntry: Sendable, Equatable, Codable {
    public let fromSha: String
    public let toSha: String
    public let at: Date

    public init(fromSha: String, toSha: String, at: Date) {
      self.fromSha = fromSha
      self.toSha = toSha
      self.at = at
    }
  }

  public let schemaVersion: Int
  public let slug: String
  public let design: String
  public let designSha: String
  /// `nil` only in the window before the design's first approval: a plan is decomposed from an
  /// approved design (spec §9.1), so every ledger'd plan has one soon after it exists.
  public let approval: Approval?
  public let clarifyChain: [ClarifyChainEntry]
  public let tier: String
  public let resume: String

  public init(
    schemaVersion: Int, slug: String, design: String, designSha: String, approval: Approval?,
    clarifyChain: [ClarifyChainEntry], tier: String, resume: String
  ) {
    self.schemaVersion = schemaVersion
    self.slug = slug
    self.design = design
    self.designSha = designSha
    self.approval = approval
    self.clarifyChain = clarifyChain
    self.tier = tier
    self.resume = resume
  }
}

/// Encodes `plan.json` as one pretty-printed, key-sorted, ISO-8601-dated object, so two encodes of
/// the same value produce identical bytes (the file is reviewed as a diff).
public enum PlanFileJSON {
  public static func encode(_ plan: PlanFile) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(plan)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  public static func decode(_ data: Data) throws -> PlanFile {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PlanFile.self, from: data)
  }
}
