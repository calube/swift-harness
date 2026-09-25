import Foundation

/// `<git common dir>/swift-harness/plans/<slug>/plan.json` (spec §5.6; paths from
/// ``PlanStateLayout``): the plan's identity and approval chain. The
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
  /// The design doc, relative to the repository root.
  public let design: String
  /// `nil` from the claim that seeds the file until the first draft is hashed.
  public let designSha: String?
  /// `nil` only in the window before the design's first approval: a plan is decomposed from an
  /// approved design (spec §9.1), so every ledger'd plan has one soon after it exists.
  public let approval: Approval?
  public let clarifyChain: [ClarifyChainEntry]
  /// `nil` when the claim that seeded the file named no tier; `design-scope` sets it later.
  public let tier: String?
  public let resume: String

  public init(
    schemaVersion: Int, slug: String, design: String, designSha: String?, approval: Approval?,
    clarifyChain: [ClarifyChainEntry], tier: String?, resume: String
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

extension PlanFile {
  public static let tiers: Set<String> = ["quick", "standard", "deep"]

  /// The `plan.json` a claim writes at frame: it ties the design doc to the plan, which is what
  /// lets the edit guard allow the holder's writes to it. Nothing is hashed or approved yet.
  public static func seed(slug: String, design: String, tier: String?) -> PlanFile {
    PlanFile(
      schemaVersion: 1, slug: slug, design: design, designSha: nil, approval: nil,
      clarifyChain: [], tier: tier, resume: "framing")
  }

  /// A path the edit guard treats as a design doc: repo-relative `…docs/…/designs/<name>.md`,
  /// with no empty, `.` or `..` component, so it names one file inside the checkout.
  public static func isValidDesignPath(_ path: String) -> Bool {
    guard !path.hasPrefix("/"), !path.contains(where: { $0 == "\0" || $0.isNewline }) else {
      return false
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map {
      $0.lowercased()
    }
    guard components.count >= 3,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      let file = components.last, file.hasSuffix(".md"), file != ".md"
    else { return false }
    return components[components.count - 2] == "designs"
      && components.dropLast(2).contains("docs")
  }
}
