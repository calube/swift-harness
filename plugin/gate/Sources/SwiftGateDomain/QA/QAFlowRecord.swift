import Foundation

/// Where a `qa.flow` record's steps came from. Closed: the run viewer reads it.
public enum QAFlowSource: String, Sendable, Equatable, Codable, CaseIterable {
  /// A prepared or final-pass flow `qa run` drove as 1 `agent-device batch`.
  case batch
  /// A kept flow T3 ran as an XCUITest.
  case xcuitest
}

/// 1 step of a flow as its record lists it.
public struct QAFlowStep: Sendable, Equatable, Codable {
  /// 1-based, in the flow file's numbering.
  public let n: Int
  public let label: String
  /// When the step started, from the start of the flow.
  public let offsetMs: Int
  public let ok: Bool

  public init(n: Int, label: String, offsetMs: Int, ok: Bool) {
    self.n = n
    self.label = label
    self.offsetMs = offsetMs
    self.ok = ok
  }
}

/// 1 flow, whichever source ran it: what the run viewer draws a flow row's steps from.
public struct QAFlowRecord: Sendable, Equatable, Codable {
  /// The file `qa run` writes beside each batch flow's evidence.
  public static let fileName = "flow.json"

  public let source: QAFlowSource
  /// The steps that ran, in order: every step up to and including the one that failed.
  public let steps: [QAFlowStep]
  /// Run-relative path of the flow's video; `nil` until a final pass records one.
  public let video: String?
  /// Run-relative path of the video's contact sheet; `nil` until a final pass makes one.
  public let sheet: String?

  public init(source: QAFlowSource, steps: [QAFlowStep], video: String? = nil, sheet: String? = nil)
  {
    self.source = source
    self.steps = steps
    self.video = video
    self.sheet = sheet
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(self)
    data.append(UInt8(ascii: "\n"))
    return data
  }
}

/// 1 step of a batch's `--json` output, as `results` (or, for a failed batch,
/// `error.details.partialResults`) lists it.
public struct BatchStepOutcome: Sendable, Equatable {
  /// 1-based, in the driven steps file's numbering.
  public let index: Int
  public let command: String
  public let ok: Bool
  public let durationMs: Int

  public init(index: Int, command: String, ok: Bool, durationMs: Int) {
    self.index = index
    self.command = command
    self.ok = ok
    self.durationMs = durationMs
  }
}

/// A prepared flow as `qa run` drives it: the flow file's steps, each kept as written, with a
/// `snapshot`, a `screenshot` and a second `snapshot` after every assertion, so the run's `sim/`
/// folder keeps a tree and a PNG per asserted step as `sim snap` would.
public struct BatchFlowPlan: Sendable, Equatable {
  /// The evidence captured after 1 assertion.
  public struct Evidence: Sendable, Equatable {
    /// The flow file's step this follows.
    public let after: Int
    /// The `sim/steps.ndjson` label.
    public let label: String
    /// The text an `is text` step expects, which `sim verify` looks for in the tree.
    public let assert: String?
    /// Driven-file indexes, 1-based: the kept tree, the screenshot, and the settle check.
    public let snapshot: Int
    public let screenshot: Int
    public let settle: Int
    /// Where the `screenshot` step writes its PNG.
    public let screenshotPath: String

    public init(
      after: Int, label: String, assert: String?, snapshot: Int, screenshot: Int, settle: Int,
      screenshotPath: String
    ) {
      self.after = after
      self.label = label
      self.assert = assert
      self.snapshot = snapshot
      self.screenshot = screenshot
      self.settle = settle
      self.screenshotPath = screenshotPath
    }
  }

  /// Where a batch stopped, in the flow file's terms.
  public enum Stop: Sendable, Equatable {
    /// A step of the flow file failed.
    case step(n: Int, command: String)
    /// A capture `qa run` added after step `after` failed.
    case evidence(after: Int, command: String)
  }

  public let steps: [FlowStep]
  public let evidence: [Evidence]
  /// Every driven step object, in order.
  public let driven: [FlowJSON]
  /// For each driven index, 1-based at position `index - 1`: the flow file's step number, or
  /// `nil` for a capture `qa run` added.
  public let origin: [Int?]

  public init(steps: [FlowStep], evidence: [Evidence], driven: [FlowJSON], origin: [Int?]) {
    self.steps = steps
    self.evidence = evidence
    self.driven = driven
    self.origin = origin
  }

  /// How many assertions `steps` holds, and so how many screenshots the plan needs.
  public static func assertionCount(_ steps: [FlowStep]) -> Int {
    steps.filter(FlowRules.asserts).count
  }

  /// - Parameter screenshots: 1 path per assertion, in order; an assertion past the last path
  ///   gets no evidence.
  public static func make(steps: [FlowStep], screenshots: [String]) -> BatchFlowPlan {
    var driven: [FlowJSON] = []
    var origin: [Int?] = []
    var evidence: [Evidence] = []
    let snapshot = FlowJSON.object(["command": .string("snapshot"), "input": .object([:])])
    for step in steps {
      driven.append(.object(step.fields))
      origin.append(step.number)
      guard FlowRules.asserts(step), evidence.count < screenshots.count else { continue }
      let path = screenshots[evidence.count]
      let first = driven.count + 1
      driven += [
        snapshot,
        .object(["command": .string("screenshot"), "input": .object(["path": .string(path)])]),
        snapshot,
      ]
      origin += [nil, nil, nil]
      evidence.append(
        Evidence(
          after: step.number, label: "after step \(step.number): \(label(step))",
          assert: expectedText(step), snapshot: first, screenshot: first + 1, settle: first + 2,
          screenshotPath: path))
    }
    return BatchFlowPlan(steps: steps, evidence: evidence, driven: driven, origin: origin)
  }

  /// The driven steps file: a JSON array `agent-device batch --steps-file` reads.
  public func drivenJSON() -> Data {
    // Built from parsed JSON values only, which always serialize.
    (try? JSONSerialization.data(
      withJSONObject: driven.map(\.foundationValue),
      options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
  }

  /// Where the batch stopped, from the failing driven step's index.
  public func stop(atDrivenIndex index: Int, command: String) -> Stop {
    if let n = origin(of: index) { return .step(n: n, command: command) }
    let after = origin.prefix(max(0, index - 1)).compactMap { $0 }.last ?? 0
    return .evidence(after: after, command: command)
  }

  /// The flow's record from the steps that ran. `failedAt` is the driven index of the step that
  /// failed, which isn't in `results`; a capture that failed marks the step it follows not ok.
  public func record(results: [BatchStepOutcome], failedAt: Int?) -> QAFlowRecord {
    var steps: [QAFlowStep] = []
    var offset = 0
    let byIndex = Dictionary(
      results.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
    let last = failedAt ?? (results.map(\.index).max() ?? 0)
    for index in 1...max(1, last) where index <= origin.count {
      let outcome = byIndex[index]
      if let n = origin[index - 1], let step = self.steps.first(where: { $0.number == n }) {
        let ok = index != failedAt && (outcome?.ok ?? false)
        steps.append(QAFlowStep(n: n, label: Self.label(step), offsetMs: offset, ok: ok))
      } else if index == failedAt, let previous = steps.popLast() {
        steps.append(
          QAFlowStep(n: previous.n, label: previous.label, offsetMs: previous.offsetMs, ok: false))
      }
      offset += outcome?.durationMs ?? 0
    }
    return QAFlowRecord(source: .batch, steps: steps)
  }

  /// A step's label: its command and what it acts on, such as `is text id="counter.value" "1"`.
  public static func label(_ step: FlowStep) -> String {
    var parts = [step.command]
    func string(_ value: FlowJSON?) -> String? {
      if case .string(let text)? = value { text } else { nil }
    }
    if let kind = string(step.input["kind"]) ?? string(step.input["predicate"]) {
      parts.append(kind)
    }
    var target: [String: FlowJSON] = [:]
    if case .object(let fields)? = step.input["target"] { target = fields }
    if let selector = string(step.input["selector"]) ?? string(target["selector"]) {
      parts.append(selector)
    }
    for key in ["text", "absent", "value"] {
      if let text = string(step.input[key]) { parts.append("\"\(text)\"") }
    }
    return parts.joined(separator: " ")
  }

  /// The flow file's step number at a 1-based driven index; `nil` for a capture.
  private func origin(of index: Int) -> Int? {
    guard index >= 1, index <= origin.count else { return nil }
    return origin[index - 1]
  }

  /// The text an `is text` step compares, which must then be in the step's tree. A `wait` for
  /// text may match part of a label, so it names no text the tree must hold whole.
  private static func expectedText(_ step: FlowStep) -> String? {
    guard step.command == "is", case .string("text")? = step.input["predicate"],
      case .string(let value)? = step.input["value"]
    else { return nil }
    return value
  }
}

extension FlowJSON {
  /// The value as `JSONSerialization` writes it.
  var foundationValue: Any {
    switch self {
    case .null: NSNull()
    case .bool(let value): value
    case .integer(let value): value
    case .number(let value): value
    case .string(let value): value
    case .array(let values): values.map(\.foundationValue)
    case .object(let fields): fields.mapValues(\.foundationValue)
    }
  }
}
