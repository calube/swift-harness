/// Which kind of repository a config describes. An owned repository commits `.swiftgate.toml`;
/// a brownfield clone keeps `config.toml` under its git common dir, written only by
/// `swiftgate discover --apply`.
public enum RepositoryProfile: String, Sendable, Equatable, CaseIterable {
  case owned
  case brownfield
}

/// The language an area's sources are written in.
public enum AreaLanguage: String, Sendable, Codable, CaseIterable {
  case swift, java, kotlin, javascript, typescript, python, go, rust, ruby, other
}

/// How an area builds, which decides the commands discovery proposes for it.
public enum AreaKind: String, Sendable, Codable, CaseIterable {
  case xcode, swiftpm, jvm, node, python, cargo, go, command
}

/// How a new source file joins an Xcode target.
public enum XcodeInclusion: String, Sendable, Codable, CaseIterable {
  /// A `PBXFileSystemSynchronizedRootGroup`: a file joins by sitting under the folder.
  case synchronized
  /// An XcodeGen `project.yml`, regenerated with `xcodegen generate`.
  case xcodegen
  /// A Tuist `Project.swift`, regenerated with `tuist generate`.
  case tuist
  /// A file reference, a build file, a group child and a Sources phase entry per file.
  case explicit
}

/// An opt-in standards pack, keeping the owned profile's rule ids for the areas that turn it on.
public enum AreaPack: String, Sendable, Codable, CaseIterable {
  case tca
  case dependencies
  case moduleKinds = "module-kinds"
}

/// 1 command an area can run, keyed as `config.toml` spells it.
public enum AreaStep: String, Sendable, Codable, CaseIterable {
  case test
  /// `test` narrowed to the changed tests through `{tests}`.
  case testFiles = "test_files"
  case lint
  case build
  /// UI and end-to-end commands, run only by the `final` tier.
  case e2e
  /// `xcodegen generate` or `tuist generate`; it comes from the area's inclusion, never a key.
  case generate
}

/// `[areas.xcode]`: where an Xcode area's project lives and how files join its targets. Exactly 1
/// of ``workspace`` and ``project`` is set.
public struct XcodeAreaConfig: Sendable, Equatable {
  public let workspace: String?
  public let project: String?
  public let inclusion: XcodeInclusion
  /// The generator's spec (`project.yml`, `Project.swift`); required for XcodeGen and Tuist.
  public let manifest: String?
  public let schemes: [String]
  /// The local packages its projects and workspace build, other than 1 at the area's own root:
  /// a change in one can break the app, so it gates this area too.
  public let packages: [String]

  public init(
    workspace: String?, project: String?, inclusion: XcodeInclusion, manifest: String?,
    schemes: [String], packages: [String] = []
  ) {
    self.workspace = workspace
    self.project = project
    self.inclusion = inclusion
    self.manifest = manifest
    self.schemes = schemes
    self.packages = packages
  }
}

/// 1 `[[areas]]` entry: a part of the repository with its own commands. A step with no command is
/// `nil`: discovery found none, or the orchestrator dropped it.
public struct BrownfieldArea: Sendable, Equatable {
  public let name: String
  /// Repository-relative; `.` is the repository root.
  public let root: String
  public let language: AreaLanguage
  public let kind: AreaKind
  public let test: String?
  public let testFiles: String?
  public let lint: String?
  public let build: String?
  public let e2e: String?
  public let testGlobs: [String]
  public let packs: [AreaPack]
  /// Set exactly when ``kind`` is `xcode`.
  public let xcode: XcodeAreaConfig?

  public init(
    name: String, root: String, language: AreaLanguage, kind: AreaKind, test: String?,
    testFiles: String?, lint: String?, build: String?, e2e: String?, testGlobs: [String],
    packs: [AreaPack], xcode: XcodeAreaConfig?
  ) {
    self.name = name
    self.root = root
    self.language = language
    self.kind = kind
    self.test = test
    self.testFiles = testFiles
    self.lint = lint
    self.build = build
    self.e2e = e2e
    self.testGlobs = testGlobs
    self.packs = packs
    self.xcode = xcode
  }
}

extension BrownfieldArea {
  /// Whether `test_files` narrows a run to the changed tests (`{tests}` or `{files}`), so `slice`
  /// can run and prove them even when the whole suite is over its budget.
  public var selectsChangedTests: Bool {
    false
  }
}

/// 1 `[[allow]]` entry: a finding waived on 1 line, matched by its text's hash, so a moved line
/// keeps its waiver and an edited one loses it.
public struct BrownfieldAllow: Sendable, Equatable {
  public let rule: String
  public let path: String
  /// Lowercase hex SHA-256 of the line's text.
  public let lineSHA: String
  public let reason: String

  public init(rule: String, path: String, lineSHA: String, reason: String) {
    self.rule = rule
    self.path = path
    self.lineSHA = lineSHA
    self.reason = reason
  }
}

/// `[brownfield]`.
public struct BrownfieldSettings: Sendable, Equatable {
  /// The `HEAD` sha discovery read.
  public let discoveredAt: String
  /// The `slice` tier's p95 budget.
  public let sliceBudgetSeconds: Int
  /// 0 means no budget; the clock starts when `swiftgate run` reads the spec.
  public let timeBudgetMinutes: Int
  /// Globs of paths review always rates high risk.
  public let sensitive: [String]

  public init(
    discoveredAt: String, sliceBudgetSeconds: Int, timeBudgetMinutes: Int, sensitive: [String]
  ) {
    self.discoveredAt = discoveredAt
    self.sliceBudgetSeconds = sliceBudgetSeconds
    self.timeBudgetMinutes = timeBudgetMinutes
    self.sensitive = sensitive
  }
}

/// `<common>/swift-harness/config.toml`. Read by ``BrownfieldConfigSchema``, written by
/// ``BrownfieldConfigTOML``; the owned profile's ``Config`` is a separate type.
public struct BrownfieldConfig: Sendable, Equatable {
  public static let fileName = "config.toml"
  public static let supportedSchema = 1

  public let brownfield: BrownfieldSettings
  public let areas: [BrownfieldArea]
  public let allow: [BrownfieldAllow]
  public let buildPresets: [String: BuildPreset]
  /// `[judge]`, as the owned profile spells it; `.disabled` without the table.
  public let judge: JudgeConfig

  public init(
    brownfield: BrownfieldSettings, areas: [BrownfieldArea], allow: [BrownfieldAllow],
    buildPresets: [String: BuildPreset], judge: JudgeConfig = .disabled
  ) {
    self.brownfield = brownfield
    self.areas = areas
    self.allow = allow
    self.buildPresets = buildPresets
    self.judge = judge
  }
}
