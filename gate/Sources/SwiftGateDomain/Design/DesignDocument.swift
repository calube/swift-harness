import Foundation

/// A design doc (spec §5.3) parsed into its named sections, on top of the generic
/// ``MarkdownDocument``. Every accessor here is `nil`/empty when the doc doesn't have that
/// section — this type never fails to construct; `design-lint` is what enforces shape.
public struct DesignDocument: Sendable, Equatable {
  /// Frontmatter `status` (spec §5.4). `unknown` covers a value the doc claims that isn't one of
  /// the four the spec defines, so a malformed frontmatter doesn't silently read as `.proposed`.
  public enum Status: Sendable, Equatable {
    case proposed
    case approved
    case built
    case supersededBy(String)
    case unknown(String)
  }

  /// A `Requirements` bullet: `req-…: statement` (spec §5.3, id form spec §5.1).
  public struct RequirementBullet: Sendable, Equatable {
    public let id: String
    public let statement: String
  }

  /// An `Evidence` bullet: tagged `[ev-…]` or `[UNVERIFIED]` (spec §5.3).
  public struct EvidenceBullet: Sendable, Equatable {
    public let tag: String
    public let text: String
  }

  /// A `Test plan by tier` bullet: `test-…: behaviour — tier T1/T2/T3` (spec §5.3).
  public struct TestPlanBullet: Sendable, Equatable {
    public let id: String
    public let behaviour: String
    public let tier: String
  }

  public let markdown: MarkdownDocument

  public let status: Status?
  public let area: String?
  public let tier: String?

  public let problem: MarkdownDocument.Section?
  public let requirements: [RequirementBullet]
  public let evidence: [EvidenceBullet]
  /// The `### Option N` subsections of `## Options`, in document order.
  public let options: [MarkdownDocument.Section]
  public let decision: MarkdownDocument.Section?
  public let architecture: MarkdownDocument.Section?
  public let moduleKinds: MarkdownDocument.Table?
  public let testPlan: [TestPlanBullet]
  public let observability: MarkdownDocument.Section?
  public let perfAndScale: MarkdownDocument.Section?
  public let risks: MarkdownDocument.Section?
  public let openQuestions: MarkdownDocument.Section?
  public let changelog: MarkdownDocument.Section?

  public init(markdown: MarkdownDocument) {
    self.markdown = markdown
    self.status = Self.parseStatus(markdown.frontmatter["status"])
    self.area = markdown.frontmatter["area"]
    self.tier = markdown.frontmatter["tier"]

    self.problem = markdown.section(anchor: "problem")
    let requirementsSection = markdown.section(anchor: "requirements")
    self.requirements = (requirementsSection?.bullets ?? []).compactMap { bullet in
      bullet.id.map { RequirementBullet(id: $0, statement: bullet.remainder) }
    }

    let evidenceSection = markdown.section(anchor: "evidence")
    self.evidence = (evidenceSection?.bullets ?? []).compactMap { bullet in
      bullet.tags.first.map { EvidenceBullet(tag: $0, text: bullet.text) }
    }

    self.options = markdown.section(anchor: "options")?.subsections ?? []
    self.decision = markdown.section(anchor: "decision")
    self.architecture = markdown.section(anchor: "architecture")
    self.moduleKinds = markdown.section(anchor: "module-kinds")?.tables.first

    let testPlanSection = markdown.section(anchor: "test-plan-by-tier")
    self.testPlan = (testPlanSection?.bullets ?? []).compactMap(Self.parseTestPlanBullet)

    self.observability = markdown.section(anchor: "observability")
    self.perfAndScale = markdown.section(anchor: "perf--scale")
    self.risks = markdown.section(anchor: "risks")
    self.openQuestions = markdown.section(anchor: "open-questions")
    self.changelog = markdown.section(anchor: "changelog")
  }

  private static func parseStatus(_ raw: String?) -> Status? {
    guard let raw else { return nil }
    switch raw {
    case "proposed": return .proposed
    case "approved": return .approved
    case "built": return .built
    default:
      if raw.hasPrefix("superseded-by:") {
        let slug = raw.dropFirst("superseded-by:".count).trimmingCharacters(in: .whitespaces)
        return .supersededBy(slug)
      }
      return .unknown(raw)
    }
  }

  /// Spec §5.3's separator is `" — tier "` specifically, not the bare word "tier" — a behaviour
  /// description is free prose and may contain "tier" itself (e.g. "no tier annotation").
  private static let tierSeparator = " — tier "

  private static func parseTestPlanBullet(_ bullet: MarkdownDocument.Bullet) -> TestPlanBullet? {
    guard let id = bullet.id else { return nil }
    guard let tierRange = bullet.remainder.range(of: tierSeparator) else {
      return TestPlanBullet(id: id, behaviour: bullet.remainder, tier: "")
    }
    let tier = String(bullet.remainder[tierRange.upperBound...])
      .trimmingCharacters(in: .whitespaces)
    let behaviour = String(bullet.remainder[bullet.remainder.startIndex..<tierRange.lowerBound])
    return TestPlanBullet(id: id, behaviour: behaviour, tier: tier)
  }
}
