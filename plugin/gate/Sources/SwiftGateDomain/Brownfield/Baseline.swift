import Foundation

/// What a baseline record answers for: 1 area step, as configured, over 1 selection.
public struct BaselineStepKey: Sendable, Hashable {
  public let area: String
  public let step: AreaStep
  /// The command as configured, before `{files}`, `{tests}` and `{junit}` expand, so every
  /// worktree and the warm-up share 1 key whatever their paths.
  public let command: String
  /// What `{files}` or `{tests}` expanded to, sorted; empty for a command that runs whole.
  public let selection: [String]

  public init(area: String, step: AreaStep, command: String, selection: [String] = []) {
    self.area = area
    self.step = step
    self.command = command
    self.selection = selection
  }
}

/// How 1 step ended, reduced to what the baseline compares.
public enum BaselineStepResult: Sendable, Hashable {
  case passed
  /// The ids of the failing tests, `<classname>.<name>`; never empty.
  case failedTests(Set<String>)
  /// Failed with no test id to read: no JUnit, an unreadable report, a crash or a timeout.
  case failed

  public static func of(_ outcome: AreaCommandOutcome) -> BaselineStepResult {
    .passed
  }
}

/// 1 failure a gate saw: a test of a step, or the whole step when no test id was readable.
public struct BaselineFailure: Sendable, Hashable {
  public let key: BaselineStepKey
  /// `nil` for the whole step.
  public let test: String?

  public init(key: BaselineStepKey, test: String?) {
    self.key = key
    self.test = test
  }
}

/// 1 step's answer at a base tree.
public struct BaselineRecord: Sendable, Equatable {
  public let key: BaselineStepKey
  public let result: BaselineStepResult

  public init(key: BaselineStepKey, result: BaselineStepResult) {
    self.key = key
    self.result = result
  }
}

public struct BaselineFileError: Error, Sendable, Equatable {
  public let detail: String

  public init(detail: String) { self.detail = detail }
}

/// `baseline/<tree>.json`: every step answer recorded at 1 base tree.
public struct BaselineFile: Sendable, Equatable {
  public static let version = 1

  public let tree: String
  public private(set) var records: [BaselineRecord]

  public init(tree: String, records: [BaselineRecord] = []) {
    self.tree = tree
    self.records = records
  }

  /// Fails on any key, step or result it doesn't know, and on a file recorded for another tree.
  public static func decode(_ data: Data, tree: String) throws(BaselineFileError) -> BaselineFile {
    throw BaselineFileError(detail: "")
  }

  public func encoded() -> Data { Data() }

  /// A newer answer for a key replaces the older one.
  public mutating func merge(_ newer: [BaselineRecord]) {}

  public var results: [BaselineStepKey: BaselineStepResult] { [:] }
}

/// What the baseline made of a gate's failures.
public struct BaselineVerdict: Sendable, Equatable {
  /// Failing at both the head and the base tree: reported, never gating.
  public let absorbed: [BaselineFailure]
  /// Failing at the head only, or with no answer at the base: these gate.
  public let remaining: [BaselineFailure]

  public init(absorbed: [BaselineFailure] = [], remaining: [BaselineFailure] = []) {
    self.absorbed = absorbed
    self.remaining = remaining
  }

  /// `gate.run`'s `baselineCount`.
  public var baselineCount: Int { 0 }

  /// The `baseline.summary` nit listing what was absorbed; `nil` when nothing was.
  public func summary(file: String) -> Finding? { nil }
}

public enum Baseline {
  /// The failures a step's result holds.
  public static func failures(of key: BaselineStepKey, _ result: BaselineStepResult)
    -> [BaselineFailure]
  {
    []
  }

  /// A head failure is absorbed only when the base answer for the same key holds the same
  /// failure: a whole-step failure never absorbs a named test, nor a named test a whole step.
  public static func compare(
    head: [BaselineStepKey: BaselineStepResult], base: [BaselineStepKey: BaselineStepResult]
  ) -> BaselineVerdict {
    BaselineVerdict()
  }
}
