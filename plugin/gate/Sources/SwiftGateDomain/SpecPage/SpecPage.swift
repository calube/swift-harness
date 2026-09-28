/// A spec page (fast modes §5.2): the 1-page plan source a sprint or a design-free ship builds
/// from, in the format `skills/sprint/references/spec-page.md` sets out.
public struct SpecPage: Sendable, Equatable {
  public let title: String
  /// The spec file the page names on its `Spec:` line, as written.
  public let specPath: String
  public let goal: String
  public let modules: [Module]
  /// 1 entry per `## Surface` bullet, without its marker.
  public let surface: [String]
  public let slices: [Slice]
  /// 1 entry per `## Out of scope` bullet, without its marker.
  public let outOfScope: [String]

  public init(
    title: String, specPath: String, goal: String, modules: [Module], surface: [String],
    slices: [Slice], outOfScope: [String]
  ) {
    self.title = title
    self.specPath = specPath
    self.goal = goal
    self.modules = modules
    self.surface = surface
    self.slices = slices
    self.outOfScope = outOfScope
  }

  /// 1 row of the `## Modules` table.
  public struct Module: Sendable, Equatable {
    public let name: String
    public let kind: ModuleKind
    public let owns: String
    public let dependsOn: String

    public init(name: String, kind: ModuleKind, owns: String, dependsOn: String) {
      self.name = name
      self.kind = kind
      self.owns = owns
      self.dependsOn = dependsOn
    }
  }

  /// What a slice's `Spec:` says: an acceptance line quoted from the spec file, or `none`.
  public enum SpecReference: Sendable, Equatable {
    case quote(String)
    case none
  }

  /// 1 numbered item of `## Slices`, with its 1 acceptance test.
  public struct Slice: Sendable, Equatable {
    public let number: Int
    /// The 1-based page line the slice starts on.
    public let line: Int
    public let testName: String
    /// T1 unless the slice says `Tier: T2` or `Tier: T3`.
    public let tier: Tier
    public let spec: SpecReference

    public init(number: Int, line: Int, testName: String, tier: Tier, spec: SpecReference) {
      self.number = number
      self.line = line
      self.testName = testName
      self.tier = tier
      self.spec = spec
    }

    /// The slice's coverage id: `slice-<number>-<kebab-case test name>`.
    public var id: String { "" }
  }

  /// Parses `text`, the page's whole contents. Every format problem is reported, not only the
  /// first, and a page with any problem has no parsed value.
  public static func parse(_ text: String) -> SpecPageParse {
    .malformed([])
  }

  /// `name` in kebab case: camel-case humps and runs of anything but letters and digits become
  /// single hyphens, all lowercase.
  public static func kebabCase(_ name: String) -> String {
    ""
  }
}

/// The result of parsing a spec page.
public enum SpecPageParse: Sendable, Equatable {
  case parsed(SpecPage)
  case malformed([SpecPageProblem])
}

/// 1 way a page breaks the spec page format.
public struct SpecPageProblem: Sendable, Equatable {
  /// The 1-based page line, or `nil` for a problem with the page as a whole.
  public let line: Int?
  public let message: String

  public init(line: Int?, message: String) {
    self.line = line
    self.message = message
  }
}
