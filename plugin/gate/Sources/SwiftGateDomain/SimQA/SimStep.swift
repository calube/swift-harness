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
    ""
  }

  /// `steps/<NNN>.png`.
  public static func screenshotPath(n: Int) -> String {
    ""
  }

  /// `steps/<NNN>.tree.json`.
  public static func treePath(n: Int) -> String {
    ""
  }

  /// Whether two `snapshot --json` outputs hold the same elements; `nil` when either doesn't
  /// parse.
  public static func settled(before: Data, after: Data) -> Bool? {
    nil
  }

  static let keys: Set<String> = [
    "n", "label", "assert", "screenshot", "tree", "settled", "elapsedMs",
  ]

  /// One JSON object with sorted keys and no trailing newline.
  public func line() -> Data {
    Data()
  }

  public static func decode(line: Data) throws(SimStepDecodingError) -> SimStep {
    throw .malformed(line: 1, "not decoded")
  }

  /// Every line of a step log in order. An empty log has no steps; a blank line, a line that
  /// doesn't decode, or a step numbered out of sequence fails, naming its 1-based line.
  public static func decodeLog(_ data: Data) throws(SimStepDecodingError) -> [SimStep] {
    []
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
    ""
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
    .blocked
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
    Data()
  }

  public var text: String {
    ""
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
    Data()
  }

  public var text: String {
    ""
  }
}
