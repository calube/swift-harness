/// Validates a parsed config document against the `.swiftgate.toml` schema.
///
/// Reading collects every presence, type, and unknown-key problem instead of stopping at the first;
/// cross-field rules then come from ``Config``'s own invariants so there is one source for them.
/// Issues are ordered: each table's unknown keys, then its keys in schema order, then cross-field
/// rules.
public enum ConfigSchema {
  public static func config(from document: ConfigValue) throws(ConfigValidationError) -> Config {
    var reader = Reader()
    guard case .table(let root) = document else {
      throw ConfigValidationError(
        issues: [.wrongType(path: "(root)", expected: "table", found: document.typeName)])
    }
    reader.rejectUnknownKeys(
      in: root, at: "",
      allowed: [
        "schema", "xcode", "app_scheme", "packages", "simulator", "pyramid", "flows", "mutation",
        "budgets", "clients", "modules", "judge", "docs", "plan", "build", "harness", "exclude",
        "telemetry", "scenarios", "qa",
      ])

    if let schema = reader.integer(root, "schema", at: "", required: true),
      schema != Config.supportedSchema
    {
      reader.issues.append(.unsupportedSchema(found: schema))
    }
    let xcode = reader.string(root, "xcode", at: "", required: true) ?? ""
    let appScheme = reader.string(root, "app_scheme", at: "", required: true) ?? ""
    let packages = reader.stringArray(root, "packages", at: "", required: true) ?? []
    let exclude = reader.stringArray(root, "exclude", at: "") ?? []

    let simulator = readSimulator(&reader, root)
    let pyramid = readPyramid(&reader, root)
    let flows = readFlows(&reader, root)
    let mutation = readMutation(&reader, root)
    let budgets = readBudgets(&reader, root)
    let clients = readClients(&reader, root)
    let modules = readModules(&reader, root)
    let judge = readJudge(&reader, root)
    let docs = readDocs(&reader, root)
    let plan = readPlan(&reader, root)
    let buildPresets = readBuild(&reader, root, profile: .owned)
    let profile = readHarness(&reader, root)
    let telemetry = readTelemetry(&reader, root)
    let scenarios = readScenarios(&reader, root)
    let qa = readQA(&reader, root)

    // A key that failed to read was replaced by a placeholder; rule violations on that placeholder
    // (or anything under it) would only restate the read issue.
    let readIssuePaths = reader.issues.map(\.path)
    func restatesReadIssue(_ issue: ConfigIssue) -> Bool {
      readIssuePaths.contains { read in
        issue.path == read || issue.path.hasPrefix(read + ".") || issue.path.hasPrefix(read + "[")
      }
    }
    let invariantIssues = Config.invariantIssues(
      xcode: xcode, appScheme: appScheme, packages: packages, simulator: simulator,
      pyramid: pyramid, flows: flows, mutation: mutation, budgets: budgets, clients: clients,
      modules: modules, judge: judge, docs: docs, plan: plan, buildPresets: buildPresets,
      profile: profile, exclude: exclude, scenarios: scenarios, qa: qa
    ).filter { !restatesReadIssue($0) }
    let issues = reader.issues + invariantIssues
    if !issues.isEmpty { throw ConfigValidationError(issues: issues) }

    return try Config(
      xcode: xcode, appScheme: appScheme, packages: packages, simulator: simulator,
      pyramid: pyramid, flows: flows, mutation: mutation, budgets: budgets, clients: clients,
      modules: modules, judge: judge, docs: docs, plan: plan, buildPresets: buildPresets,
      profile: profile, exclude: exclude, telemetry: telemetry, scenarios: scenarios, qa: qa)
  }

  private static func readSimulator(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> SimulatorConfig
  {
    let path = "simulator"
    guard let table = reader.table(root, path, at: "", required: true) else {
      return SimulatorConfig(device: "", os: "")
    }
    reader.rejectUnknownKeys(
      in: table, at: path, allowed: ["device", "os", "max_concurrent", "simctl_timeout_seconds"])
    return SimulatorConfig(
      device: reader.string(table, "device", at: path, required: true) ?? "",
      os: reader.string(table, "os", at: path, required: true) ?? "",
      maxConcurrent: reader.integer(table, "max_concurrent", at: path)
        ?? SimulatorConfig.defaultMaxConcurrent,
      simctlTimeoutSeconds: reader.integer(table, "simctl_timeout_seconds", at: path)
        ?? SimulatorConfig.defaultSimctlTimeoutSeconds)
  }

  private static func readPyramid(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> PyramidConfig
  {
    let path = "pyramid"
    let defaults = PyramidConfig()
    guard let table = reader.table(root, path, at: "") else { return defaults }
    reader.rejectUnknownKeys(in: table, at: path, allowed: ["diff_coverage_min", "max_flows"])
    return PyramidConfig(
      diffCoverageMin: reader.double(table, "diff_coverage_min", at: path)
        ?? defaults.diffCoverageMin,
      maxFlows: reader.integer(table, "max_flows", at: path) ?? defaults.maxFlows)
  }

  private static func readFlows(_ reader: inout Reader, _ root: [String: ConfigValue]) -> [Flow] {
    reader.tableArray(root, "flows", at: "").map { path, table in
      reader.rejectUnknownKeys(in: table, at: path, allowed: ["name", "reason"])
      return Flow(
        name: reader.string(table, "name", at: path, required: true) ?? "",
        reason: reader.string(table, "reason", at: path, required: true) ?? "")
    }
  }

  private static func readScenarios(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> [Scenario]
  {
    reader.tableArray(root, "scenarios", at: "").map { path, table in
      reader.rejectUnknownKeys(in: table, at: path, allowed: ["name", "reason"])
      return Scenario(
        name: reader.string(table, "name", at: path, required: true) ?? "",
        reason: reader.string(table, "reason", at: path, required: true) ?? "")
    }
  }

  private static func readQA(_ reader: inout Reader, _ root: [String: ConfigValue]) -> QAConfig {
    let path = "qa"
    guard let table = reader.table(root, path, at: "") else { return QAConfig() }
    reader.rejectUnknownKeys(
      in: table, at: path, allowed: ["session_timeout_minutes", "accessibility_ids"])
    return QAConfig(
      sessionTimeoutMinutes: reader.integer(table, "session_timeout_minutes", at: path)
        ?? QAConfig.defaultSessionTimeoutMinutes,
      accessibilityIDs: reader.string(table, "accessibility_ids", at: path))
  }

  private static func readMutation(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> MutationConfig
  {
    let path = "mutation"
    let defaults = MutationConfig()
    guard let table = reader.table(root, path, at: "") else { return defaults }
    reader.rejectUnknownKeys(in: table, at: path, allowed: ["max_mutants", "max_workers"])
    return MutationConfig(
      maxMutants: reader.integer(table, "max_mutants", at: path) ?? defaults.maxMutants,
      maxWorkers: reader.integer(table, "max_workers", at: path))
  }

  private static func readBudgets(_ reader: inout Reader, _ root: [String: ConfigValue]) -> Budgets
  {
    let path = "budgets"
    let defaults = Budgets()
    guard let table = reader.table(root, path, at: "") else { return defaults }
    reader.rejectUnknownKeys(in: table, at: path, allowed: ["t0", "t1", "t2", "t3", "stop_hook"])
    func seconds(_ key: String, default value: Duration?) -> Duration? {
      reader.integer(table, key, at: path).map { .seconds($0) } ?? value
    }
    return Budgets(
      t0: seconds("t0", default: defaults.t0), t1: seconds("t1", default: defaults.t1),
      t2: seconds("t2", default: defaults.t2), t3: seconds("t3", default: defaults.t3),
      stopHook: seconds("stop_hook", default: defaults.stopHook))
  }

  private static func readClients(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> ClientsConfig
  {
    let path = "clients"
    guard let table = reader.table(root, path, at: "") else { return ClientsConfig() }
    reader.rejectUnknownKeys(in: table, at: path, allowed: ["vendor_modules"])
    return ClientsConfig(vendorModules: reader.stringArray(table, "vendor_modules", at: path) ?? [])
  }

  private static func readModules(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> [ModuleOverride]
  {
    reader.tableArray(root, "modules", at: "").map { path, table in
      reader.rejectUnknownKeys(
        in: table, at: path, allowed: ["name", "kind", "host_testable", "reason"])
      let name = reader.string(table, "name", at: path, required: true) ?? ""
      var kind = ModuleKind.feature
      if let raw = reader.string(table, "kind", at: path) {
        if let parsed = ModuleKind(rawValue: raw) {
          kind = parsed
        } else {
          reader.issues.append(.unknownModuleKind(path: "\(path).kind", value: raw))
        }
      }
      return ModuleOverride(
        name: name, kind: kind,
        hostTestable: reader.bool(table, "host_testable", at: path) ?? true,
        reason: reader.string(table, "reason", at: path))
    }
  }

  /// `[judge]`, which the brownfield profile spells the same way.
  static func readJudge(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> JudgeConfig
  {
    let path = "judge"
    guard let table = reader.table(root, path, at: "") else { return .disabled }
    let allowed: Set = ["backend", "model", "send_to", "advisory_threshold", "block_threshold"]
    for key in table.keys.sorted() where !allowed.contains(key) {
      let keyPath = "\(path).\(key)"
      reader.issues.append(
        looksLikeCredential(key) ? .judgeSecretInConfig(path: keyPath) : .unknownKey(path: keyPath))
    }
    let rawBackend = reader.string(table, "backend", at: path, required: true)
    let backend: JudgeBackend?
    switch rawBackend {
    case nil, "none":
      backend = nil
    case let raw?:
      backend = JudgeBackend(rawValue: raw)
      if backend == nil {
        reader.issues.append(.unknownJudgeBackend(path: "\(path).backend", value: raw))
      }
    }
    // A threshold of the wrong type reads as nil and is already reported, so only an absent key
    // takes the default.
    let advisory =
      table["advisory_threshold"] == nil
      ? JudgeThresholds.defaults.advisory
      : reader.double(table, "advisory_threshold", at: path)
    let block =
      table["block_threshold"] == nil
      ? JudgeThresholds.defaults.block : reader.double(table, "block_threshold", at: path)
    let model = reader.string(table, "model", at: path)
    // A send_to of the wrong type, or beside a missing or unknown backend, is already reported.
    let sendTo = reader.string(table, "send_to", at: path)
    let sendToReadable = table["send_to"] == nil || sendTo != nil
    if sendToReadable, rawBackend == "none" || backend != nil {
      let sendToPath = "\(path).send_to"
      if let backend {
        if let issue = backend.egressIssue(sendTo: sendTo, path: sendToPath) {
          reader.issues.append(issue)
        }
      } else if sendTo != nil {
        reader.issues.append(.judgeHostUnused(path: sendToPath, backend: backend))
      }
    }
    guard let backend, let advisory, let block else { return .disabled }
    return .enabled(
      backend: backend, thresholds: JudgeThresholds(advisory: advisory, block: block), model: model)
  }

  /// A key a person might hold an API key in. Matched loosely: a false match only renames the
  /// unknown-key issue, while a miss would let a credential be committed with a generic error.
  private static func looksLikeCredential(_ key: String) -> Bool {
    let lowered = key.lowercased()
    return ["key", "token", "secret", "password", "credential"].contains { lowered.contains($0) }
  }

  private static func readDocs(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> DocsConfig
  {
    let path = "docs"
    let defaults = DocsConfig()
    guard let table = reader.table(root, path, at: "") else { return defaults }
    reader.rejectUnknownKeys(
      in: table, at: path,
      allowed: [
        "managed_files", "banned_phrases", "anchors", "sentence_ceiling", "budgets",
        "prose_exclude",
      ])
    let bannedPhrases = reader.tableArray(table, "banned_phrases", at: path).map {
      phrasePath, phraseTable in
      reader.rejectUnknownKeys(in: phraseTable, at: phrasePath, allowed: ["phrase", "reason"])
      return BannedPhrase(
        phrase: reader.string(phraseTable, "phrase", at: phrasePath, required: true) ?? "",
        reason: reader.string(phraseTable, "reason", at: phrasePath, required: true) ?? "")
    }
    return DocsConfig(
      managedFiles: reader.stringArray(table, "managed_files", at: path) ?? defaults.managedFiles,
      bannedPhrases: bannedPhrases,
      anchors: reader.stringArray(table, "anchors", at: path) ?? defaults.anchors,
      sentenceCeiling: reader.integer(table, "sentence_ceiling", at: path)
        ?? defaults.sentenceCeiling,
      budgets: readDocsBudgets(&reader, table, at: path),
      proseExclude: reader.stringArray(table, "prose_exclude", at: path) ?? defaults.proseExclude)
  }

  private static func readDocsBudgets(
    _ reader: inout Reader, _ docsTable: [String: ConfigValue], at docsPath: String
  ) -> DocsBudgets {
    let path = Reader.join(docsPath, "budgets")
    let defaults = DocsBudgets()
    guard let table = reader.table(docsTable, "budgets", at: docsPath) else { return defaults }
    reader.rejectUnknownKeys(
      in: table, at: path,
      allowed: ["router", "topic", "design", "agents_md_lines", "sections", "files"])
    // A repo's [docs.budgets.sections] adds to or overrides DocsBudgets.defaultSectionWords by
    // key; it never drops a default the repo didn't mention (e.g. Architecture's 80 words).
    let sections = defaults.sections.merging(reader.stringIntTable(table, "sections", at: path)) {
      _, configured in configured
    }
    return DocsBudgets(
      router: reader.integer(table, "router", at: path) ?? defaults.router,
      topic: reader.integer(table, "topic", at: path) ?? defaults.topic,
      design: reader.integer(table, "design", at: path) ?? defaults.design,
      agentsMdLines: reader.integer(table, "agents_md_lines", at: path) ?? defaults.agentsMdLines,
      sections: sections,
      files: reader.stringIntTable(table, "files", at: path))
  }

  private static func readPlan(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> PlanConfig
  {
    let path = "plan"
    let defaults = PlanConfig()
    guard let table = reader.table(root, path, at: "") else { return defaults }
    reader.rejectUnknownKeys(
      in: table, at: path,
      allowed: [
        "max_parallel", "est_lines_min", "est_lines_max", "max_modules_per_task",
        "max_tests_per_task", "worker_pack_token_budget",
      ])
    return PlanConfig(
      maxParallel: reader.integer(table, "max_parallel", at: path) ?? defaults.maxParallel,
      estLinesMin: reader.integer(table, "est_lines_min", at: path) ?? defaults.estLinesMin,
      estLinesMax: reader.integer(table, "est_lines_max", at: path) ?? defaults.estLinesMax,
      maxModulesPerTask: reader.integer(table, "max_modules_per_task", at: path)
        ?? defaults.maxModulesPerTask,
      maxTestsPerTask: reader.integer(table, "max_tests_per_task", at: path)
        ?? defaults.maxTestsPerTask,
      workerPackTokenBudget: reader.integer(table, "worker_pack_token_budget", at: path)
        ?? defaults.workerPackTokenBudget)
  }

  /// `[harness] profile`. Whether it names a defined preset is `doctor`'s check, not a load
  /// error, so a bad profile never stops a hook or gate from reading the config.
  private static func readHarness(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> String?
  {
    let path = "harness"
    guard let table = reader.table(root, path, at: "") else { return nil }
    reader.rejectUnknownKeys(in: table, at: path, allowed: ["profile"])
    return reader.string(table, "profile", at: path)
  }

  private static func readTelemetry(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> TelemetryConfig
  {
    let path = "telemetry"
    guard let table = reader.table(root, path, at: "") else { return TelemetryConfig() }
    reader.rejectUnknownKeys(in: table, at: path, allowed: ["enabled"])
    return TelemetryConfig(enabled: reader.bool(table, "enabled", at: path) ?? true)
  }

  /// `[build.presets.*]`, shared with ``BrownfieldConfigSchema``: a tier or model value from the
  /// other profile is an issue naming `profile`.
  static func readBuild(
    _ reader: inout Reader, _ root: [String: ConfigValue], profile: RepositoryProfile
  ) -> [String: BuildPreset] {
    let path = "build"
    guard let table = reader.table(root, path, at: "") else { return [:] }
    reader.rejectUnknownKeys(in: table, at: path, allowed: ["presets"])
    guard let presetsTable = reader.table(table, "presets", at: path, required: true) else {
      return [:]
    }
    let presetsPath = Reader.join(path, "presets")
    var presets: [String: BuildPreset] = [:]
    for name in presetsTable.keys.sorted() {
      let entryPath = Reader.join(presetsPath, name)
      guard case .table(let presetTable) = presetsTable[name]! else {
        reader.issues.append(
          .wrongType(
            path: entryPath, expected: "table", found: presetsTable[name]!.typeName))
        continue
      }
      presets[name] = readPreset(&reader, presetTable, at: entryPath, profile: profile)
    }
    return presets
  }

  private static func readPreset(
    _ reader: inout Reader, _ table: [String: ConfigValue], at path: String,
    profile: RepositoryProfile
  ) -> BuildPreset {
    var allowed: Set = [
      "design_tier", "max_parallel", "review", "task_gate", "merge_gate", "worker_model",
      "time_budget_min", "stop_starts_before_min", "on_design_conflict", "task_proof",
      "stall_min",
    ]
    // A brownfield run validates each merge with `qa run` instead, so only an owned preset
    // carries the key.
    if profile == .owned { allowed.insert("sim_qa") }
    reader.rejectUnknownKeys(in: table, at: path, allowed: allowed)
    let designTier: BuildPreset.DesignStep =
      readEnum(&reader, table, "design_tier", at: path) ?? .standard
    let review: BuildPreset.Review =
      readProfiled(&reader, table, "review", at: path, profile: profile) ?? .full
    let taskGate = readTaskGate(&reader, table, at: path, profile: profile)
    let mergeGate: CheckTier =
      readProfiled(&reader, table, "merge_gate", at: path, profile: profile) ?? .push
    let workerModel: BuildPreset.WorkerModel =
      readProfiled(&reader, table, "worker_model", at: path, profile: profile) ?? .tagged
    let readConflict: BuildPreset.OnDesignConflict? =
      readEnum(&reader, table, "on_design_conflict", at: path)
    let taskProof: BuildPreset.TaskProof =
      readProfiled(&reader, table, "task_proof", at: path, profile: profile) ?? .perTask
    let simQA: BuildPreset.SimQA =
      profile == .owned ? readEnum(&reader, table, "sim_qa", at: path) ?? .off : .off
    // With no design there is nothing to amend, so a conflict can only block. A brownfield plan
    // is its live PLAN.md, which the run amends itself, so it may answer `amend` with no design.
    if designTier == .none, profile == .owned, let readConflict, readConflict != .block {
      reader.issues.append(
        .outOfRange(
          path: Reader.join(path, "on_design_conflict"), value: readConflict.rawValue,
          allowed: "block, since \(Reader.join(path, "design_tier")) is \"none\""))
    }
    return BuildPreset(
      designTier: designTier,
      maxParallel: reader.integer(table, "max_parallel", at: path, required: true) ?? 0,
      review: review, taskGate: taskGate, mergeGate: mergeGate, workerModel: workerModel,
      timeBudgetMin: reader.integer(table, "time_budget_min", at: path, required: true) ?? 0,
      stopStartsBeforeMin: reader.integer(table, "stop_starts_before_min", at: path, required: true)
        ?? 0,
      onDesignConflict: readConflict ?? .amend, taskProof: taskProof,
      stallMin: reader.integer(table, "stall_min", at: path), simQA: simQA)
  }

  /// `task_gate` isn't a plain closed enum: `"ledger"` and every ``CheckTier`` raw value are both
  /// legal, so it can't share ``readEnum``'s `CaseIterable` constraint.
  private static func readTaskGate(
    _ reader: inout Reader, _ table: [String: ConfigValue], at path: String,
    profile: RepositoryProfile
  ) -> BuildPreset.TaskGate {
    guard let raw = reader.string(table, "task_gate", at: path, required: true) else {
      return .ledger
    }
    let allowed = ["ledger"] + CheckTier.allCases.filter { $0.profile == profile }.map(\.rawValue)
    switch BuildPreset.TaskGate(rawValue: raw) {
    case .ledger?: return .ledger
    case .tier(let tier)? where tier.profile == profile: return .tier(tier)
    case .tier?:
      reader.issues.append(
        .notInProfile(
          path: Reader.join(path, "task_gate"), value: raw, profile: profile, allowed: allowed))
    case nil:
      reader.issues.append(
        .unknownEnumValue(path: Reader.join(path, "task_gate"), value: raw, allowed: allowed))
    }
    return .ledger
  }

  /// A required closed key whose values belong to 1 profile or both. The allowed list names only
  /// `profile`'s values; a value of the other profile is a ``ConfigIssue/notInProfile(path:value:profile:allowed:)``.
  private static func readProfiled<Value>(
    _ reader: inout Reader, _ table: [String: ConfigValue], _ key: String, at path: String,
    profile: RepositoryProfile
  ) -> Value?
  where Value: RawRepresentable & CaseIterable & ProfileScoped, Value.RawValue == String {
    guard let raw = reader.string(table, key, at: path, required: true) else { return nil }
    let allowed = Value.allCases.filter { $0.profiles.contains(profile) }.map(\.rawValue)
    guard let value = Value(rawValue: raw) else {
      reader.issues.append(
        .unknownEnumValue(path: Reader.join(path, key), value: raw, allowed: allowed))
      return nil
    }
    guard value.profiles.contains(profile) else {
      reader.issues.append(
        .notInProfile(path: Reader.join(path, key), value: raw, profile: profile, allowed: allowed))
      return nil
    }
    return value
  }

  /// Reads a required string key as a closed enum. A value none of `Value`'s cases recognize is
  /// an `.unknownEnumValue` issue, not a silent fallback.
  private static func readEnum<Value>(
    _ reader: inout Reader, _ table: [String: ConfigValue], _ key: String, at path: String
  ) -> Value? where Value: RawRepresentable, Value: CaseIterable, Value.RawValue == String {
    guard let raw = reader.string(table, key, at: path, required: true) else { return nil }
    if let value = Value(rawValue: raw) { return value }
    reader.issues.append(
      .unknownEnumValue(
        path: Reader.join(path, key), value: raw, allowed: Value.allCases.map(\.rawValue)))
    return nil
  }
}

/// Typed, issue-collecting access to config tables. A read that fails records an issue and
/// returns `nil`, so callers substitute a placeholder and keep going.
struct Reader {
  var issues: [ConfigIssue] = []

  static func join(_ prefix: String, _ key: String) -> String {
    prefix.isEmpty ? key : "\(prefix).\(key)"
  }

  mutating func rejectUnknownKeys(
    in table: [String: ConfigValue], at prefix: String, allowed: Set<String>
  ) {
    for key in table.keys.sorted() where !allowed.contains(key) {
      issues.append(.unknownKey(path: Self.join(prefix, key)))
    }
  }

  private mutating func value(
    _ table: [String: ConfigValue], _ key: String, at prefix: String, required: Bool
  ) -> (ConfigValue, String)? {
    let path = Self.join(prefix, key)
    guard let value = table[key] else {
      if required { issues.append(.missingKey(path: path)) }
      return nil
    }
    return (value, path)
  }

  private mutating func typed<T>(
    _ table: [String: ConfigValue], _ key: String, at prefix: String, required: Bool,
    expected: String, _ extract: (ConfigValue) -> T?
  ) -> T? {
    guard let (value, path) = value(table, key, at: prefix, required: required) else { return nil }
    guard let result = extract(value) else {
      issues.append(.wrongType(path: path, expected: expected, found: value.typeName))
      return nil
    }
    return result
  }

  mutating func string(
    _ table: [String: ConfigValue], _ key: String, at prefix: String, required: Bool = false
  ) -> String? {
    typed(table, key, at: prefix, required: required, expected: "string") {
      if case .string(let s) = $0 { s } else { nil }
    }
  }

  mutating func integer(
    _ table: [String: ConfigValue], _ key: String, at prefix: String, required: Bool = false
  ) -> Int? {
    typed(table, key, at: prefix, required: required, expected: "integer") {
      if case .integer(let i) = $0 { Int(exactly: i) } else { nil }
    }
  }

  /// Accepts integers too, so `diff_coverage_min = 1` means 1.0.
  mutating func double(
    _ table: [String: ConfigValue], _ key: String, at prefix: String, required: Bool = false
  ) -> Double? {
    typed(table, key, at: prefix, required: required, expected: "number") {
      switch $0 {
      case .float(let d): d
      case .integer(let i): Double(i)
      default: nil
      }
    }
  }

  mutating func bool(
    _ table: [String: ConfigValue], _ key: String, at prefix: String, required: Bool = false
  ) -> Bool? {
    typed(table, key, at: prefix, required: required, expected: "boolean") {
      if case .boolean(let b) = $0 { b } else { nil }
    }
  }

  mutating func table(
    _ table: [String: ConfigValue], _ key: String, at prefix: String, required: Bool = false
  ) -> [String: ConfigValue]? {
    typed(table, key, at: prefix, required: required, expected: "table") {
      if case .table(let t) = $0 { t } else { nil }
    }
  }

  mutating func stringArray(
    _ table: [String: ConfigValue], _ key: String, at prefix: String, required: Bool = false
  ) -> [String]? {
    guard
      let elements = typed(
        table, key, at: prefix, required: required, expected: "array of strings",
        { if case .array(let a) = $0 { a } else { nil } })
    else { return nil }
    let path = Self.join(prefix, key)
    var strings: [String] = []
    for (index, element) in elements.enumerated() {
      if case .string(let s) = element {
        strings.append(s)
      } else {
        issues.append(
          .wrongType(path: "\(path)[\(index)]", expected: "string", found: element.typeName))
      }
    }
    return strings
  }

  /// An arbitrary-key table of integers, such as `[docs.budgets.sections]`. A key whose value
  /// isn't an integer is dropped and reported; it never silently becomes 0.
  mutating func stringIntTable(
    _ table: [String: ConfigValue], _ key: String, at prefix: String
  ) -> [String: Int] {
    guard let nested = self.table(table, key, at: prefix) else { return [:] }
    let path = Self.join(prefix, key)
    var result: [String: Int] = [:]
    for entryKey in nested.keys.sorted() {
      let entryPath = Self.join(path, entryKey)
      switch nested[entryKey]! {
      case .integer(let i):
        if let intValue = Int(exactly: i) {
          result[entryKey] = intValue
        } else {
          issues.append(.outOfRange(path: entryPath, value: "\(i)", allowed: "a platform Int"))
        }
      case let other:
        issues.append(.wrongType(path: entryPath, expected: "integer", found: other.typeName))
      }
    }
    return result
  }

  /// An array of tables, as `[[key]]` produces. Returns each table with its indexed path.
  mutating func tableArray(
    _ table: [String: ConfigValue], _ key: String, at prefix: String
  ) -> [(path: String, table: [String: ConfigValue])] {
    guard
      let elements = typed(
        table, key, at: prefix, required: false, expected: "array of tables",
        { if case .array(let a) = $0 { a } else { nil } })
    else { return [] }
    let path = Self.join(prefix, key)
    var tables: [(String, [String: ConfigValue])] = []
    for (index, element) in elements.enumerated() {
      if case .table(let t) = element {
        tables.append(("\(path)[\(index)]", t))
      } else {
        issues.append(
          .wrongType(path: "\(path)[\(index)]", expected: "table", found: element.typeName))
      }
    }
    return tables
  }
}
