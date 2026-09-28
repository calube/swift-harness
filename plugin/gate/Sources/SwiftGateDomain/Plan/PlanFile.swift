import Foundation

/// `<git common dir>/swift-harness/plans/<slug>/plan.json` (spec §5.6; paths from
/// ``PlanStateLayout``): the plan's identity and approval chain. The
/// ledger alongside it (``Ledger``) holds tasks and waves, so a plan can ride out an amendment's
/// `clarifyChain` without touching task state or the wave schedule.
public struct PlanFile: Sendable, Equatable {
  /// The reviewer's decision on the design page (spec §8.2, `design-render`'s approval bar).
  /// Closed so an unrecognized value fails decoding instead of a gate reading it as approved.
  public enum ApprovalDecision: String, Sendable, Equatable, Codable, CaseIterable {
    case approve
    case requestChanges = "request-changes"
  }

  public struct Approval: Sendable, Equatable, Codable {
    public let decision: ApprovalDecision
    public let designSha: String
    public let at: Date

    public init(decision: ApprovalDecision, designSha: String, at: Date) {
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

  /// Who confirmed a spec page. Closed so an unrecognized value fails decoding instead of a gate
  /// reading the page as confirmed.
  public enum PageApprover: String, Sendable, Equatable, Codable, CaseIterable {
    case user
    /// Every slice quotes the spec verbatim, so the check let the confirm skip the user.
    case specQuotes = "spec-quotes"
  }

  /// A spec page's confirmation, bound to the bytes it confirmed.
  public struct PageApproval: Sendable, Equatable, Codable {
    public let pageSha: String
    public let by: PageApprover
    public let at: Date

    public init(pageSha: String, by: PageApprover, at: Date) {
      self.pageSha = pageSha
      self.by = by
      self.at = at
    }
  }

  /// A plan decomposed from a committed design doc.
  public struct DesignSource: Sendable, Equatable {
    /// The design doc, relative to the repository root.
    public let design: String
    /// `nil` from the claim that seeds the file until the first draft is hashed.
    public let designSha: String?
    /// `nil` only in the window before the design's first approval: a plan is decomposed from an
    /// approved design (spec §9.1), so every ledger'd plan has one soon after it exists.
    public let approval: Approval?
    public let clarifyChain: [ClarifyChainEntry]
    /// `nil` when the claim that seeded the file named no tier; `design-scope` sets it later.
    public let tier: DesignTier?

    public init(
      design: String, designSha: String?, approval: Approval?, clarifyChain: [ClarifyChainEntry],
      tier: DesignTier?
    ) {
      self.design = design
      self.designSha = designSha
      self.approval = approval
      self.clarifyChain = clarifyChain
      self.tier = tier
    }
  }

  /// A plan decomposed from a spec page kept in plan state, with no design doc.
  public struct SpecPageSource: Sendable, Equatable {
    /// The page's name inside the plan's directory, where only the plan's lock holder writes.
    public static let fileName = "spec-page.md"

    /// Relative to the plan's directory.
    public let path: String
    /// `nil` until the page is first hashed.
    public let pageSha: String?
    /// `nil` until the page is confirmed.
    public let approval: PageApproval?

    public init(path: String, pageSha: String?, approval: PageApproval?) {
      self.path = path
      self.pageSha = pageSha
      self.approval = approval
    }
  }

  /// What the plan was decomposed from.
  public enum Source: Sendable, Equatable {
    case design(DesignSource)
    case specPage(SpecPageSource)
  }

  /// `plan.json`'s `source` key; a file without one is a design plan.
  public enum SourceKind: String, Sendable, Equatable, CaseIterable {
    case design
    case specPage
  }

  public let schemaVersion: Int
  public let slug: String
  public let source: Source
  /// The plan's one surface commit, which every task builds on; `nil` until it lands.
  public let surfaceCommit: String?
  public let resume: String

  public init(
    schemaVersion: Int, slug: String, source: Source, surfaceCommit: String?, resume: String
  ) {
    self.schemaVersion = schemaVersion
    self.slug = slug
    self.source = source
    self.surfaceCommit = surfaceCommit
    self.resume = resume
  }

  /// A design plan with no surface commit.
  public init(
    schemaVersion: Int, slug: String, design: String, designSha: String?, approval: Approval?,
    clarifyChain: [ClarifyChainEntry], tier: DesignTier?, resume: String
  ) {
    self.init(
      schemaVersion: schemaVersion, slug: slug,
      source: .design(
        DesignSource(
          design: design, designSha: designSha, approval: approval, clarifyChain: clarifyChain,
          tier: tier)),
      surfaceCommit: nil, resume: resume)
  }

  /// `nil` for a spec-page plan, which has no design to read.
  public var designSource: DesignSource? {
    if case .design(let source) = source { return source }
    return nil
  }

  /// `nil` for a design plan.
  public var specPageSource: SpecPageSource? {
    if case .specPage(let source) = source { return source }
    return nil
  }
}

extension PlanFile: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, slug, source, design, designSha, approval, clarifyChain, tier, specPage
    case surfaceCommit, resume
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
      slug: try container.decode(String.self, forKey: .slug),
      design: try container.decode(String.self, forKey: .design),
      designSha: try container.decodeIfPresent(String.self, forKey: .designSha),
      approval: try container.decodeIfPresent(Approval.self, forKey: .approval),
      clarifyChain: try container.decode([ClarifyChainEntry].self, forKey: .clarifyChain),
      tier: try container.decodeIfPresent(DesignTier.self, forKey: .tier),
      resume: try container.decode(String.self, forKey: .resume))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(slug, forKey: .slug)
    try container.encode(resume, forKey: .resume)
    if case .design(let design) = source {
      try container.encode(design.design, forKey: .design)
      try container.encodeIfPresent(design.designSha, forKey: .designSha)
      try container.encodeIfPresent(design.approval, forKey: .approval)
      try container.encode(design.clarifyChain, forKey: .clarifyChain)
      try container.encodeIfPresent(design.tier, forKey: .tier)
    }
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
  /// The `plan.json` a claim writes at frame: it ties the design doc to the plan, which is what
  /// lets the edit guard allow the holder's writes to it. Nothing is hashed or approved yet.
  public static func seed(slug: String, design: String, tier: DesignTier?) -> PlanFile {
    PlanFile(
      schemaVersion: 1, slug: slug, design: design, designSha: nil, approval: nil,
      clarifyChain: [], tier: tier, resume: "framing")
  }

  /// The `plan.json` a spec-page claim writes: it names the page in the plan's own directory, so
  /// no design doc belongs to the plan. Nothing is hashed or confirmed yet.
  public static func seedSpecPage(slug: String) -> PlanFile {
    PlanFile(
      schemaVersion: 1, slug: slug,
      source: .specPage(
        SpecPageSource(path: SpecPageSource.fileName, pageSha: nil, approval: nil)),
      surfaceCommit: nil, resume: "framing")
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
