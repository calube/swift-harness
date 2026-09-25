import SwiftGateDomain

/// Optional `fixture.json` in a rule's fixture directory (`Fixtures/rules/<rule-id>/`): the
/// injected context the rule's `bad/` and `good/` files are checked under. Without it, files are
/// checked with no module scopes, flows, codenames or vendor modules.
public struct RuleFixtureManifest: Decodable, Sendable, Equatable {
  public struct Module: Decodable, Sendable, Equatable {
    public let name: String
    /// `core`, `ui`, `client`, `clientLive`, `app`, `t1`, `t2` or `t3`.
    public let role: String
    public let kind: String?
    public let directories: [String]
  }

  /// Repository-relative directory the fixture files are presented under, so path-scoped rules
  /// see a realistic path.
  public let directory: String?
  public let modules: [Module]?
  public let flows: [String]?
  public let privateCodenames: [String]?
  public let vendorModules: [String]?

  public init(
    directory: String? = nil, modules: [Module]? = nil, flows: [String]? = nil,
    privateCodenames: [String]? = nil, vendorModules: [String]? = nil
  ) {
    self.directory = directory
    self.modules = modules
    self.flows = flows
    self.privateCodenames = privateCodenames
    self.vendorModules = vendorModules
  }

  public static let defaultDirectory = "Fixture"

  public func path(forFileNamed name: String) -> String {
    "\(directory ?? Self.defaultDirectory)/\(name)"
  }

  public func context() throws(RuleFixtureManifestError) -> RuleContext {
    var entries: [StaticModuleScopes.Entry] = []
    for module in modules ?? [] {
      guard let role = Self.role(named: module.role) else {
        throw .unknownRole(module.role)
      }
      var kind = ModuleKind.feature
      if let name = module.kind {
        guard let parsed = ModuleKind(rawValue: name) else { throw .unknownKind(name) }
        kind = parsed
      }
      entries.append(
        .init(
          scope: ModuleScope(module: module.name, role: role, kind: kind),
          directories: module.directories))
    }
    return RuleContext(
      scopes: StaticModuleScopes(entries), flows: flows, privateCodenames: privateCodenames ?? [],
      vendorModules: vendorModules ?? [])
  }

  static func role(named name: String) -> ModuleRole? {
    switch name {
    case "core": .core
    case "ui": .ui
    case "client": .client
    case "clientLive": .clientLive
    case "app": .app
    case "t1": .tests(.t1)
    case "t2": .tests(.t2)
    case "t3": .tests(.t3)
    default: nil
    }
  }
}

public enum RuleFixtureManifestError: Error, Sendable, Equatable {
  case unknownRole(String)
  case unknownKind(String)
}
