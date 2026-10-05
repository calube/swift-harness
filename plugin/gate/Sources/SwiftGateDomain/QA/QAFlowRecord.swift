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
  /// When the step started: from the video's first frame when the record has a `video`, else
  /// from the batch's start.
  public let offsetMs: Int
  public let ok: Bool
  /// How long the steps `qa run` added after this one took before the flow's next step: the
  /// evidence captures after a check, and a final pass's `record start` after an opening `open`.
  /// Each step after it starts that much later. `nil` when `qa run` added none.
  public let captureMs: Int?

  public init(n: Int, label: String, offsetMs: Int, ok: Bool, captureMs: Int? = nil) {
    self.n = n
    self.label = label
    self.offsetMs = offsetMs
    self.ok = ok
    self.captureMs = captureMs
  }
}

/// How long a flow's opening `open` took to bring the app up, as `agent-device` measured it.
public struct QAFlowLaunch: Sendable, Equatable, Codable {
  /// From the open's dispatch until `agent-device` first saw the app settle.
  public let launchMs: Int
  /// The part of `launchMs` spent waiting for the app to settle; `nil` when none was reported.
  public let settleMs: Int?

  public init(launchMs: Int, settleMs: Int?) {
    self.launchMs = launchMs
    self.settleMs = settleMs
  }
}

/// Where the time before a batch's failing step went, on the batch's clock.
public struct QAFlowDelay: Sendable, Equatable {
  /// The flow file's step that failed.
  public let step: Int
  /// Every driven step before it.
  public let beforeMs: Int
  /// The flow's own `open` steps among them.
  public let openMs: Int
  /// The steps `qa run` added among them: evidence captures and a `record start`.
  public let captureMs: Int
  /// The flow's opening `open`'s launch, when it reported one.
  public let launch: QAFlowLaunch?
  /// What a tree `qa run` captured before the failing step showed of the state it then missed.
  public let lost: QAFlowCaptureLoss?

  public init(
    step: Int, beforeMs: Int, openMs: Int, captureMs: Int, launch: QAFlowLaunch?,
    lost: QAFlowCaptureLoss? = nil
  ) {
    self.step = step
    self.beforeMs = beforeMs
    self.openMs = openMs
    self.captureMs = captureMs
    self.launch = launch
    self.lost = lost
  }

  /// The clause a red row's message ends with, such as `step 5 began 22.7 s into the batch: …`.
  public var sentence: String {
    var parts: [String] = []
    if openMs > 0 {
      var open = "\(Self.seconds(openMs)) opening the app"
      if let launch {
        open += " (\(Self.seconds(launch.launchMs)) to launch"
        if let settle = launch.settleMs { open += ", \(Self.seconds(settle)) of it settling" }
        open += ")"
      }
      parts.append(open)
    }
    if captureMs > 0 { parts.append("\(Self.seconds(captureMs)) in captures qa run added") }
    let rest = beforeMs - openMs - captureMs
    if rest > 0 { parts.append("\(Self.seconds(rest)) in the flow's other steps") }
    return "step \(step) began \(Self.seconds(beforeMs)) into the batch: "
      + parts.joined(separator: ", ")
  }

  private static func seconds(_ ms: Int) -> String {
    let tenths = (ms + 50) / 100
    return "\(tenths / 10).\(tenths % 10) s"
  }
}

/// A failing step's target shown in the tree `qa run` captured after the step before it: the
/// state was on screen and went while `qa run`'s own captures held the flow, so the red is a
/// capture delay, not evidence against the app, the flow or the contract.
public struct QAFlowCaptureLoss: Sendable, Equatable {
  /// The flow file's step the capture followed.
  public let after: Int
  /// The failing step's checked selector, which an element of that tree matched.
  public let selector: String
  /// From the start of that capture to the start of the failing step.
  public let beforeMs: Int
  /// The captures `qa run` added between the step before and the failing step.
  public let captureMs: Int

  public init(after: Int, selector: String, beforeMs: Int, captureMs: Int) {
    self.after = after
    self.selector = selector
    self.beforeMs = beforeMs
    self.captureMs = captureMs
  }
}

/// 1 flow, whichever source ran it: what the run viewer draws a flow row's steps from.
public struct QAFlowRecord: Sendable, Equatable, Codable {
  /// The file `qa run` writes beside each batch flow's evidence.
  public static let fileName = "flow.json"

  public let source: QAFlowSource
  /// The steps that ran, in order: every step up to and including the one that failed.
  public let steps: [QAFlowStep]
  /// Run-relative path of the flow's video; `nil` until a final pass or an `--after` run records
  /// one.
  public let video: String?
  /// Run-relative path of the video's contact sheet; `nil` until a recording makes one.
  public let sheet: String?
  /// Why a final pass left no video: the video reads `unverified`. `nil` outside a final pass.
  public let videoUnverified: QARecordingGapReason?
  /// Why a final pass that made a video left no contact sheet.
  public let sheetUnverified: QARecordingGapReason?
  /// How long the flow's opening `open` took to bring the app up; `nil` for a flow that opens
  /// nothing first, an `open` that reported no launch, or a kept XCUITest flow.
  public let launch: QAFlowLaunch?
  /// The `[[flows]]` entry a kept XCUITest flow maps to; `nil` for a batch flow.
  public let flow: String?
  /// The kept flow's test, `<Class>/<method>()` as the result bundle names it; `nil` for a batch
  /// flow.
  public let test: String?

  public init(
    source: QAFlowSource, steps: [QAFlowStep], video: String? = nil, sheet: String? = nil,
    videoUnverified: QARecordingGapReason? = nil,
    sheetUnverified: QARecordingGapReason? = nil, launch: QAFlowLaunch? = nil,
    flow: String? = nil, test: String? = nil
  ) {
    self.launch = launch
    self.flow = flow
    self.test = test
    self.source = source
    self.steps = steps
    self.video = video
    self.sheet = sheet
    self.videoUnverified = videoUnverified
    self.sheetUnverified = sheetUnverified
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
  /// An `open`'s launch, from its `data.startup` and `data.timing`; `nil` for any other step.
  public let launch: QAFlowLaunch?

  public init(index: Int, command: String, ok: Bool, durationMs: Int, launch: QAFlowLaunch? = nil) {
    self.index = index
    self.command = command
    self.ok = ok
    self.durationMs = durationMs
    self.launch = launch
  }
}

/// A prepared flow as `qa run` drives it: the flow file's steps, each kept as written, with a
/// `snapshot`, a `screenshot` and a second `snapshot` after every assertion, so the run's `sim/`
/// folder keeps a tree and a PNG per asserted step as `sim snap` would. A batch that records a
/// video takes only the `snapshot` inline: each step's PNG is the video's frame from when that
/// snapshot began, so the flow's next step waits for 1 capture, not 3.
public struct BatchFlowPlan: Sendable, Equatable {
  /// The evidence captured after 1 assertion.
  public struct Evidence: Sendable, Equatable {
    /// The flow file's step this follows.
    public let after: Int
    /// The `sim/steps.ndjson` label.
    public let label: String
    /// The text an `is text` step expects, which `sim verify` looks for in the tree.
    public let assert: String?
    /// The selector of the element the step checks is shown, which `sim verify` holds in view.
    public let target: String?
    /// Driven-file indexes, 1-based: the kept tree, the screenshot, and the settle check. With
    /// no `screenshot` the PNG is the video's frame, and with no `settle` nothing checks the
    /// screen held still.
    public let snapshot: Int
    public let screenshot: Int?
    public let settle: Int?
    /// Where the `screenshot` step, or the video's frame, writes its PNG.
    public let screenshotPath: String

    public init(
      after: Int, label: String, assert: String?, snapshot: Int, screenshot: Int?, settle: Int?,
      screenshotPath: String, target: String? = nil
    ) {
      self.after = after
      self.label = label
      self.assert = assert
      self.target = target
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
    /// The `record start` a final pass adds failed, so no step after the flow's opening `open` ran.
    case recordStart
  }

  public let steps: [FlowStep]
  public let evidence: [Evidence]
  /// Every driven step object, in order.
  public let driven: [FlowJSON]
  /// For each driven index, 1-based at position `index - 1`: the flow file's step number, or
  /// `nil` for a capture `qa run` added.
  public let origin: [Int?]
  /// Where the batch's `record start` writes the video; `nil` when the batch records nothing.
  public let recordTo: String?
  /// The driven index of the `record start`, 1-based; `nil` when the batch records nothing.
  public let recordIndex: Int?

  public init(
    steps: [FlowStep], evidence: [Evidence], driven: [FlowJSON], origin: [Int?],
    recordTo: String? = nil, recordIndex: Int? = nil
  ) {
    self.steps = steps
    self.evidence = evidence
    self.driven = driven
    self.origin = origin
    self.recordTo = recordTo
    self.recordIndex = recordIndex ?? (recordTo == nil ? nil : 1)
  }

  /// How many assertions `steps` holds, and so how many screenshots the plan needs.
  public static func assertionCount(_ steps: [FlowStep]) -> Int {
    steps.filter(FlowRules.asserts).count
  }

  /// - Parameters:
  ///   - screenshots: 1 path per assertion, in order; an assertion past the last path gets no
  ///     evidence.
  ///   - recordTo: set on a final pass: the batch holds a `record start` to this path, so the
  ///     video and the steps share the batch's clock. It comes first, or right after the flow's
  ///     first step when that is an `open`, so the video opens on the launch the flow makes and
  ///     not on the app as an earlier launch left it.
  public static func make(steps: [FlowStep], screenshots: [String], recordTo: String? = nil)
    -> BatchFlowPlan
  {
    var driven: [FlowJSON] = []
    var origin: [Int?] = []
    var evidence: [Evidence] = []
    var recordIndex: Int?
    let afterOpen = steps.first?.command == "open" ? steps.first?.number : nil
    func startRecording() {
      guard let recordTo else { return }
      driven.append(
        .object([
          "command": .string("record"),
          "input": .object(["action": .string("start"), "path": .string(recordTo)]),
        ]))
      origin.append(nil)
      recordIndex = driven.count
    }
    if afterOpen == nil { startRecording() }
    let snapshot = FlowJSON.object(["command": .string("snapshot"), "input": .object([:])])
    for step in steps {
      driven.append(.object(step.fields))
      origin.append(step.number)
      if step.number == afterOpen { startRecording() }
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
          screenshotPath: path, target: checkedTarget(step)))
    }
    return BatchFlowPlan(
      steps: steps, evidence: evidence, driven: driven, origin: origin, recordTo: recordTo,
      recordIndex: recordIndex)
  }

  /// When the video's first frame came, on the batch's clock: the end of the `record start`.
  /// `nil` when the batch records nothing or the `record start` has no passing result.
  public func videoStartMs(results: [BatchStepOutcome]) -> Int? {
    guard let recordIndex,
      let record = results.first(where: { $0.index == recordIndex }), record.ok
    else { return nil }
    let byIndex = Dictionary(
      results.map { ($0.index, $0.durationMs) }, uniquingKeysWith: { first, _ in first })
    return (1...recordIndex).reduce(0) { $0 + (byIndex[$1] ?? 0) }
  }

  /// When each evidence whose PNG is the video's frame began its snapshot, on the video's clock,
  /// by the flow file's step it follows. Empty when the batch recorded nothing.
  public func frameTimes(results: [BatchStepOutcome]) -> [Int: Int] {
    [:]
  }

  /// The failing step's target as the tree `qa run` captured just before it showed it; `nil`
  /// when no such capture ran, the step checks no element, or that tree didn't show it.
  /// `trees` holds each capture's parsed tree by driven index.
  public func captureLoss(
    results: [BatchStepOutcome], failedAt: Int?, trees: [Int: SimTree]
  ) -> QAFlowCaptureLoss? {
    nil
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
    if index == recordIndex { return .recordStart }
    if let n = origin(of: index) { return .step(n: n, command: command) }
    let after = origin.prefix(max(0, index - 1)).compactMap { $0 }.last ?? 0
    return .evidence(after: after, command: command)
  }

  /// The flow's record from the steps that ran. `failedAt` is the driven index of the step that
  /// failed, which isn't in `results`; a capture that failed marks the step it follows not ok.
  /// With no result and no failing step, no step is known to have run, so the record has none.
  /// Each step carries the time the captures after it took, and the record the launch its
  /// opening `open` reported.
  public func record(results: [BatchStepOutcome], failedAt: Int?) -> QAFlowRecord {
    var steps: [QAFlowStep] = []
    var captures: [Int] = []
    var offset = 0
    let byIndex = Dictionary(
      results.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
    let last = failedAt ?? (results.map(\.index).max() ?? 0)
    guard last > 0 else { return QAFlowRecord(source: .batch, steps: []) }
    for index in 1...last where index <= origin.count {
      let outcome = byIndex[index]
      if let n = origin[index - 1], let step = self.steps.first(where: { $0.number == n }) {
        let ok = index != failedAt && (outcome?.ok ?? false)
        steps.append(QAFlowStep(n: n, label: Self.label(step), offsetMs: offset, ok: ok))
        captures.append(0)
      } else if index == failedAt, let previous = steps.popLast() {
        steps.append(
          QAFlowStep(n: previous.n, label: previous.label, offsetMs: previous.offsetMs, ok: false))
      } else if !captures.isEmpty, let outcome {
        captures[captures.count - 1] += outcome.durationMs
      }
      offset += outcome?.durationMs ?? 0
    }
    let timed = zip(steps, captures).map { step, capture in
      QAFlowStep(
        n: step.n, label: step.label, offsetMs: step.offsetMs, ok: step.ok,
        captureMs: capture > 0 ? capture : nil)
    }
    return QAFlowRecord(source: .batch, steps: timed, launch: launch(results: results))
  }

  /// The launch the flow's opening `open` reported; `nil` when the flow opens nothing first.
  private func launch(results: [BatchStepOutcome]) -> QAFlowLaunch? {
    guard steps.first?.command == "open", let first = steps.first?.number,
      let index = origin.firstIndex(of: first)
    else { return nil }
    return results.first(where: { $0.index == index + 1 })?.launch
  }

  /// Where the time before the failing step went; `nil` when no flow step failed or nothing ran
  /// before it.
  public func delay(results: [BatchStepOutcome], failedAt: Int?) -> QAFlowDelay? {
    guard let failedAt, let n = origin(of: failedAt), failedAt > 1 else { return nil }
    let byIndex = Dictionary(
      results.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
    var before = 0
    var opens = 0
    var captures = 0
    for index in 1..<failedAt {
      let ms = byIndex[index]?.durationMs ?? 0
      before += ms
      if let step = origin(of: index), self.steps.first(where: { $0.number == step })?.command == "open" {
        opens += ms
      } else if origin(of: index) == nil {
        captures += ms
      }
    }
    guard before > 0 else { return nil }
    return QAFlowDelay(
      step: n, beforeMs: before, openMs: opens, captureMs: captures,
      launch: launch(results: results))
  }

  /// The selector of the element `step` checks is shown: a `wait` for a selector, or an `is`
  /// whose predicate holds only for an element that is there. `nil` for any other step.
  public static func checkedTarget(_ step: FlowStep) -> String? {
    guard case .string(let selector)? = step.input["selector"] else { return nil }
    switch step.command {
    case "wait":
      if case .string(let kind)? = step.input["kind"], kind != "selector" { return nil }
      return selector
    case "is":
      guard case .string(let predicate)? = step.input["predicate"],
        ["exists", "visible", "text"].contains(predicate)
      else { return nil }
      return selector
    default:
      return nil
    }
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
