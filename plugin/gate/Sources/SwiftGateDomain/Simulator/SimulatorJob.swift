/// One `xcodebuild test` a simulator tier runs: a package's test scheme filtered to its simulator
/// targets (T2), or the app scheme's test action (T3).
public struct SimulatorJob: Sendable, Equatable {
  public enum Container: Sendable, Equatable {
    /// Repository-relative package directory.
    case package(path: String)
    /// Repository-relative `.xcodeproj` or `.xcworkspace`.
    case app(path: String)
  }

  /// Unique within a run; names the job's result bundle, log and DerivedData directory.
  public let name: String
  public let container: Container
  public let scheme: String
  public let onlyTesting: [String]
  /// Targets that must each execute at least one test. Empty for the app scheme, whose UI test
  /// targets the module graph does not know.
  public let targets: [TestTargetReference]

  public init(
    name: String, container: Container, scheme: String, onlyTesting: [String],
    targets: [TestTargetReference]
  ) {
    self.name = name
    self.container = container
    self.scheme = scheme
    self.onlyTesting = onlyTesting
    self.targets = targets
  }

  /// One job per package the plan selects, in plan order.
  public static func packageJobs(plan: TierPlan, graph: ModuleGraph) -> [SimulatorJob] {
    plan.packages.compactMap { selection in
      guard let manifest = graph.packages.first(where: { $0.name == selection.packageName })
      else { return nil }
      return SimulatorJob(
        name: "pkg-" + stem(selection.packagePath),
        container: .package(path: selection.packagePath),
        scheme: PackageTestScheme.name(for: manifest), onlyTesting: selection.testTargets,
        targets: selection.testTargets.map { name in
          TestTargetReference(
            name: name, path: graph.module(named: name)?.path ?? selection.packagePath)
        })
    }
  }

  public static func appJob(containerPath: String, scheme: String) -> SimulatorJob {
    SimulatorJob(
      name: "app-" + stem(scheme), container: .app(path: containerPath), scheme: scheme,
      onlyTesting: [], targets: [])
  }

  static func stem(_ text: String) -> String {
    let mapped = text.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
    return mapped.isEmpty ? "root" : String(mapped)
  }
}

public enum AppContainerError: Error, Sendable, Equatable {
  case none
  case ambiguous([String])

  public var message: String {
    switch self {
    case .none: "no .xcworkspace or .xcodeproj at the repository root to run the app scheme from"
    case .ambiguous(let candidates):
      "several app containers at the repository root (\(candidates.joined(separator: ", "))); "
        + "keep one, or add a workspace that holds them"
    }
  }
}

/// Picks the app container from the repository root's entries. A workspace wins because it is what
/// makes a project's sibling packages resolvable.
public enum AppContainer {
  public static func choose(among entries: [String]) -> Result<String, AppContainerError> {
    let workspaces = entries.filter { $0.hasSuffix(".xcworkspace") }.sorted()
    let projects = entries.filter { $0.hasSuffix(".xcodeproj") }.sorted()
    for candidates in [workspaces, projects] where !candidates.isEmpty {
      guard candidates.count == 1, let only = candidates.first else {
        return .failure(.ambiguous(candidates))
      }
      return .success(only)
    }
    return .failure(.none)
  }
}
