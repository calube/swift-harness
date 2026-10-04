import Foundation

/// The identifiers a flow's `id="…"` selectors may name, or why they can't be checked.
public enum FlowIDs: Sendable, Equatable {
  /// The raw values of the typed accessibility-id enum in `source`, a repo-relative path.
  case declared(source: String, ids: Set<String>)
  /// No module is configured; the reason becomes the `qa.flow-ids-unknown` note.
  case unconfigured(reason: String)
}

/// The 5 batch steps file rules (simulator QA amendment §6.1), each `RED`, and the note that says
/// identifiers weren't checked.
public enum FlowRules {
  public static let unparsedRuleID = "qa.flow-unparsed"
  public static let refTargetRuleID = "qa.flow-ref-target"
  public static let noAssertRuleID = "qa.flow-no-assert"
  public static let schemaRuleID = "qa.flow-schema"
  public static let unknownIDRuleID = "qa.flow-unknown-id"
  public static let idsUnknownRuleID = "qa.flow-ids-unknown"

  /// Keys whose strings are app content, not selectors: what a step types, or the text a
  /// predicate compares with.
  static let contentKeys: Set<String> = ["text", "value"]

  /// Every finding 1 steps file earns. An unparsed file earns only `qa.flow-unparsed`.
  /// - Parameter file: the path findings name.
  public static func check(file: String, data: Data, schemas: ToolSchemas, ids: FlowIDs)
    -> [Finding]
  {
    let steps: [FlowStep]
    do {
      steps = try FlowSteps.parse(data)
    } catch {
      return [
        finding(
          unparsedRuleID, file,
          "not a batch steps file: \(error.reason); write a JSON list of "
            + "{\"command\": \"<name>\", \"input\": {...}} steps")
      ].compactMap { $0 }
    }
    var findings: [Finding?] = []
    for step in steps {
      let named = "step \(step.number) `\(step.command)`"
      for target in refTargets(in: .object(step.input), key: nil) {
        findings.append(
          finding(
            refTargetRuleID, file,
            "\(named) targets \(target); name the element with a selector such as "
              + "id=\"<identifier>\" or label=\"<text>\", which holds across runs and screens"))
      }
      let stepProblems = schemas.step.violations(of: .object(step.fields), at: "step")
      let inputProblems =
        stepProblems.isEmpty
        ? schemas.commands[step.command]?.violations(of: .object(step.input), at: "input")
          ?? ["`\(step.command)` has no schema in the pinned tool"] : []
      for problem in stepProblems + inputProblems {
        findings.append(
          finding(
            schemaRuleID, file,
            "\(named): \(problem); agent-device \(schemas.version) refuses this step"))
      }
      if case .declared(let source, let declared) = ids {
        for id in selectorIDs(in: .object(step.input), key: nil) where !declared.contains(id) {
          findings.append(
            finding(
              unknownIDRuleID, file,
              "\(named) selects id=\"\(id)\", which \(source) doesn't declare; use a raw value "
                + "of its `enum AccessibilityID`, or add the case the view sets"))
        }
      }
    }
    if !steps.contains(where: asserts) {
      findings.append(
        finding(
          noAssertRuleID, file,
          "no `wait` or `is` step checks a result, so the flow passes whatever the app shows; "
            + "add a `wait` for the expected text or selector, or an `is` predicate (`get` only "
            + "reads a value, and a `duration` or `stable` wait only pauses)"))
    }
    return findings.compactMap { $0 }
  }

  /// Checks each file, then adds 1 `qa.flow-ids-unknown` note when `ids` is unconfigured.
  public static func lint(
    files: [(path: String, data: Data)], schemas: ToolSchemas, ids: FlowIDs
  ) -> FlowLintReport {
    var findings = files.flatMap { check(file: $0.path, data: $0.data, schemas: schemas, ids: ids) }
    if case .unconfigured(let reason) = ids,
      let note = finding(
        idsUnknownRuleID, Config.fileName,
        "\(reason), so no `id=\"…\"` selector was checked against the app; set "
          + "`[qa] accessibility_ids` to the Swift file that declares `enum AccessibilityID: "
          + "String`", severity: .nit)
    {
      findings.append(note)
    }
    return FlowLintReport(files: files.map(\.path), findings: findings)
  }

  /// A `wait` that looks for something, or any `is`. A `duration` or `stable` wait only pauses.
  static func asserts(_ step: FlowStep) -> Bool {
    switch step.command {
    case "is":
      return true
    case "wait":
      if case .string(let kind)? = step.input["kind"] {
        return ["text", "ref", "selector", "absent"].contains(kind)
      }
      return ["text", "ref", "selector", "absent"].contains { step.input[$0] != nil }
    default:
      return false
    }
  }

  /// Each `@e` ref or coordinate in `value`, described for a message.
  static func refTargets(in value: FlowJSON, key: String?) -> [String] {
    switch value {
    case .object(let fields):
      if case .string(let kind)? = fields["kind"], kind == "ref" {
        return ["the ref \(fields["ref"]?.rendered ?? "(none)")"]
      }
      if case .string(let ref)? = fields["ref"] {
        return ["the ref \"\(ref)\""]
      }
      let x = fields["x"]?.numeric
      let y = fields["y"]?.numeric
      if case .string(let kind)? = fields["kind"], kind == "point" {
        return ["a point (\(x.map(FlowJSON.bound) ?? "?"), \(y.map(FlowJSON.bound) ?? "?"))"]
      }
      // A `delta` is how far a gesture moves, not where it lands.
      if let x, let y, key != "delta" {
        return ["the point (\(FlowJSON.bound(x)), \(FlowJSON.bound(y)))"]
      }
      return fields.keys.sorted().flatMap { name in
        fields[name].map { refTargets(in: $0, key: name) } ?? []
      }
    case .array(let values):
      return values.flatMap { refTargets(in: $0, key: key) }
    case .string(let text):
      guard !contentKeys.contains(key ?? ""), text.wholeMatch(of: /@e\d+(~s\d+)?/) != nil else {
        return []
      }
      return ["the ref \"\(text)\""]
    default:
      return []
    }
  }

  /// Each identifier an `id="…"` (or bare `id=…`) selector in `value` names.
  static func selectorIDs(in value: FlowJSON, key: String?) -> [String] {
    switch value {
    case .object(let fields):
      return fields.keys.sorted().flatMap { name in
        fields[name].map { selectorIDs(in: $0, key: name) } ?? []
      }
    case .array(let values):
      return values.flatMap { selectorIDs(in: $0, key: key) }
    case .string(let text):
      guard !contentKeys.contains(key ?? "") else { return [] }
      return text.matches(of: /(?:^|[\s,(])id=(?:"([^"]*)"|([^\s"),]+))/).compactMap { match in
        (match.output.1 ?? match.output.2).map(String.init)
      }
    default:
      return []
    }
  }

  /// `nil` only if the finding contract refused it, which a non-empty rule, file and message
  /// never are.
  static func finding(
    _ rule: String, _ file: String, _ message: String, severity: Severity = .major
  )
    -> Finding?
  {
    try? Finding(
      ruleID: rule, severity: severity, file: file, line: nil, message: message,
      failureScenario: nil)
  }
}

/// What `qa lint` reports: the files it read, their findings and the verdict they make.
public struct FlowLintReport: Sendable, Equatable {
  public let files: [String]
  public let findings: [Finding]
  /// Why the rules couldn't run; `nil` when they ran.
  public let blockedReason: String?

  public init(files: [String], findings: [Finding]) {
    self.files = files
    self.findings = findings
    self.blockedReason = nil
  }

  private init(files: [String], findings: [Finding], blockedReason: String?) {
    self.files = files
    self.findings = findings
    self.blockedReason = blockedReason
  }

  /// `BLOCKED` when the rules couldn't run, `RED` when any finding gates, else `GREEN`.
  public var verdict: Verdict {
    if blockedReason != nil { return .blocked }
    return findings.contains { $0.severity.failsGate } ? .red : .green
  }

  public var message: String {
    if let blockedReason { return blockedReason }
    let gating = findings.filter { $0.severity.failsGate }.count
    let count =
      switch findings.count {
      case 0: "no findings"
      case 1: "1 finding"
      default: "\(findings.count) findings"
      }
    return "\(files.count) \(files.count == 1 ? "file" : "files"): \(count)"
      + (gating > 0 && gating < findings.count ? ", \(gating) gating" : "")
  }

  /// A lint the environment stopped before any rule ran: the schemas or the id module didn't load.
  public static func blocked(_ message: String, files: [String]) -> FlowLintReport {
    FlowLintReport(files: files, findings: [], blockedReason: message)
  }
}

extension FlowLintReport: Codable {
  private enum CodingKeys: String, CodingKey {
    case files, verdict, findings, message
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let verdict = try c.decode(Verdict.self, forKey: .verdict)
    self.init(
      files: try c.decode([String].self, forKey: .files),
      findings: try c.decode([Finding].self, forKey: .findings),
      blockedReason: verdict == .blocked ? try c.decode(String.self, forKey: .message) : nil)
  }

  /// `{files, verdict, findings, message}`, every key always present.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(files, forKey: .files)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(findings, forKey: .findings)
    try c.encode(message, forKey: .message)
  }
}
