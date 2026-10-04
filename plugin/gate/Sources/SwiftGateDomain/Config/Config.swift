import Foundation

/// A repository's `.swiftgate.toml`, validated. Every instance satisfies the cross-field rules in
/// ``Config/init(xcode:appScheme:packages:simulator:pyramid:flows:mutation:budgets:clients:modules:judge:docs:plan:buildPresets:profile:exclude:telemetry:)``;
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
  public let docs: DocsConfig
  public let plan: PlanConfig
  /// Named `[build.presets.<name>]` tables, keyed by preset name. Empty when a repository
  /// declares no `build` section.
  public let buildPresets: [String: BuildPreset]
  /// `[harness] profile`: the ``buildPresets`` entry a repository is optimised for, used when a
  /// build names no preset. `nil` when the repository doesn't say.
  public let profile: String?
  /// Repository-relative directories that whole-repository checks skip, such as fixtures that
  /// violate the rules on purpose.
  public let exclude: [String]
  public let telemetry: TelemetryConfig

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
    docs: DocsConfig = DocsConfig(),
    plan: PlanConfig = PlanConfig(),
    buildPresets: [String: BuildPreset] = [:],
    profile: String? = nil,
    exclude: [String] = [],
    telemetry: TelemetryConfig = TelemetryConfig()
  ) throws(ConfigValidationError) {
    let issues = Self.invariantIssues(
      xcode: xcode, appScheme: appScheme, packages: packages, simulator: simulator,
      pyramid: pyramid, flows: flows, mutation: mutation, budgets: budgets, clients: clients,
      modules: modules, judge: judge, docs: docs, plan: plan, buildPresets: buildPresets,
      profile: profile, exclude: exclude)
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
    self.docs = docs
    self.plan = plan
    self.buildPresets = buildPresets
    self.profile = profile
    self.exclude = exclude
    self.telemetry = telemetry
  }

  /// The preset a repository with no `[harness] profile` builds with.
  public static let defaultProfile = "default"

  /// The preset name a build uses when it is given none.
  public var profileName: String { profile ?? Self.defaultProfile }

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
    clients: ClientsConfig, modules: [ModuleOverride], judge: JudgeConfig, docs: DocsConfig,
    plan: PlanConfig, buildPresets: [String: BuildPreset], profile: String?, exclude: [String]
  ) -> [ConfigIssue] {
    var issues: [ConfigIssue] = []
    func requireText(_ value: String, _ path: String) {
      if value.isBlank { issues.append(.emptyValue(path: path)) }
    }
    func requireRepoRelativePath(_ path: String, _ fieldPath: String, allowed: String) {
      let components = path.split(separator: "/")
      if path.isBlank || path.hasPrefix("/") || components.contains("..") {
        issues.append(.outOfRange(path: fieldPath, value: path, allowed: allowed))
      }
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
    let simctlTimeouts = SimulatorConfig.simctlTimeoutSecondsRange
    if !simctlTimeouts.contains(simulator.simctlTimeoutSeconds) {
      issues.append(
        .outOfRange(
          path: SimulatorConfig.simctlTimeoutKey, value: "\(simulator.simctlTimeoutSeconds)",
          allowed: "\(simctlTimeouts.lowerBound)...\(simctlTimeouts.upperBound)"))
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
    if let workers = mutation.maxWorkers, workers < 1 {
      issues.append(.outOfRange(path: "mutation.max_workers", value: "\(workers)", allowed: ">= 1"))
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

    if case .enabled(_, let thresholds, _) = judge {
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
    if case .enabled(let backend, _, let model?) = judge, let pin = backend.pinnedModel,
      !backend.isPinned(model)
    {
      issues.append(
        .judgeModelNotPinned(path: "judge.model", value: model, backend: backend, pin: pin))
    }
    for (index, path) in exclude.enumerated() {
      requireRepoRelativePath(
        path, "exclude[\(index)]", allowed: "a repository-relative directory")
    }

    for (index, path) in docs.managedFiles.enumerated() {
      requireText(path, "docs.managed_files[\(index)]")
      requireRepoRelativePath(
        path, "docs.managed_files[\(index)]", allowed: "a repository-relative path")
    }
    for (index, phrase) in docs.bannedPhrases.enumerated() {
      requireText(phrase.phrase, "docs.banned_phrases[\(index)].phrase")
      requireText(phrase.reason, "docs.banned_phrases[\(index)].reason")
    }
    if docs.sentenceCeiling < 1 {
      issues.append(
        .outOfRange(
          path: "docs.sentence_ceiling", value: "\(docs.sentenceCeiling)", allowed: ">= 1"))
    }
    let docsBudgetEntries: [(String, Int)] = [
      ("docs.budgets.router", docs.budgets.router), ("docs.budgets.topic", docs.budgets.topic),
      ("docs.budgets.design", docs.budgets.design),
      ("docs.budgets.agents_md_lines", docs.budgets.agentsMdLines),
    ]
    for (path, value) in docsBudgetEntries where value < 1 {
      issues.append(.outOfRange(path: path, value: "\(value)", allowed: ">= 1"))
    }
    for name in docs.budgets.sections.keys.sorted() {
      let value = docs.budgets.sections[name]!
      if value < 1 {
        issues.append(
          .outOfRange(path: "docs.budgets.sections.\(name)", value: "\(value)", allowed: ">= 1"))
      }
    }
    for file in docs.budgets.files.keys.sorted() {
      let value = docs.budgets.files[file]!
      requireRepoRelativePath(
        file, "docs.budgets.files.\(file)", allowed: "a repository-relative path")
      if value < 1 {
        issues.append(
          .outOfRange(path: "docs.budgets.files.\(file)", value: "\(value)", allowed: ">= 1"))
      }
    }
    for (index, glob) in docs.proseExclude.enumerated() {
      if glob.isBlank {
        issues.append(.emptyValue(path: "docs.prose_exclude[\(index)]"))
      } else {
        requireRepoRelativePath(
          glob, "docs.prose_exclude[\(index)]", allowed: "a repository-relative glob")
      }
    }

    if plan.maxParallel < 1 {
      issues.append(
        .outOfRange(path: "plan.max_parallel", value: "\(plan.maxParallel)", allowed: ">= 1"))
    }
    if plan.estLinesMin < 1 {
      issues.append(
        .outOfRange(path: "plan.est_lines_min", value: "\(plan.estLinesMin)", allowed: ">= 1"))
    }
    if plan.estLinesMax < plan.estLinesMin {
      issues.append(
        .outOfRange(
          path: "plan.est_lines_max", value: "\(plan.estLinesMax)",
          allowed: ">= plan.est_lines_min"))
    }
    if plan.maxModulesPerTask < 1 {
      issues.append(
        .outOfRange(
          path: "plan.max_modules_per_task", value: "\(plan.maxModulesPerTask)", allowed: ">= 1"))
    }
    if plan.maxTestsPerTask < 1 {
      issues.append(
        .outOfRange(
          path: "plan.max_tests_per_task", value: "\(plan.maxTestsPerTask)", allowed: ">= 1"))
    }
    if plan.workerPackTokenBudget < 1 {
      issues.append(
        .outOfRange(
          path: "plan.worker_pack_token_budget", value: "\(plan.workerPackTokenBudget)",
          allowed: ">= 1"))
    }

    for name in buildPresets.keys.sorted() {
      let preset = buildPresets[name]!
      let path = "build.presets.\(name)"
      if preset.maxParallel < 1 {
        issues.append(
          .outOfRange(
            path: "\(path).max_parallel", value: "\(preset.maxParallel)", allowed: ">= 1"))
      }
      if preset.timeBudgetMin < 0 {
        issues.append(
          .outOfRange(
            path: "\(path).time_budget_min", value: "\(preset.timeBudgetMin)", allowed: ">= 0"))
      }
      if preset.stopStartsBeforeMin < 0 {
        issues.append(
          .outOfRange(
            path: "\(path).stop_starts_before_min", value: "\(preset.stopStartsBeforeMin)",
            allowed: ">= 0"))
      } else if preset.stopStartsBeforeMin > preset.timeBudgetMin {
        issues.append(
          .outOfRange(
            path: "\(path).stop_starts_before_min", value: "\(preset.stopStartsBeforeMin)",
            allowed: "<= \(path).time_budget_min"))
      }
    }
    if let profile { requireText(profile, "harness.profile") }
    return issues
  }
}

public struct SimulatorConfig: Sendable, Equatable {
  public static let defaultMaxConcurrent = 2
  /// A loaded machine (load average 60) took over 60 s to answer `simctl list`.
  public static let defaultSimctlTimeoutSeconds = 180
  public static let simctlTimeoutSecondsRange = 30...1800
  public static let simctlTimeoutKey = "simulator.simctl_timeout_seconds"

  public let device: String
  public let os: String
  /// Machine-wide cap on concurrent simulator runs across every worktree.
  public let maxConcurrent: Int
  /// Deadline for each `simctl` call other than booting and installing.
  public let simctlTimeoutSeconds: Int

  public init(
    device: String, os: String, maxConcurrent: Int = Self.defaultMaxConcurrent,
    simctlTimeoutSeconds: Int = Self.defaultSimctlTimeoutSeconds
  ) {
    self.device = device
    self.os = os
    self.maxConcurrent = maxConcurrent
    self.simctlTimeoutSeconds = simctlTimeoutSeconds
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
  /// Scratch worktrees running mutants at once; `nil` for ``MutationWorkers``' default.
  public let maxWorkers: Int?

  public init(maxMutants: Int = 30, maxWorkers: Int? = nil) {
    self.maxMutants = maxMutants
    self.maxWorkers = maxWorkers
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

/// `[telemetry]`: whether harness events are written under `.harness/events/`. Events stay on the
/// machine; no key sends them anywhere. The judge's audit events ignore this switch.
public struct TelemetryConfig: Sendable, Equatable {
  public let enabled: Bool

  public init(enabled: Bool = true) {
    self.enabled = enabled
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
  case testSupport = "test-support"
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
  /// `model` is the backend's model name; `nil` means the backend's default.
  case enabled(backend: JudgeBackend, thresholds: JudgeThresholds, model: String? = nil)
}

public enum JudgeBackend: String, Sendable, Equatable, CaseIterable {
  case claude
  /// TypeSafe's Jev over HTTP; it sends judged code to ``egressHost``, so config must name that host.
  case jev

  /// Whether each answer carries the backend's own rationale; a blocking finding from a backend
  /// without one gets its reason from Claude (spec §6).
  public var writesReasons: Bool {
    switch self {
    case .claude: true
    case .jev: false
    }
  }

  /// The third-party host this backend sends test source to, which `[judge] send_to` must name
  /// before the backend runs. `nil` when there is no such host to name.
  public var egressHost: String? {
    switch self {
    case .claude: nil
    case .jev: "api.typesafe.ai"
    }
  }

  /// The versioned model used when `[judge] model` is unset. `nil` when the adapter picks its own
  /// default.
  public var pinnedModel: String? {
    switch self {
    case .claude: nil
    case .jev: "jev-1.13.0"
    }
  }

  /// The environment variable the backend reads its API key from; config never holds the key.
  public var keyVariable: String? {
    switch self {
    case .claude: nil
    case .jev: "TYPESAFE_API_KEY"
    }
  }

  /// Why `sendTo`, found at `path`, doesn't allow this backend's egress: it names no host where
  /// the backend needs one, a host that isn't exactly ``egressHost``, or a host where the backend
  /// sends nowhere. `nil` when it allows it.
  public func egressIssue(sendTo: String?, path: String) -> ConfigIssue? {
    guard let host = egressHost else {
      return sendTo == nil ? nil : .judgeHostUnused(path: path, backend: self)
    }
    guard let sendTo else { return .judgeHostNotNamed(path: path, backend: self, host: host) }
    return sendTo == host
      ? nil : .judgeHostMismatch(path: path, value: sendTo, backend: self, host: host)
  }

  /// Whether `model` names one fixed model rather than an alias that can move to a new one.
  public func isPinned(_ model: String) -> Bool {
    switch self {
    case .claude:
      return true
    case .jev:
      // TypeSafe versions are `jev-<major>.<minor>.<patch>`; `jev-latest` and `jev-preview` move.
      guard model.hasPrefix("jev-") else { return false }
      let parts = model.dropFirst("jev-".count).split(
        separator: ".", omittingEmptySubsequences: false)
      return parts.count == 3
        && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
  }
}

/// Probability thresholds: `p >= block` may block at the `ready` tier; `advisory <= p < block` is
/// advisory; below `advisory` is ignored.
public struct JudgeThresholds: Sendable, Equatable {
  public let advisory: Double
  public let block: Double

  /// What a `[judge]` table gets for a threshold key it leaves out.
  public static let defaults = JudgeThresholds(advisory: 0.6, block: 0.9)

  public init(advisory: Double, block: Double) {
    self.advisory = advisory
    self.block = block
  }
}

extension String {
  var isBlank: Bool { allSatisfy(\.isWhitespace) }
}

/// Rules `docs-lint` and `prose` apply to markdown under `docs/`, `AGENTS.md` and design docs.
/// Absent from a repository's config, `docs-lint` and `prose` still run with these defaults.
public struct DocsConfig: Sendable, Equatable {
  public static let defaultSentenceCeiling = 40

  /// Repository-relative paths `docs-lint` requires to exist, such as the stamped router and the
  /// `AGENTS.md` pointer.
  public let managedFiles: [String]
  public let bannedPhrases: [BannedPhrase]
  /// Extra anchors `docs-lint`'s non-vacuity check accepts, beyond the ids it already knows.
  public let anchors: [String]
  /// Words per sentence before `prose` flags it; an estimate, tuned like the other prose budgets.
  public let sentenceCeiling: Int
  public let budgets: DocsBudgets
  /// Repository-relative globs that `prose` and the word budgets skip. Links, ids and router
  /// reachability still cover them. `**` spans any number of directories; `*` and `?` stay
  /// within one. Empty by default, so a consumer repo's docs are all covered.
  public let proseExclude: [String]

  public init(
    managedFiles: [String] = [],
    bannedPhrases: [BannedPhrase] = [],
    anchors: [String] = [],
    sentenceCeiling: Int = Self.defaultSentenceCeiling,
    budgets: DocsBudgets = DocsBudgets(),
    proseExclude: [String] = []
  ) {
    self.managedFiles = managedFiles
    self.bannedPhrases = bannedPhrases
    self.anchors = anchors
    self.sentenceCeiling = sentenceCeiling
    self.budgets = budgets
    self.proseExclude = proseExclude
  }

  public func isProseExcluded(_ repoRelativePath: String) -> Bool {
    let path = repoRelativePath.split(separator: "/").map(String.init)
    return proseExclude.contains { glob in
      Self.matches(glob.split(separator: "/").map(String.init)[...], path[...])
    }
  }

  private static func matches(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
    guard let head = pattern.first else { return path.isEmpty }
    if head == "**" {
      let rest = pattern.dropFirst()
      return path.indices.contains { matches(rest, path[$0...]) }
        || matches(rest, path[path.endIndex...])
    }
    guard let segment = path.first, fnmatch(head, segment, 0) == 0 else { return false }
    return matches(pattern.dropFirst(), path.dropFirst())
  }
}

/// A phrase `docs-lint`'s banned-phrases family rejects. `reason` is mandatory: a ban nobody can
/// explain is a ban nobody can act on when it fires.
public struct BannedPhrase: Sendable, Equatable {
  public let phrase: String
  public let reason: String

  public init(phrase: String, reason: String) {
    self.phrase = phrase
    self.reason = reason
  }
}

/// Prose word budgets. Tables, diagrams and code never count toward any of these.
public struct DocsBudgets: Sendable, Equatable {
  public static let defaultRouterWords = 400
  public static let defaultTopicWords = 800
  public static let defaultDesignWords = 1_200
  public static let defaultAgentsMdLines = 60
  /// Default per-section overrides, keyed by the design doc's GitHub-style anchor slug
  /// (`MarkdownDocument.Section.anchor`). Architecture's 80-word cap is spec §5.3's own table entry,
  /// not a tunable estimate like the others here — but it still lives in config, never in the lint,
  /// so `[docs.budgets.sections]` can raise or lower it per repo. A user's `sections` table merges
  /// over this default; it doesn't replace it (`ConfigSchema.readDocsBudgets`).
  public static let defaultSectionWords: [String: Int] = ["architecture": 80]

  /// Budget for `docs/index.md` and area routers.
  public let router: Int
  /// Budget for a one-topic doc file.
  public let topic: Int
  /// Whole-design-doc default; an estimate, tuned from real designs (spec §5.3).
  public let design: Int
  public let agentsMdLines: Int
  /// Per design-section-anchor word budget. A section absent here is bounded only by the
  /// whole-document `design` budget, not individually.
  public let sections: [String: Int]
  /// Per-file word budgets keyed by repository-relative path. Each replaces the router or topic
  /// budget for that one file. Empty by default.
  public let files: [String: Int]

  public init(
    router: Int = Self.defaultRouterWords,
    topic: Int = Self.defaultTopicWords,
    design: Int = Self.defaultDesignWords,
    agentsMdLines: Int = Self.defaultAgentsMdLines,
    sections: [String: Int] = Self.defaultSectionWords,
    files: [String: Int] = [:]
  ) {
    self.files = files
    self.router = router
    self.topic = topic
    self.design = design
    self.agentsMdLines = agentsMdLines
    self.sections = sections
  }
}

/// Bounds `plan-schedule` and `plan-lint` enforce on a decomposed plan (spec §9.3).
public struct PlanConfig: Sendable, Equatable {
  public static let defaultMaxParallel = 3
  public static let defaultEstLinesMin = 40
  public static let defaultEstLinesMax = 400
  public static let defaultMaxModulesPerTask = 2
  public static let defaultMaxTestsPerTask = 6
  public static let defaultWorkerPackTokenBudget = 15_000

  /// Width cap on `plan-schedule`'s wave layers.
  public let maxParallel: Int
  /// Below this, `plan-lint` warns a task is too small to be its own unit.
  public let estLinesMin: Int
  /// Above this, `plan-lint` errors: split the task.
  public let estLinesMax: Int
  /// Only an interface + live pair may share a task above 1.
  public let maxModulesPerTask: Int
  public let maxTestsPerTask: Int
  /// Estimated tokens (UTF-8 bytes / 4) a worker's `context-pack` may hold before `plan-lint`
  /// flags it as over budget.
  public let workerPackTokenBudget: Int

  public init(
    maxParallel: Int = Self.defaultMaxParallel,
    estLinesMin: Int = Self.defaultEstLinesMin,
    estLinesMax: Int = Self.defaultEstLinesMax,
    maxModulesPerTask: Int = Self.defaultMaxModulesPerTask,
    maxTestsPerTask: Int = Self.defaultMaxTestsPerTask,
    workerPackTokenBudget: Int = Self.defaultWorkerPackTokenBudget
  ) {
    self.maxParallel = maxParallel
    self.estLinesMin = estLinesMin
    self.estLinesMax = estLinesMax
    self.maxModulesPerTask = maxModulesPerTask
    self.maxTestsPerTask = maxTestsPerTask
    self.workerPackTokenBudget = workerPackTokenBudget
  }
}
