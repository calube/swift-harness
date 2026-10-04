/// How discovery knows a value.
public enum Confidence: String, Sendable, Codable, CaseIterable {
  /// A build file or a command CI already runs states it.
  case found
  /// Inferred from the ecosystem's convention, with no file that states it.
  case guessed
  /// Set by the orchestrator through `discover --apply --set`.
  case orchestrator
}

/// A proposed value with the file it came from.
public struct Sourced<Value: Sendable & Equatable>: Sendable, Equatable {
  public let value: Value
  /// Repository-relative path of the file that gave the value.
  public let source: String
  public let confidence: Confidence

  public init(value: Value, source: String, confidence: Confidence) {
    self.value = value
    self.source = source
    self.confidence = confidence
  }
}

/// 1 area an ``EcosystemReader`` proposes.
public struct ProposedArea: Sendable, Equatable {
  public let name: String
  /// Repository-relative; `.` is the repository root.
  public let root: String
  public let language: AreaLanguage
  public let kind: AreaKind
  /// The build file that made this an area.
  public let source: String
  public let commands: [AreaStep: Sourced<String>]
  /// Steps with no command, each with why: none configured, or the orchestrator dropped it.
  public let missing: [AreaStep: String]
  public let testGlobs: [String]
  public let xcode: Sourced<XcodeAreaConfig>?
  /// Whether the generated Xcode project is committed; `nil` when the area has no generator.
  public let generatedProjectTracked: Bool?

  public init(
    name: String, root: String, language: AreaLanguage, kind: AreaKind, source: String,
    commands: [AreaStep: Sourced<String>], missing: [AreaStep: String], testGlobs: [String],
    xcode: Sourced<XcodeAreaConfig>?, generatedProjectTracked: Bool?
  ) {
    self.name = name
    self.root = root
    self.language = language
    self.kind = kind
    self.source = source
    self.commands = commands
    self.missing = missing
    self.testGlobs = testGlobs
    self.xcode = xcode
    self.generatedProjectTracked = generatedProjectTracked
  }
}

extension BrownfieldArea {
  /// The config entry an applied proposal writes: each proposed command under its key, and no
  /// pack, since packs are opt-in. `generate` has no key; the warm-up derives it from the
  /// inclusion.
  public init(proposed: ProposedArea) {
    self.init(
      name: "", root: "", language: .other, kind: .command, test: nil, testFiles: nil, lint: nil,
      build: nil, e2e: nil, testGlobs: [], packs: [], xcode: nil)
  }
}

/// What 1 tree proposes: every area, and the files already modified when discovery ran, which
/// workers never stage.
public struct DiscoverProposal: Sendable, Equatable {
  /// The `HEAD` sha discovery read.
  public let head: String
  public let areas: [ProposedArea]
  /// Repository-relative paths `git status` showed as modified or untracked.
  public let dirty: [String]

  public init(head: String, areas: [ProposedArea], dirty: [String]) {
    self.head = head
    self.areas = areas
    self.dirty = dirty
  }
}
