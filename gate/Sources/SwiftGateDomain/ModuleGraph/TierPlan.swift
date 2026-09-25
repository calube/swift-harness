/// What one tier must run for a change: changed paths plus the module graph select affected
/// modules (changed modules and everything depending on them) and the test targets that tier owns.
public struct TierPlan: Sendable, Equatable {
  public struct PackageSelection: Sendable, Equatable {
    public let packageName: String
    /// Repository-relative package directory, where `swift test` runs.
    public let packagePath: String
    /// Sorted.
    public let testTargets: [String]
  }

  public let tier: Tier
  /// Sorted; includes test modules.
  public let affectedModules: [String]
  /// Packages with at least one selected test target, sorted by path. Empty for T0 and T3, which
  /// do not run package test targets.
  public let packages: [PackageSelection]
  /// An app-target source changed, which only simulator tiers exercise.
  public let appChanged: Bool
  /// Non-documentation paths outside every module and package manifest, sorted.
  public let unmappedPaths: [String]

  public var isEmpty: Bool { packages.isEmpty && !appChanged }

  public init(changedPaths: [String], graph: ModuleGraph, tier: Tier) {
    var changedModules = Set<String>()
    var appChanged = false
    var unmapped = Set<String>()

    for path in changedPaths where !Self.isDocumentation(path) {
      if let module = graph.module(containingFile: path) {
        changedModules.insert(module.name)
        if module.role == .app { appChanged = true }
      } else if let package = graph.package(containingFile: path),
        Self.isManifest(path, of: package)
      {
        changedModules.formUnion(package.targets.map(\.name))
      } else {
        unmapped.insert(path)
      }
    }

    let affected = changedModules.union(graph.transitiveDependents(of: changedModules))
    let selectedTests = affected.compactMap(graph.module(named:)).filter {
      $0.role == .tests(tier)
    }
    let byPackage = Dictionary(grouping: selectedTests, by: { $0.packageName ?? "" })

    self.tier = tier
    self.affectedModules = affected.sorted()
    self.packages = graph.packages
      .compactMap { package in
        guard let tests = byPackage[package.name], !tests.isEmpty else { return nil }
        return PackageSelection(
          packageName: package.name, packagePath: package.path,
          testTargets: tests.map(\.name).sorted())
      }
      .sorted { $0.packagePath < $1.packagePath }
    self.appChanged = appChanged
    self.unmappedPaths = unmapped.sorted()
  }

  private static func isDocumentation(_ path: String) -> Bool {
    path.hasSuffix(".md") || path.split(separator: "/").contains { $0.hasSuffix(".docc") }
  }

  private static func isManifest(_ path: String, of package: PackageManifest) -> Bool {
    let prefix = package.path.isEmpty ? "" : package.path + "/"
    guard path.hasPrefix(prefix) else { return false }
    let name = path.dropFirst(prefix.count)
    return name == "Package.swift" || name == "Package.resolved"
      || (name.hasPrefix("Package@swift-") && name.hasSuffix(".swift") && !name.contains("/"))
  }
}
