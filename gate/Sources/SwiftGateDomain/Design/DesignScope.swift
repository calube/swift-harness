import Foundation

/// The module-graph facts a design's frame answers carry about its shape (spec §8.1). The design
/// skill's frame step compares the modules it plans to touch against the current ``ModuleGraph``
/// and answers these questions; `design-scope` itself loads no graph and reads no files, so a
/// repository's actual module layout never has to be reachable from this pure decision.
public struct DesignScopeInput: Sendable, Equatable, Encodable {
  /// The design pulls in a dependency (an external product, or a local package) the graph does
  /// not already carry.
  public let addsDependency: Bool
  /// The design introduces a ``ModuleKind`` no existing module in the graph has.
  public let addsModuleKind: Bool
  /// Brand-new modules the design creates.
  public let modulesAdded: Int
  /// Modules the design creates or edits. Every added module is touched, so this can never be
  /// smaller than `modulesAdded`.
  public let modulesTouched: Int

  /// Not `Decodable`: the only supported way to build one from JSON is
  /// ``DesignScopeInputJSON/decode(_:)``, which enforces `schemaVersion` before it reaches here.
  /// A bare `Decodable` conformance would let a malformed frame-answers file skip that check and
  /// still produce a tier.
  public init(
    addsDependency: Bool, addsModuleKind: Bool, modulesAdded: Int, modulesTouched: Int
  ) throws(ReportContractViolation) {
    try requireNonNegative(modulesAdded, field: "modulesAdded")
    try requireNonNegative(modulesTouched, field: "modulesTouched")
    guard modulesTouched >= modulesAdded else {
      throw .outOfRange(field: "modulesTouched", value: modulesTouched)
    }
    self.addsDependency = addsDependency
    self.addsModuleKind = addsModuleKind
    self.modulesAdded = modulesAdded
    self.modulesTouched = modulesTouched
  }
}

/// The frame-answers file `design-scope --frame-answers <path>` reads (its only supported input
/// shape; see ``DesignScopeInput``).
public enum DesignScopeInputJSON {
  public static let schemaVersion = 1

  private struct Envelope: Decodable {
    let schemaVersion: Int
    let addsDependency: Bool
    let addsModuleKind: Bool
    let modulesAdded: Int
    let modulesTouched: Int
  }

  /// Throws `DecodingError` on malformed JSON or a missing/mistyped key, and
  /// ``ReportContractViolation`` on an unsupported `schemaVersion` or an invalid value
  /// (negative count, or `modulesTouched` under `modulesAdded`). Never returns a tier for
  /// invalid input — the caller decides what "malformed" means for its exit code.
  public static func decode(_ data: Data) throws -> DesignScopeInput {
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.schemaVersion == schemaVersion else {
      throw ReportContractViolation.unsupportedSchemaVersion(envelope.schemaVersion)
    }
    return try DesignScopeInput(
      addsDependency: envelope.addsDependency, addsModuleKind: envelope.addsModuleKind,
      modulesAdded: envelope.modulesAdded, modulesTouched: envelope.modulesTouched)
  }
}

/// Why `design-scope` recommended a tier (spec §8.1 Decisions row). Closed so every caller — the
/// CLI's human and JSON output, and the design skill's `AskUserQuestion` prompt — reads the same
/// fixed message instead of hand-rolling prose from raw booleans and counts.
public enum DesignScopeReason: String, Sendable, Equatable, Codable, CaseIterable {
  case newDependencyAndModuleKind = "new-dependency-and-module-kind"
  case modulesAdded = "modules-added"
  case modulesTouched = "modules-touched"
  case newDependency = "new-dependency"
  case newModuleKind = "new-module-kind"
  case noNewDependencyOrModuleKind = "no-new-dependency-or-module-kind"

  public var message: String {
    switch self {
    case .newDependencyAndModuleKind:
      "adds a new dependency and a new module kind together"
    case .modulesAdded:
      "adds \(DesignScope.modulesAddedDeepThreshold) or more modules"
    case .modulesTouched:
      "touches \(DesignScope.modulesTouchedDeepThreshold) or more modules"
    case .newDependency:
      "adds a new dependency"
    case .newModuleKind:
      "adds a new module kind"
    case .noNewDependencyOrModuleKind:
      "adds no new dependency and no new module kind"
    }
  }
}

/// `design-scope`'s recommendation: a tier plus every reason that applied. Quick and deep always
/// carry at least one reason (`recommend(_:)` never returns either with an empty list); standard
/// carries whichever of `.newDependency`/`.newModuleKind` ruled out quick.
public struct DesignScopeRecommendation: Sendable, Equatable, Codable {
  public let tier: DesignTier
  public let reasons: [DesignScopeReason]

  public init(tier: DesignTier, reasons: [DesignScopeReason]) {
    self.tier = tier
    self.reasons = reasons
  }
}

/// Recommends a design's depth tier from its frame answers (spec §8.1). The deep thresholds are
/// fixed constants, not `[docs]`/`[plan]` config (Decisions table: moving them to config is the
/// named reversal, not the default), so softening them takes a code change and a gate re-run
/// rather than a `.swiftgate.toml` edit.
public enum DesignScope {
  /// Two or more brand-new modules recommend deep on their own.
  public static let modulesAddedDeepThreshold = 2
  /// Four or more touched modules recommend deep on their own.
  public static let modulesTouchedDeepThreshold = 4

  /// Quick is never offered once the design adds a dependency or a module kind — checked here by
  /// construction: the only path that returns `.quick` requires both to be `false`. Deep is
  /// checked first, so the dependency-and-module-kind case (which meets both the quick-exclusion
  /// and a deep trigger) resolves to deep, never standard.
  public static func recommend(_ input: DesignScopeInput) -> DesignScopeRecommendation {
    var deepReasons: [DesignScopeReason] = []
    if input.addsDependency, input.addsModuleKind {
      deepReasons.append(.newDependencyAndModuleKind)
    }
    if input.modulesAdded >= modulesAddedDeepThreshold { deepReasons.append(.modulesAdded) }
    if input.modulesTouched >= modulesTouchedDeepThreshold { deepReasons.append(.modulesTouched) }
    if !deepReasons.isEmpty {
      return DesignScopeRecommendation(tier: .deep, reasons: deepReasons)
    }

    guard !input.addsDependency, !input.addsModuleKind else {
      var reasons: [DesignScopeReason] = []
      if input.addsDependency { reasons.append(.newDependency) }
      if input.addsModuleKind { reasons.append(.newModuleKind) }
      return DesignScopeRecommendation(tier: .standard, reasons: reasons)
    }
    return DesignScopeRecommendation(tier: .quick, reasons: [.noNewDependencyOrModuleKind])
  }
}
