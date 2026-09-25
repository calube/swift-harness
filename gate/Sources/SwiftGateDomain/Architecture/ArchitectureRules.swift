/// Everything the module-graph architecture rules read.
public struct ArchitectureInput: Sendable {
  public let graph: ModuleGraph
  public let config: Config
  /// Keyed by package path.
  public let settings: [String: PackageSettings]

  public init(graph: ModuleGraph, config: Config, settings: [String: PackageSettings]) {
    self.graph = graph
    self.config = config
    self.settings = settings
  }
}

public struct ArchitectureViolation: Sendable, Equatable {
  /// Repository-relative file the fix belongs in: a package manifest or the config.
  public let file: String
  public let message: String
}

/// A rule over module-graph facts (declared dependencies, build settings, config), which source
/// imports alone cannot establish: a module can depend on a Live module without importing it, and
/// SwiftPM links it all the same.
public struct GraphRule: Sendable {
  public let id: String
  public let severity: Severity
  public let summary: String
  let evaluate: @Sendable (ArchitectureInput) -> [ArchitectureViolation]

  public func check(_ input: ArchitectureInput) -> [ArchitectureViolation] { evaluate(input) }
}

/// Spec §6.1.1 client boundaries and the §6.2 toolchain rule, over the module graph.
public enum ArchitectureRules {
  public static let all: [GraphRule] = [
    liveDependency, liveDependsOnFeature, vendorDependency, coreMainActorIsolation,
    configModuleMismatch,
  ]

  public static func evaluate(_ input: ArchitectureInput) throws(ReportContractViolation)
    -> [Finding]
  {
    var findings: [Finding] = []
    for rule in all {
      for violation in rule.check(input) {
        findings.append(
          try Finding(
            ruleID: rule.id, severity: rule.severity, file: violation.file, line: nil,
            message: violation.message, failureScenario: nil))
      }
    }
    return findings
  }

  /// Only the composition root may link a `*Live` module; tests may, to exercise it.
  static let liveDependency = GraphRule(
    id: "arch.live-dependency", severity: .major,
    summary: "a *Live module is a dependency of something other than the app or a test"
  ) { input in
    input.graph.modules.flatMap { module -> [ArchitectureViolation] in
      switch module.role {
      case .app, .tests: return []
      case .core, .ui, .client, .clientLive: break
      }
      return module.dependencies
        .filter { input.graph.module(named: $0)?.role == .clientLive }
        .map { live in
          violation(
            at: module, in: input.graph,
            "\(module.name) depends on \(live); only the app target may link *Live modules — "
              + "depend on the interface and let the app supply the live value")
        }
    }
  }

  /// A Live module talks to the world on behalf of interfaces; depending on a feature, engine or
  /// UI module inverts the layering and drags feature code into every app that links it.
  static let liveDependsOnFeature = GraphRule(
    id: "arch.live-depends-on-feature", severity: .major,
    summary: "a *Live module depends on a feature, engine, library or UI module"
  ) { input in
    input.graph.modules.filter { $0.role == .clientLive }.flatMap { live in
      live.dependencies
        .filter { name in
          guard let role = input.graph.module(named: name)?.role else { return false }
          return role == .core || role == .ui
        }
        .map { feature in
          violation(
            at: live, in: input.graph,
            "\(live.name) depends on \(feature); Live modules may depend only on client interfaces")
        }
    }
  }

  static let vendorDependency = GraphRule(
    id: "arch.vendor-dependency", severity: .major,
    summary: "a declared vendor SDK is a dependency of a module other than a *Live module"
  ) { input in
    let vendors = Set(input.config.clients.vendorModules)
    return input.graph.modules.flatMap { module -> [ArchitectureViolation] in
      if module.role == .clientLive { return [] }
      if case .tests = module.role { return [] }
      return module.externalProducts.filter(vendors.contains).map { vendor in
        violation(
          at: module, in: input.graph,
          "\(module.name) depends on vendor SDK \(vendor); wrap it behind a client interface "
            + "and link it only from that client's *Live module")
      }
    }
  }

  /// `@Reducer` enums break under MainActor default isolation (TCA issue #3768).
  public static let coreMainActorIsolation = GraphRule(
    id: "arch.core-main-actor-isolation", severity: .major,
    summary: "a Core module sets MainActor default isolation"
  ) { input in
    input.graph.modules.filter { $0.role == .core }.compactMap { module in
      guard let package = input.graph.package(of: module),
        input.settings[package.path]?.defaultIsolation[module.name] == "MainActor"
      else { return nil }
      return violation(
        at: module, in: input.graph,
        "\(module.name) sets default isolation MainActor; Core modules must not "
          + "(@Reducer enums break under it) — isolate the UI module instead")
    }
  }

  /// `[[modules]]` entries must name a real module and agree with what the graph says it is.
  static let configModuleMismatch = GraphRule(
    id: "arch.config-module-mismatch", severity: .major,
    summary: ".swiftgate.toml [[modules]] entry names no module or contradicts the graph"
  ) { input in
    input.config.modules.compactMap { entry -> ArchitectureViolation? in
      let file = Config.fileName
      guard let module = input.graph.module(named: entry.name) else {
        return ArchitectureViolation(
          file: file,
          message: "[[modules]] '\(entry.name)' names no module in the configured packages")
      }
      if case .tests = module.role, entry.kind != .feature {
        return ArchitectureViolation(
          file: file,
          message: "[[modules]] '\(entry.name)' is a test target; kind '\(entry.kind.rawValue)' "
            + "applies only to production modules")
      }
      if module.name.hasSuffix("Live"), entry.kind != .client {
        return ArchitectureViolation(
          file: file,
          message: "[[modules]] '\(entry.name)' is a *Live module but is declared kind "
            + "'\(entry.kind.rawValue)'; Live modules are always kind 'client'")
      }
      return nil
    }
  }

  private static func violation(at module: Module, in graph: ModuleGraph, _ message: String)
    -> ArchitectureViolation
  {
    let manifest = graph.package(of: module)?.manifestPath ?? module.path
    return ArchitectureViolation(file: manifest, message: message)
  }
}
