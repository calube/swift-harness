/// Validates a parsed `config.toml` document against the brownfield schema, collecting every
/// problem rather than stopping at the first. Every closed field fails on a value it doesn't
/// know and names the allowed values.
public enum BrownfieldConfigSchema {
  public static let profileName = "brownfield"

  public static func config(from document: ConfigValue) throws(ConfigValidationError)
    -> BrownfieldConfig
  {
    guard case .table(let root) = document else {
      throw ConfigValidationError(
        issues: [.wrongType(path: "(root)", expected: "table", found: document.typeName)])
    }
    var reader = Reader()
    reader.rejectUnknownKeys(
      in: root, at: "",
      allowed: ["schema", "harness", "brownfield", "areas", "allow", "judge", "build"])
    if let schema = reader.integer(root, "schema", at: "", required: true),
      schema != BrownfieldConfig.supportedSchema
    {
      reader.issues.append(.unsupportedSchema(found: schema))
    }
    readHarness(&reader, root)
    let settings = readSettings(&reader, root)
    let areas = readAreas(&reader, root)
    let allow = readAllow(&reader, root)
    let judge = ConfigSchema.readJudge(&reader, root)
    let buildPresets = ConfigSchema.readBuild(&reader, root, profile: .brownfield)
    let issues = reader.issues + Config.presetIssues(buildPresets)
    if !issues.isEmpty { throw ConfigValidationError(issues: issues) }
    return BrownfieldConfig(
      brownfield: settings, areas: areas, allow: allow, buildPresets: buildPresets, judge: judge)
  }

  private static func readHarness(_ reader: inout Reader, _ root: [String: ConfigValue]) {
    guard let table = reader.table(root, "harness", at: "", required: true) else { return }
    reader.rejectUnknownKeys(in: table, at: "harness", allowed: ["profile"])
    if let profile = reader.string(table, "profile", at: "harness", required: true),
      profile != profileName
    {
      reader.issues.append(
        .unknownEnumValue(path: "harness.profile", value: profile, allowed: [profileName]))
    }
  }

  private static func readSettings(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> BrownfieldSettings
  {
    let path = "brownfield"
    guard let table = reader.table(root, path, at: "", required: true) else {
      return BrownfieldSettings(
        discoveredAt: "", sliceBudgetSeconds: 0, timeBudgetMinutes: 0, sensitive: [])
    }
    reader.rejectUnknownKeys(
      in: table, at: path,
      allowed: ["discovered_at", "slice_budget_s", "time_budget_min", "sensitive"])
    let discoveredAt = reader.nonEmptyString(table, "discovered_at", at: path, required: true)
    let slice = reader.integer(table, "slice_budget_s", at: path, required: true)
    if let slice, slice < 1 {
      reader.issues.append(
        .outOfRange(path: "\(path).slice_budget_s", value: "\(slice)", allowed: ">= 1"))
    }
    let time = reader.integer(table, "time_budget_min", at: path, required: true)
    if let time, time < 0 {
      reader.issues.append(
        .outOfRange(path: "\(path).time_budget_min", value: "\(time)", allowed: ">= 0"))
    }
    return BrownfieldSettings(
      discoveredAt: discoveredAt ?? "", sliceBudgetSeconds: slice ?? 0,
      timeBudgetMinutes: time ?? 0,
      sensitive: reader.stringArray(table, "sensitive", at: path) ?? [])
  }

  private static func readAreas(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> [BrownfieldArea]
  {
    var seen: Set<String> = []
    return reader.tableArray(root, "areas", at: "").compactMap { path, table in
      reader.rejectUnknownKeys(
        in: table, at: path,
        allowed: [
          "name", "root", "language", "kind", "test", "test_files", "lint", "build", "e2e",
          "test_globs", "packs", "xcode",
        ])
      let name = reader.nonEmptyString(table, "name", at: path, required: true)
      if let name, !seen.insert(name).inserted {
        reader.issues.append(.duplicateName(path: "\(path).name", name: name))
      }
      let root = reader.nonEmptyString(table, "root", at: path, required: true)
      let language: AreaLanguage? = reader.closed(table, "language", at: path, required: true)
      let kind: AreaKind? = reader.closed(table, "kind", at: path, required: true)
      let commands = [AreaStep.test, .testFiles, .lint, .build, .e2e].map { step in
        reader.nonEmptyString(table, step.rawValue, at: path)
      }
      let packs = (reader.stringArray(table, "packs", at: path) ?? []).enumerated().compactMap {
        index, raw -> AreaPack? in
        if let pack = AreaPack(rawValue: raw) { return pack }
        reader.issues.append(
          .unknownEnumValue(
            path: "\(path).packs[\(index)]", value: raw,
            allowed: AreaPack.allCases.map(\.rawValue)))
        return nil
      }
      let xcode = readXcode(&reader, table, at: path, area: name ?? "", kind: kind)
      guard let name, let root, let language, let kind else { return nil }
      return BrownfieldArea(
        name: name, root: root, language: language, kind: kind, test: commands[0],
        testFiles: commands[1], lint: commands[2], build: commands[3], e2e: commands[4],
        testGlobs: reader.stringArray(table, "test_globs", at: path) ?? [], packs: packs,
        xcode: xcode)
    }
  }

  private static func readXcode(
    _ reader: inout Reader, _ area: [String: ConfigValue], at areaPath: String, area name: String,
    kind: AreaKind?
  ) -> XcodeAreaConfig? {
    let path = Reader.join(areaPath, "xcode")
    guard let table = reader.table(area, "xcode", at: areaPath) else {
      if kind == .xcode, area["xcode"] == nil {
        reader.issues.append(.xcodeTableMissing(path: path, area: name))
      }
      return nil
    }
    if let kind, kind != .xcode {
      reader.issues.append(.xcodeTableUnexpected(path: path, area: name, kind: kind))
    }
    reader.rejectUnknownKeys(
      in: table, at: path, allowed: ["workspace", "project", "inclusion", "manifest", "schemes"])
    let workspace = reader.nonEmptyString(table, "workspace", at: path)
    let project = reader.nonEmptyString(table, "project", at: path)
    if (table["workspace"] == nil) == (table["project"] == nil) {
      reader.issues.append(.exactlyOne(path: path, keys: ["workspace", "project"]))
    }
    let inclusion: XcodeInclusion? = reader.closed(table, "inclusion", at: path, required: true)
    let generated = inclusion == .xcodegen || inclusion == .tuist
    let manifest = reader.nonEmptyString(table, "manifest", at: path, required: generated)
    guard let inclusion else { return nil }
    return XcodeAreaConfig(
      workspace: workspace, project: project, inclusion: inclusion, manifest: manifest,
      schemes: reader.stringArray(table, "schemes", at: path) ?? [])
  }

  private static func readAllow(_ reader: inout Reader, _ root: [String: ConfigValue])
    -> [BrownfieldAllow]
  {
    reader.tableArray(root, "allow", at: "").compactMap { path, table in
      reader.rejectUnknownKeys(
        in: table, at: path, allowed: ["rule", "path", "line_sha", "reason"])
      let rule = reader.nonEmptyString(table, "rule", at: path, required: true)
      let file = reader.nonEmptyString(table, "path", at: path, required: true)
      let lineSHA = reader.string(table, "line_sha", at: path, required: true)
      if let lineSHA, !isSHA256(lineSHA) {
        reader.issues.append(
          .outOfRange(
            path: "\(path).line_sha", value: lineSHA, allowed: "64 lowercase hex characters"))
      }
      let reason = reader.nonEmptyString(table, "reason", at: path, required: true)
      guard let rule, let file, let lineSHA, let reason else { return nil }
      return BrownfieldAllow(rule: rule, path: file, lineSHA: lineSHA, reason: reason)
    }
  }

  private static func isSHA256(_ text: String) -> Bool {
    text.utf8.count == 64
      && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

extension Reader {
  /// A string that must hold something other than whitespace when present.
  mutating func nonEmptyString(
    _ table: [String: ConfigValue], _ key: String, at prefix: String, required: Bool = false
  ) -> String? {
    guard let value = string(table, key, at: prefix, required: required) else { return nil }
    guard !value.isBlank else {
      issues.append(.emptyValue(path: Self.join(prefix, key)))
      return nil
    }
    return value
  }

  /// A string read as a closed enum; an unknown value names the allowed ones.
  mutating func closed<Value>(
    _ table: [String: ConfigValue], _ key: String, at prefix: String, required: Bool = false
  ) -> Value? where Value: RawRepresentable & CaseIterable, Value.RawValue == String {
    guard let raw = string(table, key, at: prefix, required: required) else { return nil }
    if let value = Value(rawValue: raw) { return value }
    issues.append(
      .unknownEnumValue(
        path: Self.join(prefix, key), value: raw, allowed: Value.allCases.map(\.rawValue)))
    return nil
  }
}
