/// The table `swiftgate discover` prints (design §5.2): 1 row per value, with its source and
/// confidence, then 1 `missing:` line per step with no command.
public enum ProposalTable {
  /// `appliedTo` is the config path an `--apply` wrote; `nil` for a proposal only printed.
  public static func render(_ proposal: DiscoverProposal, milliseconds: Int, appliedTo: String?)
    -> String
  {
    ""
  }
}

/// `discover/last.json`: the last applied proposal, with every value's source and confidence,
/// the edits that shaped it, and the dirty files. The warm-up and the run report read it.
public struct DiscoverRecord: Sendable, Equatable, Codable {
  public struct Value: Sendable, Equatable, Codable {
    public let step: AreaStep
    public let command: String
    public let source: String
    public let confidence: Confidence
  }

  public struct Missing: Sendable, Equatable, Codable {
    public let step: AreaStep
    public let reason: String
  }

  public struct Xcode: Sendable, Equatable, Codable {
    public let workspace: String?
    public let project: String?
    public let inclusion: XcodeInclusion
    public let manifest: String?
    public let schemes: [String]
    public let source: String
    public let confidence: Confidence
  }

  public struct Area: Sendable, Equatable, Codable {
    public let name: String
    public let root: String
    public let language: AreaLanguage
    public let kind: AreaKind
    public let source: String
    public let values: [Value]
    public let missing: [Missing]
    public let testGlobs: [String]
    public let xcode: Xcode?
    public let generatedProjectTracked: Bool?
  }

  public static let schemaVersion = 1

  public let schemaVersion: Int
  public let head: String
  public let areas: [Area]
  public let dirty: [String]
  public let edits: [DiscoverEdit]

  public init(proposal: DiscoverProposal, edits: [DiscoverEdit]) {
    self.schemaVersion = Self.schemaVersion
    self.head = proposal.head
    self.areas = []
    self.dirty = proposal.dirty
    self.edits = edits
  }

  /// The proposal this record holds.
  public var proposal: DiscoverProposal {
    DiscoverProposal(head: head, areas: [], dirty: dirty)
  }
}

/// `discover/dirty.json`: the paths modified or untracked when discovery ran, which workers never
/// stage.
public struct DiscoverDirtyFiles: Sendable, Equatable, Codable {
  public let head: String
  /// Repository-relative, as `git status --porcelain` prints them; an untracked directory ends
  /// in `/`.
  public let paths: [String]

  public init(head: String, paths: [String]) {
    self.head = head
    self.paths = paths
  }
}
