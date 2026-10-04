import Foundation

/// One line of `sim/steps.ndjson`: what `sim snap` captured at one point of a QA run.
///
/// Encoded as one JSON object with exactly the keys `n`, `label`, `screenshot`, `tree`,
/// `elapsedMs` and, when set, `assert` and `settled`. Any other key, a missing key, or an empty
/// string fails decoding: `sim verify` judges the run from these lines, so a line it can't fully
/// read must stop it rather than pass.
public struct SimStep: Sendable, Equatable {
  /// The step log, inside the run's `sim/` folder.
  public static let logFileName = "steps.ndjson"
  /// Where each step's screenshot and tree go, inside the run's `sim/` folder.
  public static let directoryName = "steps"

  /// 1-based, in capture order.
  public var n: Int
  public var label: String
  /// The text the step expects its tree to hold; `nil` when the step asserts nothing.
  public var assert: String?
  /// Relative to the run's `sim/` folder.
  public var screenshot: String
  /// Relative to the run's `sim/` folder; the `snapshot --json` output, unmodified.
  public var tree: String
  /// Whether a second snapshot taken after the screenshot held the same elements as the kept
  /// tree, so the screenshot shows the screen the tree records. `nil` when either snapshot
  /// didn't parse, which `sim verify` reports on the tree itself.
  public var settled: Bool?
  /// How long the step's captures took.
  public var elapsedMs: Int

  public init(
    n: Int, label: String, assert: String?, screenshot: String, tree: String, settled: Bool?,
    elapsedMs: Int
  ) {
    self.n = n
    self.label = label
    self.assert = assert
    self.screenshot = screenshot
    self.tree = tree
    self.settled = settled
    self.elapsedMs = elapsedMs
  }

  /// `001` for step 1: at least 3 digits, so names sort in step order up to 999.
  public static func stem(_ n: Int) -> String {
    let digits = String(n)
    return String(repeating: "0", count: max(0, 3 - digits.count)) + digits
  }

  /// `steps/<NNN>.png`.
  public static func screenshotPath(n: Int) -> String {
    "\(directoryName)/\(stem(n)).png"
  }

  /// `steps/<NNN>.tree.json`.
  public static func treePath(n: Int) -> String {
    "\(directoryName)/\(stem(n)).tree.json"
  }

  /// Whether two `snapshot --json` outputs hold the same elements; `nil` when either doesn't
  /// parse.
  public static func settled(before: Data, after: Data) -> Bool? {
    guard let first = try? SimTree.parse(snapshotJSON: before),
      let second = try? SimTree.parse(snapshotJSON: after)
    else { return nil }
    return first == second
  }

  static let keys: Set<String> = [
    "n", "label", "assert", "screenshot", "tree", "settled", "elapsedMs",
  ]

  /// One JSON object with sorted keys and no trailing newline.
  public func line() -> Data {
    var object: [String: Any] = [
      "n": n, "label": label, "screenshot": screenshot, "tree": tree, "elapsedMs": elapsedMs,
    ]
    if let assert { object["assert"] = assert }
    if let settled { object["settled"] = settled }
    // Strings, integers and a boolean always encode.
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
  }

  public static func decode(line: Data) throws(SimStepDecodingError) -> SimStep {
    try decode(line: line, number: 1)
  }

  static func decode(line: Data, number: Int) throws(SimStepDecodingError) -> SimStep {
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: line)
    } catch {
      throw .malformed(line: number, "not JSON")
    }
    guard let object = parsed as? [String: Any] else {
      throw .malformed(line: number, "not a JSON object")
    }
    if let unknown = object.keys.sorted().first(where: { !keys.contains($0) }) {
      throw .unknownKey(line: number, unknown)
    }
    func text(_ key: String) throws(SimStepDecodingError) -> String? {
      guard let value = object[key] else { return nil }
      guard let string = value as? String else {
        throw .malformed(line: number, "\"\(key)\" is not a string")
      }
      guard !string.isEmpty else { throw .invalidValue(line: number, key: key, value: string) }
      return string
    }
    func required(_ key: String) throws(SimStepDecodingError) -> String {
      guard let value = try text(key) else { throw .missingKey(line: number, key) }
      return value
    }
    func integer(_ key: String, minimum: Int) throws(SimStepDecodingError) -> Int {
      guard let value = object[key] else { throw .missingKey(line: number, key) }
      guard let numeric = value as? NSNumber, CFGetTypeID(numeric) != CFBooleanGetTypeID(),
        let integer = Int(exactly: numeric.doubleValue)
      else { throw .malformed(line: number, "\"\(key)\" is not an integer") }
      guard integer >= minimum else {
        throw .invalidValue(line: number, key: key, value: String(integer))
      }
      return integer
    }
    var settled: Bool?
    if let value = object["settled"] {
      guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
        throw .malformed(line: number, "\"settled\" is not a boolean")
      }
      settled = flag.boolValue
    }
    return SimStep(
      n: try integer("n", minimum: 1), label: try required("label"), assert: try text("assert"),
      screenshot: try required("screenshot"), tree: try required("tree"), settled: settled,
      elapsedMs: try integer("elapsedMs", minimum: 0))
  }

  /// Every line of a step log in order. An empty log has no steps; a blank line, a line that
  /// doesn't decode, or a step numbered out of sequence fails, naming its 1-based line.
  public static func decodeLog(_ data: Data) throws(SimStepDecodingError) -> [SimStep] {
    var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    var steps: [SimStep] = []
    for (offset, line) in lines.enumerated() {
      let number = offset + 1
      guard !line.isEmpty else { throw .malformed(line: number, "blank line") }
      let step = try decode(line: Data(line), number: number)
      guard step.n == number else {
        throw .outOfSequence(line: number, expected: number, found: step.n)
      }
      steps.append(step)
    }
    return steps
  }
}

public enum SimStepDecodingError: Error, Sendable, Equatable {
  /// Not a JSON object, or a key holds the wrong type.
  case malformed(line: Int, String)
  case missingKey(line: Int, String)
  case unknownKey(line: Int, String)
  /// A key holds an empty string or a number out of range.
  case invalidValue(line: Int, key: String, value: String)
  /// The line's `n` isn't one more than the line before it.
  case outOfSequence(line: Int, expected: Int, found: Int)

  public var message: String {
    switch self {
    case .malformed(let line, let detail): "step line \(line) is not a step: \(detail)"
    case .missingKey(let line, let key): "step line \(line) has no \"\(key)\""
    case .unknownKey(let line, let key): "step line \(line) has an unknown key \"\(key)\""
    case .invalidValue(let line, let key, let value):
      "step line \(line) \"\(key)\" is invalid: \"\(value)\""
    case .outOfSequence(let line, let expected, let found):
      "step line \(line) is step \(found), not \(expected)"
    }
  }
}

/// The rule ids `sim snap` reports. A failure writes no step.
public enum SimSnapRule: String, Sendable, Equatable, CaseIterable {
  /// The run's lease belongs to another worktree.
  case notOwner = "sim.not-owner"
  /// No live run, holder, session or device is there to capture from.
  case sessionGone = "sim.session-gone"
  /// `agent-device` failed for a reason other than a gone device.
  case driverFailed = "sim.driver-failed"
  /// The run's files couldn't be read or written.
  case environment = "swiftgate.environment"

  public var verdict: Verdict {
    switch self {
    case .notOwner, .sessionGone: .red
    case .driverFailed, .environment: .blocked
    }
  }
}

/// Why `sim snap` stopped.
public struct SimSnapFailure: Error, Sendable, Equatable {
  public var rule: SimSnapRule
  public var message: String
  /// The run, once `sim snap` has resolved one.
  public var runID: String?

  public init(rule: SimSnapRule, message: String, runID: String? = nil) {
    self.rule = rule
    self.message = message
    self.runID = runID
  }

  public var verdict: Verdict { rule.verdict }

  /// `{schemaVersion, verdict, ruleID, message, runID}`, `runID` `null` before a run is resolved.
  public func json() -> Data {
    let object: [String: Any] = [
      "schemaVersion": SimSession.schemaVersion, "verdict": verdict.rawValue,
      "ruleID": rule.rawValue, "message": message, "runID": runID ?? NSNull(),
    ]
    // Strings, an integer and null always encode.
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
  }

  public var text: String {
    "sim snap \(verdict.rawValue) \(rule.rawValue): \(message)"
  }
}

/// What a successful `sim snap` prints: the run, the step line it appended, and where the step's
/// files are.
public struct SimSnapped: Sendable, Equatable {
  public var runID: String
  public var step: SimStep
  /// The run's `sim/` folder, absolute.
  public var simDirectory: String

  public init(runID: String, step: SimStep, simDirectory: String) {
    self.runID = runID
    self.step = step
    self.simDirectory = simDirectory
  }

  /// `{schemaVersion, verdict, runID, n, label, screenshot, tree, settled}`, with `screenshot`
  /// and `tree` absolute and `settled` `null` when unknown.
  public func json() -> Data {
    let object: [String: Any] = [
      "schemaVersion": SimSession.schemaVersion, "verdict": Verdict.green.rawValue,
      "runID": runID, "n": step.n, "label": step.label, "screenshot": path(step.screenshot),
      "tree": path(step.tree), "settled": step.settled ?? NSNull(),
    ]
    // Strings, integers, a boolean and null always encode.
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
  }

  public var text: String {
    let settle =
      switch step.settled {
      case true?: "settled"
      case false?: "not settled: the screen changed during the capture"
      case nil: "settle unknown: a snapshot didn't parse"
      }
    return "sim snap: run \(runID) step \(SimStep.stem(step.n)) \"\(step.label)\", \(settle); "
      + "screenshot \(path(step.screenshot)), tree \(path(step.tree))"
  }

  private func path(_ relative: String) -> String {
    (simDirectory.hasSuffix("/") ? simDirectory : simDirectory + "/") + relative
  }
}
