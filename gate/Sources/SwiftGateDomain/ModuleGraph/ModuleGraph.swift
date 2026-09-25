/// A source root outside any package, such as an Xcode app target's synchronized folder.
public struct AppModule: Sendable, Equatable {
  public let name: String
  /// Repository-relative directory.
  public let path: String

  public init(name: String, path: String) {
    self.name = name
    self.path = path
  }
}

public struct Module: Sendable, Equatable {
  public let name: String
  /// `nil` for app modules.
  public let packageName: String?
  /// Repository-relative source directory.
  public let path: String
  public let role: ModuleRole
  public let kind: ModuleKind
  public let isHostTestable: Bool
  /// In-graph modules this one depends on, sorted.
  public let dependencies: [String]
  /// Products from packages outside the graph (for example `ComposableArchitecture`), sorted.
  public let externalProducts: [String]

  func with(role: ModuleRole) -> Module {
    Module(
      name: name, packageName: packageName, path: path, role: role, kind: kind,
      isHostTestable: isHostTestable, dependencies: dependencies,
      externalProducts: externalProducts)
  }

  /// This module as the rules see it.
  public var scope: ModuleScope { ModuleScope(module: name, role: role, kind: kind) }
}

public enum ModuleGraphError: Error, Sendable, Equatable {
  case duplicateModule(String)
  /// A package depends on a local package that was not described, so reverse dependencies would
  /// be silently incomplete.
  case missingLocalPackage(package: String, dependencyPath: String)
}

/// Every module in the repository's packages plus its app targets, with dependency edges in both
/// directions. Module names are unique, as Swift requires within one build.
public struct ModuleGraph: ModuleScopeResolving {
  public let packages: [PackageManifest]
  /// Sorted by name.
  public let modules: [Module]
  private let modulesByName: [String: Module]
  private let dependentsByName: [String: [String]]

  public init(packages: [PackageManifest], apps: [AppModule] = [], config: Config? = nil)
    throws(ModuleGraphError)
  {
    let packagesByPath = Dictionary(
      packages.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    let names = packages.flatMap { $0.targets.map(\.name) } + apps.map(\.name)
    let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys
    if let duplicate = duplicates.sorted().first { throw .duplicateModule(duplicate) }
    let nameSet = Set(names)

    // Test targets are placed on a tier from their dependencies' roles, so every non-test role
    // is settled first.
    var drafts: [Module] = []
    for package in packages {
      var localPackages: [PackageManifest] = []
      for dependencyPath in package.localDependencyPaths {
        guard let local = packagesByPath[dependencyPath] else {
          throw .missingLocalPackage(package: package.name, dependencyPath: dependencyPath)
        }
        localPackages.append(local)
      }
      for target in package.targets {
        var dependencies = Set(target.targetDependencies)
        var external = Set<String>()
        for product in target.productDependencies {
          if let vended = localPackages.lazy.compactMap({ $0.products[product] }).first {
            dependencies.formUnion(vended)
          } else {
            external.insert(product)
          }
        }
        let override = config?.module(named: target.name)
        let role = Self.role(of: target, allNames: nameSet, override: override)
        drafts.append(
          Module(
            name: target.name, packageName: package.name, path: target.path, role: role,
            kind: Self.kind(role: role, override: override),
            isHostTestable: config?.isHostTestable(module: target.name) ?? true,
            dependencies: dependencies.sorted(), externalProducts: external.sorted()))
      }
    }
    for app in apps {
      drafts.append(
        Module(
          name: app.name, packageName: nil, path: app.path, role: .app,
          kind: config?.kind(ofModule: app.name) ?? .feature,
          isHostTestable: config?.isHostTestable(module: app.name) ?? true,
          dependencies: [], externalProducts: []))
    }
    let draftsByName = Dictionary(uniqueKeysWithValues: drafts.map { ($0.name, $0) })
    let modules = drafts.map { module in
      guard case .tests = module.role else { return module }
      return module.with(role: .tests(Self.tier(ofTest: module, modules: draftsByName)))
    }

    var dependents: [String: [String]] = [:]
    for module in modules {
      for dependency in module.dependencies {
        dependents[dependency, default: []].append(module.name)
      }
    }
    self.packages = packages
    self.modules = modules.sorted { $0.name < $1.name }
    self.modulesByName = Dictionary(uniqueKeysWithValues: modules.map { ($0.name, $0) })
    self.dependentsByName = dependents.mapValues { $0.sorted() }
  }

  public func module(named name: String) -> Module? { modulesByName[name] }

  public func scope(forFile path: String) -> ModuleScope? { module(containingFile: path)?.scope }

  public func scope(ofModule name: String) -> ModuleScope? { module(named: name)?.scope }

  /// The module whose source directory contains `path` (repository-relative), if any. Package
  /// manifests and files outside every target directory belong to no module.
  public func module(containingFile path: String) -> Module? {
    modules
      .filter { Self.isInside(path, directory: $0.path) }
      .max { $0.path.count < $1.path.count }
  }

  /// The package whose directory contains `path` (repository-relative), if any.
  public func package(containingFile path: String) -> PackageManifest? {
    packages
      .filter { Self.isInside(path, directory: $0.path) }
      .max { $0.path.count < $1.path.count }
  }

  /// The package that defines `module`; `nil` for app modules.
  public func package(of module: Module) -> PackageManifest? {
    module.packageName.flatMap { name in packages.first { $0.name == name } }
  }

  /// Direct in-graph dependencies, sorted.
  public func dependencies(of name: String) -> [String] {
    modulesByName[name]?.dependencies ?? []
  }

  /// Modules that directly depend on `name`, sorted.
  public func dependents(of name: String) -> [String] {
    dependentsByName[name] ?? []
  }

  /// Every module that depends on any of `names`, directly or transitively, excluding `names`
  /// themselves unless reached through a cycle.
  public func transitiveDependents(of names: Set<String>) -> Set<String> {
    var reached = Set<String>()
    var frontier = Array(names)
    while let next = frontier.popLast() {
      for dependent in dependents(of: next) where reached.insert(dependent).inserted {
        frontier.append(dependent)
      }
    }
    return reached
  }

  static func isInside(_ path: String, directory: String) -> Bool {
    directory.isEmpty || path.hasPrefix(directory + "/")
  }

  private static func role(
    of target: PackageTarget, allNames: Set<String>, override: ModuleOverride?
  ) -> ModuleRole {
    switch target.type {
    // Refined to T2 once dependency roles are known.
    case .test: return .tests(.t1)
    case .executable: return .app
    default: break
    }
    let isLiveName = target.name.hasSuffix("Live")
    switch override?.kind {
    case .client?: return isLiveName ? .clientLive : .client
    case .render?: return .ui
    default: break
    }
    if isLiveName { return .clientLive }
    if target.name.hasSuffix("Client") || allNames.contains(target.name + "Live") { return .client }
    if target.name.hasSuffix("UI") { return .ui }
    return .core
  }

  private static func kind(role: ModuleRole, override: ModuleOverride?) -> ModuleKind {
    if let override, override.kind != .feature { return override.kind }
    switch role {
    case .client, .clientLive: return .client
    case .core, .ui, .app, .tests: return .feature
    }
  }

  /// T1 is host `swift test`; a test belongs to T2 instead when it or anything it directly tests
  /// is UI or declared not host-testable, since those targets compile to nothing on the host.
  private static func tier(ofTest test: Module, modules: [String: Module]) -> Tier {
    let needsSimulator =
      !test.isHostTestable
      || test.dependencies.contains { name in
        guard let dependency = modules[name] else { return false }
        return dependency.role == .ui || !dependency.isHostTestable
      }
    return needsSimulator ? .t2 : .t1
  }
}
