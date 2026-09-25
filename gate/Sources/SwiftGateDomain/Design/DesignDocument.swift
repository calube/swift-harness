import Foundation

/// A design doc (spec §5.3) parsed into its named sections, on top of the generic
/// ``MarkdownDocument``. Every accessor here is `nil`/empty when the doc doesn't have that
/// section — this type never fails to construct; `design-lint` is what enforces shape.
public struct DesignDocument: Sendable, Equatable {
  /// spec §5.3's named sections, in table order — the one place both this parser's per-field
  /// lookups and `design-lint`'s presence/order check get an anchor. Change §5.3's section shape
  /// here; nowhere else names an anchor literal for it.
  public enum RequiredSection: CaseIterable, Equatable, Sendable {
    case problem, requirements, evidence, options, decision, architecture
    case moduleKinds, testPlanByTier, observability, perfAndScale, risks, openQuestions, changelog

    /// The GitHub-slug anchor `MarkdownDocument` gives this section's heading.
    public var anchor: String {
      switch self {
      case .problem: "problem"
      case .requirements: "requirements"
      case .evidence: "evidence"
      case .options: "options"
      case .decision: "decision"
      case .architecture: "architecture"
      case .moduleKinds: "module-kinds"
      case .testPlanByTier: "test-plan-by-tier"
      case .observability: "observability"
      case .perfAndScale: "perf--scale"
      case .risks: "risks"
      case .openQuestions: "open-questions"
      case .changelog: "changelog"
      }
    }

    /// The heading text spec §5.3 names, for finding messages.
    public var name: String {
      switch self {
      case .problem: "Problem"
      case .requirements: "Requirements"
      case .evidence: "Evidence"
      case .options: "Options"
      case .decision: "Decision"
      case .architecture: "Architecture"
      case .moduleKinds: "Module kinds"
      case .testPlanByTier: "Test plan by tier"
      case .observability: "Observability"
      case .perfAndScale: "Perf & scale"
      case .risks: "Risks"
      case .openQuestions: "Open questions"
      case .changelog: "Changelog"
      }
    }
  }

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

    self.problem = markdown.section(anchor: RequiredSection.problem.anchor)
    let requirementsSection = markdown.section(anchor: RequiredSection.requirements.anchor)
    self.requirements = (requirementsSection?.bullets ?? []).compactMap { bullet in
      bullet.id.map { RequirementBullet(id: $0, statement: bullet.remainder) }
    }

    let evidenceSection = markdown.section(anchor: RequiredSection.evidence.anchor)
    self.evidence = (evidenceSection?.bullets ?? []).compactMap { bullet in
      bullet.tags.first.map { EvidenceBullet(tag: $0, text: bullet.text) }
    }

    self.options = markdown.section(anchor: RequiredSection.options.anchor)?.subsections ?? []
    self.decision = markdown.section(anchor: RequiredSection.decision.anchor)
    self.architecture = markdown.section(anchor: RequiredSection.architecture.anchor)
    self.moduleKinds = markdown.section(anchor: RequiredSection.moduleKinds.anchor)?.tables.first

    let testPlanSection = markdown.section(anchor: RequiredSection.testPlanByTier.anchor)
    self.testPlan = (testPlanSection?.bullets ?? []).compactMap(Self.parseTestPlanBullet)

    self.observability = markdown.section(anchor: RequiredSection.observability.anchor)
    self.perfAndScale = markdown.section(anchor: RequiredSection.perfAndScale.anchor)
    self.risks = markdown.section(anchor: RequiredSection.risks.anchor)
    self.openQuestions = markdown.section(anchor: RequiredSection.openQuestions.anchor)
    self.changelog = markdown.section(anchor: RequiredSection.changelog.anchor)
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

  /// The `docs/**/designs/<name>.md` shape `plan claim --design` also matches: an `.md` file whose
  /// immediate parent directory is literally named `designs`. Matching any path *component* named
  /// `designs` would also catch `docs/redesigns/x.md` and `notes-designs/x.md`, neither of which is
  /// a design doc. Only the last two path components matter, so `repoRelativePath` works whether
  /// it's rooted at the repository (`docs/designs/x.md`) or at `docs/` itself (`designs/x.md`) —
  /// every caller (`docs-lint`, the known-id feed, `check --tier push`) walks the tree the same
  /// way; none of them re-derives this shape on its own.
  public static func isDesignDocPath(_ repoRelativePath: String) -> Bool {
    guard repoRelativePath.hasSuffix(".md") else { return false }
    let components = repoRelativePath.split(separator: "/")
    guard components.count >= 2 else { return false }
    return components[components.count - 2] == "designs"
  }
}
