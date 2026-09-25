/// A repository's `.swiftgate.toml`, validated. Every instance satisfies the cross-field rules in
/// ``Config/init(xcode:appScheme:packages:simulator:pyramid:flows:mutation:budgets:clients:modules:judge:exclude:)``;
/// there is no way to hold a `Config` that silently disables a rule.
public struct Config: Sendable, Equatable {
  /// Where the config lives, relative to the repository root.
  public static let fileName = ".swiftgate.toml"

  /// The only `schema` value this build understands.
  public static let supportedSchema = 1

  public let xcode: String
  public let appScheme: String
  /// Package directory globs, relative to the repository root.
  public let packages: [String]
  public let simulator: SimulatorConfig
  public let pyramid: PyramidConfig
  /// The closed list of T3 flows.
  public let flows: [Flow]
  public let mutation: MutationConfig
  public let budgets: Budgets
  public let clients: ClientsConfig
  /// Only modules that deviate from the defaults (`feature`, host-testable) need entries.
  public let modules: [ModuleOverride]
  public let judge: JudgeConfig
  /// Repository-relative directories that whole-repository checks skip, such as fixtures that
  /// violate the rules on purpose.
  public let exclude: [String]

  public init(
    xcode: String,
    appScheme: String,
    packages: [String],
    simulator: SimulatorConfig,
    pyramid: PyramidConfig = PyramidConfig(),
    flows: [Flow] = [],
    mutation: MutationConfig = MutationConfig(),
    budgets: Budgets = Budgets(),
    clients: ClientsConfig = ClientsConfig(),
    modules: [ModuleOverride] = [],
    judge: JudgeConfig = .disabled,
    exclude: [String] = []
  ) throws(ConfigValidationError) {
    let issues = Self.invariantIssues(
      xcode: xcode, appScheme: appScheme, packages: packages, simulator: simulator,
      pyramid: pyramid, flows: flows, mutation: mutation, budgets: budgets, clients: clients,
      modules: modules, judge: judge, exclude: exclude)
    if !issues.isEmpty { throw ConfigValidationError(issues: issues) }
    self.xcode = xcode
    self.appScheme = appScheme
    self.packages = packages
    self.simulator = simulator
    self.pyramid = pyramid
    self.flows = flows
    self.mutation = mutation
    self.budgets = budgets
    self.clients = clients
    self.modules = modules
    self.judge = judge
    self.exclude = exclude
  }

  public func module(named name: String) -> ModuleOverride? {
    modules.first { $0.name == name }
  }

  public func kind(ofModule name: String) -> ModuleKind {
    module(named: name)?.kind ?? .feature
  }

  public func isHostTestable(module name: String) -> Bool {
    module(named: name)?.hostTestable ?? true
  }

  static func invariantIssues(
    xcode: String, appScheme: String, packages: [String], simulator: SimulatorConfig,
    pyramid: PyramidConfig, flows: [Flow], mutation: MutationConfig, budgets: Budgets,
    clients: ClientsConfig, modules: [ModuleOverride], judge: JudgeConfig, exclude: [String]
  ) -> [ConfigIssue] {
    var issues: [ConfigIssue] = []
    func requireText(_ value: String, _ path: String) {
      if value.isBlank { issues.append(.emptyValue(path: path)) }
    }

    requireText(xcode, "xcode")
    requireText(appScheme, "app_scheme")
    if packages.isEmpty { issues.append(.emptyValue(path: "packages")) }
    for (index, glob) in packages.enumerated() { requireText(glob, "packages[\(index)]") }

    requireText(simulator.device, "simulator.device")
    requireText(simulator.os, "simulator.os")
    if simulator.maxConcurrent < 1 {
      issues.append(
        .outOfRange(
          path: "simulator.max_concurrent", value: "\(simulator.maxConcurrent)", allowed: ">= 1"))
    }

    if !(0...1).contains(pyramid.diffCoverageMin) {
      issues.append(
        .outOfRange(
          path: "pyramid.diff_coverage_min", value: "\(pyramid.diffCoverageMin)", allowed: "0...1"))
    }
    if pyramid.maxFlows < 0 {
      issues.append(
        .outOfRange(path: "pyramid.max_flows", value: "\(pyramid.maxFlows)", allowed: ">= 0"))
    }

    var flowNames = Set<String>()
    for (index, flow) in flows.enumerated() {
      requireText(flow.name, "flows[\(index)].name")
      requireText(flow.reason, "flows[\(index)].reason")
      if !flow.name.isBlank, !flowNames.insert(flow.name).inserted {
        issues.append(.duplicateName(path: "flows[\(index)].name", name: flow.name))
      }
    }
    if pyramid.maxFlows >= 0, flows.count > pyramid.maxFlows {
      issues.append(.tooManyFlows(count: flows.count, max: pyramid.maxFlows))
    }

    if mutation.maxMutants < 1 {
      issues.append(
        .outOfRange(path: "mutation.max_mutants", value: "\(mutation.maxMutants)", allowed: ">= 1"))
    }

    let budgetEntries: [(String, Duration?)] = [
      ("t0", budgets.t0), ("t1", budgets.t1), ("t2", budgets.t2), ("t3", budgets.t3),
      ("stop_hook", budgets.stopHook),
    ]
    for case (let key, let budget?) in budgetEntries where budget <= .zero {
      issues.append(.outOfRange(path: "budgets.\(key)", value: "\(budget)", allowed: "> 0 seconds"))
    }

    for (index, module) in clients.vendorModules.enumerated() {
      requireText(module, "clients.vendor_modules[\(index)]")
    }

    var moduleNames = Set<String>()
    for (index, module) in modules.enumerated() {
      let path = "modules[\(index)]"
      requireText(module.name, "\(path).name")
      if !module.name.isBlank, !moduleNames.insert(module.name).inserted {
        issues.append(.duplicateName(path: "\(path).name", name: module.name))
      }
      let hasReason = !(module.reason ?? "").isBlank
      if module.kind != .feature, !hasReason {
        issues.append(
          .missingReason(
            path: "\(path).reason", module: module.name, rule: .nonDefaultKind(module.kind)))
      }
      if !module.hostTestable, !hasReason {
        issues.append(
          .missingReason(path: "\(path).reason", module: module.name, rule: .notHostTestable))
      }
    }

    if case .enabled(_, let thresholds) = judge {
      for (key, value) in [
        ("judge.advisory_threshold", thresholds.advisory),
        ("judge.block_threshold", thresholds.block),
      ] where !(0...1).contains(value) {
        issues.append(.outOfRange(path: key, value: "\(value)", allowed: "0...1"))
      }
      if thresholds.advisory > thresholds.block {
        issues.append(
          .judgeThresholdsInverted(advisory: thresholds.advisory, block: thresholds.block))
      }
    }
    for (index, path) in exclude.enumerated() {
      let components = path.split(separator: "/")
      if path.isBlank || path.hasPrefix("/") || components.contains("..") {
        issues.append(
          .outOfRange(
            path: "exclude[\(index)]", value: path, allowed: "a repository-relative directory"))
      }
    }
    return issues
  }
}

public struct SimulatorConfig: Sendable, Equatable {
  public static let defaultMaxConcurrent = 2

  public let device: String
  public let os: String
  /// Machine-wide cap on concurrent simulator runs across every worktree.
  public let maxConcurrent: Int

  public init(device: String, os: String, maxConcurrent: Int = Self.defaultMaxConcurrent) {
    self.device = device
    self.os = os
    self.maxConcurrent = maxConcurrent
  }
}

public struct PyramidConfig: Sendable, Equatable {
  /// Fraction (0...1) of changed Core/Client/Live lines that T1 tests alone must cover.
  public let diffCoverageMin: Double
  /// Cap on the number of T3 flows.
  public let maxFlows: Int

  public init(diffCoverageMin: Double = 0.90, maxFlows: Int = 10) {
    self.diffCoverageMin = diffCoverageMin
    self.maxFlows = maxFlows
  }
}

public struct Flow: Sendable, Equatable {
  public let name: String
  public let reason: String

  public init(name: String, reason: String) {
    self.name = name
    self.reason = reason
  }
}

public struct MutationConfig: Sendable, Equatable {
  /// Mutants beyond this count are sampled.
  public let maxMutants: Int

  public init(maxMutants: Int = 30) {
    self.maxMutants = maxMutants
  }
}

/// Wall-clock budgets that `stats` flags breaches against. `nil` means unbudgeted.
public struct Budgets: Sendable, Equatable {
  public let t0: Duration?
  public let t1: Duration?
  public let t2: Duration?
  public let t3: Duration?
  public let stopHook: Duration?

  public init(
    t0: Duration? = .seconds(5), t1: Duration? = .seconds(60), t2: Duration? = nil,
    t3: Duration? = nil, stopHook: Duration? = .seconds(90)
  ) {
    self.t0 = t0
    self.t1 = t1
    self.t2 = t2
    self.t3 = t3
    self.stopHook = stopHook
  }
}

public struct ClientsConfig: Sendable, Equatable {
  /// Vendor SDK module names that may be imported only inside `*Live` modules.
  public let vendorModules: [String]

  public init(vendorModules: [String] = []) {
    self.vendorModules = vendorModules
  }
}

public enum ModuleKind: String, Sendable, Equatable, CaseIterable {
  case feature
  case engine
  case render
  case library
  case client
}

public struct ModuleOverride: Sendable, Equatable {
  public let name: String
  public let kind: ModuleKind
  public let hostTestable: Bool
  public let reason: String?

  public init(name: String, kind: ModuleKind = .feature, hostTestable: Bool = true, reason: String?)
  {
    self.name = name
    self.kind = kind
    self.hostTestable = hostTestable
    self.reason = reason
  }
}

/// The judge sends test source to a model, so it is off unless a repository opts in.
public enum JudgeConfig: Sendable, Equatable {
  case disabled
  case enabled(backend: JudgeBackend, thresholds: JudgeThresholds)
}

public enum JudgeBackend: String, Sendable, Equatable, CaseIterable {
  case claude
}

/// Probability thresholds: `p >= block` may block at the `ready` tier; `advisory <= p < block` is
/// advisory; below `advisory` is ignored.
public struct JudgeThresholds: Sendable, Equatable {
  public let advisory: Double
  public let block: Double

  public init(advisory: Double, block: Double) {
    self.advisory = advisory
    self.block = block
  }
}

extension String {
  var isBlank: Bool { allSatisfy(\.isWhitespace) }
}
