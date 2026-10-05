import Foundation

/// The identifiers a flow's `id="…"` selectors may name, or why they can't be checked.
public enum FlowIDs: Sendable, Equatable {
  /// The raw values of the typed accessibility-id enum in `source`, a repo-relative path.
  case declared(source: String, ids: Set<String>)
  /// No module is configured; the reason becomes the `qa.flow-ids-unknown` note.
  case unconfigured(reason: String)
  /// The profile has nowhere to declare an id module, as a brownfield clone's config: ids go
  /// unchecked with no note, since nothing the repository could hold would clear it.
  case undeclarable
}

/// The batch steps file rules (simulator QA amendment §6.1), each `RED`, and the note that says
/// identifiers weren't checked.
public enum FlowRules {
  public static let unparsedRuleID = "qa.flow-unparsed"
  public static let refTargetRuleID = "qa.flow-ref-target"
  public static let noAssertRuleID = "qa.flow-no-assert"
  public static let schemaRuleID = "qa.flow-schema"
  public static let unknownIDRuleID = "qa.flow-unknown-id"
  public static let idsUnknownRuleID = "qa.flow-ids-unknown"
  public static let kindKeyRuleID = "qa.flow-kind-key"
  /// A warning that never gates: the flow sees a state appear, then go by itself, under a fake
  /// scenario that doesn't hold it, so the fake's latency decides whether the first wait sees it.
  public static let transientStateRuleID = "qa.flow-transient-state"
  /// The `-`- or `_`-separated word a scenario's name carries when its fake holds an in-flight
  /// state until the flow moves on, as in `save-held`.
  public static let heldScenarioWord = "held"

  /// The input key a `wait` of each `kind` reads its target from. The pinned tool drops `kind`
  /// before it runs the step and takes whichever 1 of these keys is present, so a target under
  /// another kind's key runs as that other kind. The pinned `wait` schema names every kind in its
  /// `kind` enum and every key as a property; the schema alone doesn't pair them.
  public static let waitTargetKeys: [String: String] = [
    "duration": "durationMs", "text": "text", "ref": "ref", "selector": "selector",
    "absent": "absent", "stable": "stable",
  ]

  /// The presets a `gesture` of `kind` `swipe` reads from `preset`, which the pinned tool
  /// requires; it refuses a swipe without one, whatever other keys the step holds.
  public static let swipePresets = ["left", "right", "left-edge", "right-edge"]

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
      if stepProblems.isEmpty, inputProblems.isEmpty {
        for problem in kindKeyProblems(step) {
          findings.append(finding(kindKeyRuleID, file, "\(named): \(problem)"))
        }
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
    for problem in transientStateProblems(steps) {
      findings.append(finding(transientStateRuleID, file, problem, severity: .minor))
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

  /// Why `step` would run as another step than its `kind` or `predicate` says, each naming the key
  /// to use; empty when its input keys match. A `wait` holds exactly 1 target key, the 1 its
  /// `kind` reads, an `is` holds a `value` exactly when its predicate is `text`, and a `swipe`
  /// gesture holds a `preset`.
  static func kindKeyProblems(_ step: FlowStep) -> [String] {
    switch step.command {
    case "wait": waitProblems(step.input)
    case "is": isProblems(step.input)
    case "gesture": gestureProblems(step.input)
    default: []
    }
  }

  /// The target keys `input` holds, in the order ``waitTargetKeys`` sorts them.
  static func waitTargets(in input: [String: FlowJSON]) -> [String] {
    Set(waitTargetKeys.values).filter { input[$0] != nil }.sorted()
  }

  /// `input` with its target under the key its `kind` reads, when it holds exactly 1 target key
  /// and a `kind` that reads another; `nil` otherwise.
  static func correctedWait(_ input: [String: FlowJSON]) -> [String: FlowJSON]? {
    guard case .string(let kind)? = input["kind"], let key = waitTargetKeys[kind] else {
      return nil
    }
    let targets = waitTargets(in: input)
    guard targets.count == 1, let found = targets.first, found != key else { return nil }
    var fixed = input
    fixed[key] = fixed.removeValue(forKey: found)
    return fixed
  }

  private static func waitProblems(_ input: [String: FlowJSON]) -> [String] {
    let targets = waitTargets(in: input)
    let listed = targets.map { "`\($0)`" }.joined(separator: ", ")
    var problems: [String] = []
    if case .string(let kind)? = input["kind"], let key = waitTargetKeys[kind] {
      if let fixed = correctedWait(input), let found = targets.first {
        let runsAs = waitTargetKeys.first { $0.value == found }?.key ?? found
        problems.append(
          "`kind` `\(kind)` reads its target from `\(key)`, but this step puts it under "
            + "`\(found)`; the pinned tool drops `kind` and runs whichever target key is present, "
            + "so this runs as a `\(runsAs)` wait. Write \(FlowJSON.object(fixed).jsonText)")
      } else if targets.isEmpty {
        problems.append("`kind` `\(kind)` reads its target from `\(key)`, which this step lacks")
      } else if targets != [key] {
        problems.append(
          "it holds the target keys \(listed); a `wait` takes exactly 1, and `kind` `\(kind)` "
            + "reads `\(key)`")
      }
    } else if targets.count != 1 {
      let every = Set(waitTargetKeys.values).sorted().map { "`\($0)`" }.joined(separator: ", ")
      problems.append(
        "a `wait` takes exactly 1 target key of \(every), and this step holds "
          + (targets.isEmpty ? "none" : listed))
    }
    if input["quietMs"] != nil, !targets.isEmpty, targets != ["stable"] {
      problems.append(
        "`quietMs` applies only to a `stable` wait, so the pinned tool drops it from this step")
    }
    return problems
  }

  private static func isProblems(_ input: [String: FlowJSON]) -> [String] {
    guard case .string(let predicate)? = input["predicate"] else { return [] }
    if predicate == "text", input["value"] == nil {
      return ["`predicate` `text` compares the element's text with `value`, which this step lacks"]
    }
    if predicate != "text", input["value"] != nil {
      return [
        "`value` goes only with `predicate` `text`; the pinned tool drops it from an "
          + "`is \(predicate)`, so the step never compares it. Use `predicate` `text`, or drop "
          + "`value`"
      ]
    }
    return []
  }

  /// Why a `swipe` gesture lacks the `preset` the pinned tool requires. A `direction` of `left`
  /// or `right`, the key a `fling` reads, names the preset to write instead.
  private static func gestureProblems(_ input: [String: FlowJSON]) -> [String] {
    guard case .string("swipe")? = input["kind"], input["preset"] == nil else { return [] }
    let presets = swipePresets.joined(separator: ", ")
    var problem =
      "`kind` `swipe` reads its direction from `preset`, 1 of \(presets), which this step "
      + "lacks; the pinned tool refuses the step at run time"
    if case .string(let direction)? = input["direction"], swipePresets.contains(direction) {
      var fixed = input
      fixed["preset"] = fixed.removeValue(forKey: "direction")
      problem += ". Write \(FlowJSON.object(fixed).jsonText)"
    }
    return [problem]
  }

  /// Commands that read the screen and leave the app as it is.
  static let observingCommands: Set<String> = ["wait", "is", "get", "snapshot", "screenshot"]

  /// Each check that sees a selector appear and a later check that sees the same selector go,
  /// with only ``observingCommands`` between them, under the latest `open`'s scenario when that
  /// scenario doesn't hold. Nothing the flow does ends the state, so the fake's latency does. A
  /// flow with no scenario has no fake to hold the state, so it earns none.
  static func transientStateProblems(_ steps: [FlowStep]) -> [String] {
    var scenario: String?
    var problems: [String] = []
    for (index, step) in steps.enumerated() {
      if step.command == "open" { scenario = launchScenario(step.input) }
      guard let scenario, !holds(scenario), let shown = presentTarget(step) else { continue }
      for later in steps[(index + 1)...] {
        guard observingCommands.contains(later.command) else { break }
        guard absentTarget(later) == shown else { continue }
        problems.append(
          "step \(step.number) `\(step.command)` sees \(shown) appear and step \(later.number) "
            + "`\(later.command)` sees it go, with no step between that drives the app, under "
            + "the scenario `\(scenario)`, which holds nothing: the fake ends that state on its "
            + "own, so its latency, not the app, decides whether step \(step.number) sees it. Run "
            + "the flow under a scenario that holds the state until the flow moves on, named "
            + "with the word `\(heldScenarioWord)` (such as `\(scenario)-\(heldScenarioWord)`), "
            + "or return that scenario as a missing contract name")
        break
      }
    }
    return problems
  }

  /// The scenario an `open` step launches the app in; `nil` for live dependencies.
  static func launchScenario(_ input: [String: FlowJSON]) -> String? {
    guard case .array(let arguments)? = input["launchArgs"] else { return nil }
    let strings = arguments.map { argument -> String? in
      if case .string(let text) = argument { return text }
      return nil
    }
    guard let flag = strings.firstIndex(of: SimSession.scenarioArgument),
      flag + 1 < strings.count
    else { return nil }
    return strings[flag + 1]
  }

  /// Whether `scenario`'s name carries ``heldScenarioWord`` as 1 of its `-`- or `_`-separated
  /// words.
  static func holds(_ scenario: String) -> Bool {
    scenario.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" })
      .contains { $0 == heldScenarioWord }
  }

  /// The selector a step sees present: a selector `wait` whose keys agree with its `kind`, or an
  /// `is exists` or `is visible`. A `wait` that ``kindKeyProblems`` refuses counts as neither.
  static func presentTarget(_ step: FlowStep) -> String? {
    switch step.command {
    case "wait":
      guard kindKeyProblems(step).isEmpty, case .string(let target)? = step.input["selector"]
      else { return nil }
      return target.trimmingCharacters(in: .whitespaces)
    case "is":
      guard case .string(let predicate)? = step.input["predicate"],
        ["exists", "visible"].contains(predicate),
        case .string(let target)? = step.input["selector"]
      else { return nil }
      return target.trimmingCharacters(in: .whitespaces)
    default:
      return nil
    }
  }

  /// The selector a step sees gone: an absent `wait` whose keys agree with its `kind`, or an
  /// `is absent` or `is hidden`.
  static func absentTarget(_ step: FlowStep) -> String? {
    switch step.command {
    case "wait":
      guard kindKeyProblems(step).isEmpty, case .string(let target)? = step.input["absent"]
      else { return nil }
      return target.trimmingCharacters(in: .whitespaces)
    case "is":
      guard case .string(let predicate)? = step.input["predicate"],
        ["absent", "hidden"].contains(predicate),
        case .string(let target)? = step.input["selector"]
      else { return nil }
      return target.trimmingCharacters(in: .whitespaces)
    default:
      return nil
    }
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

extension FlowJSON {
  /// Compact JSON with sorted keys and escaped strings, which a flow file can hold as written.
  var jsonText: String {
    switch self {
    case .string(let value):
      var escaped = "\""
      for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": escaped += "\\\""
        case "\\": escaped += "\\\\"
        case "\n": escaped += "\\n"
        case "\t": escaped += "\\t"
        case "\r": escaped += "\\r"
        default:
          if scalar.value < 0x20 {
            let hex = String(scalar.value, radix: 16)
            escaped += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
          } else {
            escaped.unicodeScalars.append(scalar)
          }
        }
      }
      return escaped + "\""
    case .array(let values):
      return "[" + values.map(\.jsonText).joined(separator: ",") + "]"
    case .object(let fields):
      return "{"
        + fields.keys.sorted().map {
          "\(FlowJSON.string($0).jsonText):\(fields[$0]?.jsonText ?? "null")"
        }.joined(separator: ",") + "}"
    default:
      return rendered
    }
  }
}
