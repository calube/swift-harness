import Foundation

/// A module the design creates, named in a frame answer. `kind` is a ``ModuleKind`` raw value, so
/// an unrecognised kind fails to decode instead of silently becoming some default.
///
/// `ModuleKind` (declared in `Config.swift`, a different task's file) isn't `Codable`, so this
/// type codes `kind` through its raw value itself rather than adding that conformance to a
/// shared config type from here.
public struct DesignScopeNewModule: Sendable, Equatable, Codable {
  public let name: String
  public let kind: ModuleKind

  public init(name: String, kind: ModuleKind) {
    self.name = name
    self.kind = kind
  }

  private enum CodingKeys: String, CodingKey {
    case name, kind
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    let rawKind = try container.decode(String.self, forKey: .kind)
    guard let kind = ModuleKind(rawValue: rawKind) else {
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container,
        debugDescription:
          "'\(rawKind)' is not a known module kind (\(ModuleKind.allCases.map(\.rawValue)))")
    }
    self.kind = kind
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(kind.rawValue, forKey: .kind)
  }
}

/// What a design's frame answers name about its shape (spec §8.1): which existing modules it
/// touches, which modules it creates, and which dependencies it adds. Frame answers name things;
/// they never count them — `design-scope` derives the counts itself, against the real module
/// graph, so a miscount by whatever wrote this file can't understate the tier.
///
/// Not `Decodable`: the only supported way to build one from JSON is
/// ``DesignScopeInputJSON/decode(_:)``, which enforces `schemaVersion` before it reaches here.
public struct DesignScopeAnswers: Sendable, Equatable, Encodable {
  public let touchedModules: [String]
  public let newModules: [DesignScopeNewModule]
  public let newDependencies: [String]

  public init(
    touchedModules: [String], newModules: [DesignScopeNewModule], newDependencies: [String]
  ) {
    self.touchedModules = touchedModules
    self.newModules = newModules
    self.newDependencies = newDependencies
  }
}

/// The frame-answers file `design-scope --frame-answers <path>` reads (its only supported input
/// shape; see ``DesignScopeAnswers``).
public enum DesignScopeInputJSON {
  public static let schemaVersion = 1

  private struct Envelope: Decodable {
    let schemaVersion: Int
    let touchedModules: [String]
    let newModules: [DesignScopeNewModule]
    let newDependencies: [String]
  }

  /// Throws `DecodingError` on malformed JSON, a missing/mistyped key, or an unrecognised
  /// `ModuleKind`, and ``ReportContractViolation`` on an unsupported `schemaVersion`. Never
  /// returns a tier for invalid input — the caller decides what "malformed" means for its exit
  /// code.
  public static func decode(_ data: Data) throws -> DesignScopeAnswers {
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.schemaVersion == schemaVersion else {
      throw ReportContractViolation.unsupportedSchemaVersion(envelope.schemaVersion)
    }
    return DesignScopeAnswers(
      touchedModules: envelope.touchedModules, newModules: envelope.newModules,
      newDependencies: envelope.newDependencies)
  }
}

/// Why a set of frame answers can't be checked against the module graph. Each case names the
/// offending module so the message is actionable without a second lookup.
public enum DesignScopeValidationError: Error, Sendable, Equatable, CustomStringConvertible {
  /// `touchedModules` names a module the graph doesn't have.
  case touchedModuleNotInGraph(String)
  /// `newModules` names a module the graph already has — it isn't new.
  case newModuleAlreadyExists(String)
  /// The same name appears more than once across `touchedModules` and `newModules` (checked in
  /// that order): a module can't be both untouched-and-new and separately touched, or named twice
  /// in the same list.
  case duplicateName(String)

  public var description: String {
    switch self {
    case .touchedModuleNotInGraph(let name):
      "touched module `\(name)` is not in the module graph"
    case .newModuleAlreadyExists(let name):
      "new module `\(name)` already exists in the module graph"
    case .duplicateName(let name):
      "`\(name)` is named more than once across touchedModules and newModules"
    }
  }
}

/// The module-graph facts `design-scope` recommends a tier from (spec §8.1 Decisions), derived
/// from ``DesignScopeAnswers`` against the real ``ModuleGraph`` by
/// ``DesignScope/deriveFacts(answers:graph:)``.
public struct DesignScopeGraphFacts: Sendable, Equatable, Codable {
  /// `newDependencies` isn't empty.
  public let addsDependency: Bool
  /// Some new module's kind is absent from every module already in the graph.
  public let addsModuleKind: Bool
  /// `newModules.count`.
  public let modulesAdded: Int
  /// The distinct union of `touchedModules` and `newModules`' names — every added module is
  /// touched, so this is never smaller than `modulesAdded`.
  public let modulesTouched: Int

  public init(addsDependency: Bool, addsModuleKind: Bool, modulesAdded: Int, modulesTouched: Int) {
    self.addsDependency = addsDependency
    self.addsModuleKind = addsModuleKind
    self.modulesAdded = modulesAdded
    self.modulesTouched = modulesTouched
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

/// Recommends a design's depth tier from its frame answers and the real module graph (spec
/// §8.1). The deep thresholds are fixed constants, not `[docs]`/`[plan]` config (Decisions table:
/// moving them to config is the named reversal, not the default), so softening them takes a code
/// change and a gate re-run rather than a `.swiftgate.toml` edit.
public enum DesignScope {
  /// Two or more brand-new modules recommend deep on their own.
  public static let modulesAddedDeepThreshold = 2
  /// Four or more touched modules recommend deep on their own.
  public static let modulesTouchedDeepThreshold = 4

  /// Turns frame answers into graph facts, checked against `graph`. Deterministic: duplicate
  /// names are checked first (`touchedModules` then `newModules`, first offender reported), then
  /// every touched module must already be in the graph, then no new module may already be in the
  /// graph.
  public static func deriveFacts(
    answers: DesignScopeAnswers, graph: ModuleGraph
  ) throws(DesignScopeValidationError) -> DesignScopeGraphFacts {
    var seen = Set<String>()
    for name in answers.touchedModules {
      guard seen.insert(name).inserted else { throw .duplicateName(name) }
    }
    for module in answers.newModules {
      guard seen.insert(module.name).inserted else { throw .duplicateName(module.name) }
    }
    for name in answers.touchedModules {
      guard graph.module(named: name) != nil else { throw .touchedModuleNotInGraph(name) }
    }
    for module in answers.newModules {
      guard graph.module(named: module.name) == nil else {
        throw .newModuleAlreadyExists(module.name)
      }
    }

    let existingKinds = Set(graph.modules.map(\.kind))
    let addsModuleKind = answers.newModules.contains { !existingKinds.contains($0.kind) }
    let touchedAndNew = Set(answers.touchedModules).union(answers.newModules.map(\.name))
    return DesignScopeGraphFacts(
      addsDependency: !answers.newDependencies.isEmpty, addsModuleKind: addsModuleKind,
      modulesAdded: answers.newModules.count, modulesTouched: touchedAndNew.count)
  }

  /// Quick is never offered once the design adds a dependency or a module kind — checked here by
  /// construction: the only path that returns `.quick` requires both to be `false`. Deep is
  /// checked first, so the dependency-and-module-kind case (which meets both the quick-exclusion
  /// and a deep trigger) resolves to deep, never standard.
  public static func recommend(_ facts: DesignScopeGraphFacts) -> DesignScopeRecommendation {
    var deepReasons: [DesignScopeReason] = []
    if facts.addsDependency, facts.addsModuleKind {
      deepReasons.append(.newDependencyAndModuleKind)
    }
    if facts.modulesAdded >= modulesAddedDeepThreshold { deepReasons.append(.modulesAdded) }
    if facts.modulesTouched >= modulesTouchedDeepThreshold { deepReasons.append(.modulesTouched) }
    if !deepReasons.isEmpty {
      return DesignScopeRecommendation(tier: .deep, reasons: deepReasons)
    }

    guard !facts.addsDependency, !facts.addsModuleKind else {
      var reasons: [DesignScopeReason] = []
      if facts.addsDependency { reasons.append(.newDependency) }
      if facts.addsModuleKind { reasons.append(.newModuleKind) }
      return DesignScopeRecommendation(tier: .standard, reasons: reasons)
    }
    return DesignScopeRecommendation(tier: .quick, reasons: [.noNewDependencyOrModuleKind])
  }
}
