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
        "budgets", "clients", "modules", "judge",
      ])

    if let schema = reader.integer(root, "schema", at: "", required: true),
      schema != Config.supportedSchema
    {
      reader.issues.append(.unsupportedSchema(found: schema))
    }
    let xcode = reader.string(root, "xcode", at: "", required: true) ?? ""
    let appScheme = reader.string(root, "app_scheme", at: "", required: true) ?? ""
    let packages = reader.stringArray(root, "packages", at: "", required: true) ?? []

    let simulator = readSimulator(&reader, root)
    let pyramid = readPyramid(&reader, root)
    let flows = readFlows(&reader, root)
    let mutation = readMutation(&reader, root)
    let budgets = readBudgets(&reader, root)
    let clients = readClients(&reader, root)
    let modules = readModules(&reader, root)
    let judge = readJudge(&reader, root)

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
      modules: modules, judge: judge
    ).filter { !restatesReadIssue($0) }
    let issues = reader.issues + invariantIssues
    if !issues.isEmpty { throw ConfigValidationError(issues: issues) }

    return try Config(
      xcode: xcode, appScheme: appScheme, packages: packages, simulator: simulator,
      pyramid: pyramid, flows: flows, mutation: mutation, budgets: budgets, clients: clients,
      modules: modules, judge: judge)
  }

  private static func readSimulator(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> SimulatorConfig
  {
    let path = "simulator"
    guard let table = reader.table(root, path, at: "", required: true) else {
      return SimulatorConfig(device: "", os: "")
    }
    reader.rejectUnknownKeys(in: table, at: path, allowed: ["device", "os", "max_concurrent"])
    return SimulatorConfig(
      device: reader.string(table, "device", at: path, required: true) ?? "",
      os: reader.string(table, "os", at: path, required: true) ?? "",
      maxConcurrent: reader.integer(table, "max_concurrent", at: path)
        ?? SimulatorConfig.defaultMaxConcurrent)
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

  private static func readMutation(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> MutationConfig
  {
    let path = "mutation"
    let defaults = MutationConfig()
    guard let table = reader.table(root, path, at: "") else { return defaults }
    reader.rejectUnknownKeys(in: table, at: path, allowed: ["max_mutants"])
    return MutationConfig(
      maxMutants: reader.integer(table, "max_mutants", at: path) ?? defaults.maxMutants)
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

  private static func readJudge(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> JudgeConfig
  {
    let path = "judge"
    guard let table = reader.table(root, path, at: "") else { return .disabled }
    reader.rejectUnknownKeys(
      in: table, at: path, allowed: ["backend", "advisory_threshold", "block_threshold"])
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
    let required = backend != nil
    let advisory = reader.double(table, "advisory_threshold", at: path, required: required)
    let block = reader.double(table, "block_threshold", at: path, required: required)
    guard let backend, let advisory, let block else { return .disabled }
    return .enabled(backend: backend, thresholds: JudgeThresholds(advisory: advisory, block: block))
  }
}

/// Typed, issue-collecting access to config tables. A read that fails records an issue and
/// returns `nil`, so callers substitute a placeholder and keep going.
private struct Reader {
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
