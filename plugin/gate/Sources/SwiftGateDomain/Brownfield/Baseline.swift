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
    self.selection = selection.sorted()
  }
}

/// How 1 step ended, reduced to what the baseline compares.
public enum BaselineStepResult: Sendable, Hashable {
  case passed
  /// The ids of the failing tests, `<classname>.<name>`; never empty.
  case failedTests(Set<String>)
  /// Failed with no test id to read: no JUnit, an unreadable report, a crash or a timeout.
  case failed
  /// Exited 127: the shell couldn't find the command's tool, so the step checked nothing.
  case notInstalled

  public static func of(_ outcome: AreaCommandOutcome) -> BaselineStepResult {
    switch outcome {
    case .passed: return .passed
    case .failed(127, _, _): return .notInstalled
    case .failed(_, _, let junit?):
      let tests = Self.failingTests(junit)
      return tests.isEmpty ? .failed : .failedTests(tests)
    case .failed, .crashed, .timedOut: return .failed
    }
  }

  /// An unreadable report, or one naming no failing case, reads as no ids: the step failed.
  private static func failingTests(_ junit: Data) -> Set<String> {
    guard let cases = JUnitReports.cases(junit) else { return [] }
    var tests = Set<String>()
    for testCase in cases {
      guard case .failed = testCase.outcome else { continue }
      // Jest's reporter repeats the full test name as its classname.
      let id =
        testCase.className.isEmpty || testCase.className == testCase.name
        ? testCase.name : "\(testCase.className).\(testCase.name)"
      tests.insert(id)
    }
    return tests
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
    let stored: StoredFile
    do {
      stored = try JSONDecoder().decode(StoredFile.self, from: data)
    } catch {
      throw BaselineFileError(detail: "\(error)")
    }
    guard stored.version == version else {
      throw BaselineFileError(detail: "version \(stored.version), expected \(version)")
    }
    guard stored.tree == tree else {
      throw BaselineFileError(detail: "recorded for tree \(stored.tree), expected \(tree)")
    }
    var records: [BaselineRecord] = []
    for record in stored.records {
      let result: BaselineStepResult
      switch (record.result, record.tests) {
      case (.passed, nil): result = .passed
      case (.failed, nil): result = .failed
      case (.notInstalled, nil): result = .notInstalled
      case (.failedTests, let tests?) where !tests.isEmpty: result = .failedTests(Set(tests))
      default:
        throw BaselineFileError(
          detail: "\(record.area) \(record.step.rawValue): result \(record.result.rawValue) "
            + "with \(record.tests.map { "\($0.count) tests" } ?? "no tests")")
      }
      records.append(
        BaselineRecord(
          key: BaselineStepKey(
            area: record.area, step: record.step, command: record.command,
            selection: record.selection),
          result: result))
    }
    return BaselineFile(tree: tree, records: records)
  }

  public func encoded() -> Data {
    let stored = StoredFile(
      version: Self.version, tree: tree,
      records: records.map { record in
        let (result, tests): (StoredResult, [String]?) =
          switch record.result {
          case .passed: (.passed, nil)
          case .failed: (.failed, nil)
          case .notInstalled: (.notInstalled, nil)
          case .failedTests(let tests): (.failedTests, tests.sorted())
          }
        return StoredRecord(
          area: record.key.area, step: record.key.step, command: record.key.command,
          selection: record.key.selection, result: result, tests: tests)
      })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    // Every field is a string, an int or an array of them, which always encode.
    return (try? encoder.encode(stored)) ?? Data()
  }

  /// A newer answer for a key replaces the older one.
  public mutating func merge(_ newer: [BaselineRecord]) {
    let replaced = Set(newer.map(\.key))
    records.removeAll { replaced.contains($0.key) }
    var seen = Set<BaselineStepKey>()
    for record in newer.reversed() where seen.insert(record.key).inserted {
      records.append(record)
    }
  }

  public var results: [BaselineStepKey: BaselineStepResult] {
    Dictionary(records.map { ($0.key, $0.result) }, uniquingKeysWith: { _, last in last })
  }

  private enum StoredResult: String, Codable {
    case passed, failed
    case failedTests = "failed-tests"
    case notInstalled = "not-installed"
  }

  private struct StoredRecord: Codable {
    let area: String
    let step: AreaStep
    let command: String
    let selection: [String]
    let result: StoredResult
    let tests: [String]?
  }

  private struct StoredFile: Codable {
    let version: Int
    let tree: String
    let records: [StoredRecord]
  }
}

/// What the baseline made of a gate's failures.
public struct BaselineVerdict: Sendable, Equatable {
  /// Failing at both the head and the base tree: reported, never gating.
  public let absorbed: [BaselineFailure]
  /// Failing at the head only, or with no answer at the base: these gate.
  public let remaining: [BaselineFailure]
  /// Not installed at both the head and the base tree: neither absorbed nor gating, and reported.
  public let notInstalled: [BaselineStepKey]

  public init(
    absorbed: [BaselineFailure] = [], remaining: [BaselineFailure] = [],
    notInstalled: [BaselineStepKey] = []
  ) {
    self.absorbed = absorbed
    self.remaining = remaining
    self.notInstalled = notInstalled
  }

  /// `gate.run`'s `baselineCount`.
  public var baselineCount: Int { absorbed.count }

  /// The `baseline.summary` nit listing what was absorbed; `nil` when nothing was.
  public func summary(file: String) -> Finding? {
    guard !absorbed.isEmpty else { return nil }
    let listed = absorbed.map { failure in
      "\(failure.key.area) \(failure.key.step.rawValue)"
        + (failure.test.map { ": \($0)" } ?? " (the whole step)")
    }
    return try? Finding(
      ruleID: BrownfieldRuleID.baselineSummary.rawValue, severity: .nit, file: file, line: nil,
      message:
        "\(absorbed.count) failure(s) also fail at the merge base, so they don't gate: "
        + listed.joined(separator: "; "),
      failureScenario: nil)
  }
}

extension BaselineVerdict {
  /// 1 non-gating `area.step-dropped` per step whose tool isn't installed.
  public func notInstalledFindings(file: String) -> [Finding] {
    notInstalled.compactMap { key in
      try? Finding(
        ruleID: BrownfieldRuleID.stepDropped.rawValue, severity: .minor, file: file, line: nil,
        message:
          "\(key.area) \(key.step.rawValue): its command's tool isn't installed (exit 127 at the "
          + "head and the merge base), so the step checked nothing; put the tool on PATH or drop "
          + "the step",
        failureScenario: nil)
    }
  }
}

public enum Baseline {
  /// The failures a step's result holds.
  public static func failures(of key: BaselineStepKey, _ result: BaselineStepResult)
    -> [BaselineFailure]
  {
    switch result {
    case .passed: []
    case .failed: [BaselineFailure(key: key, test: nil)]
    case .notInstalled: []
    case .failedTests(let tests):
      tests.sorted().map { BaselineFailure(key: key, test: $0) }
    }
  }

  /// A head failure is absorbed only when the base answer for the same key holds the same
  /// failure: a whole-step failure never absorbs a named test, nor a named test a whole step.
  /// A step not installed at the head is never absorbed: it is reported when the base can't run
  /// it either, and gates when the base can.
  public static func compare(
    head: [BaselineStepKey: BaselineStepResult], base: [BaselineStepKey: BaselineStepResult]
  ) -> BaselineVerdict {
    var absorbed: [BaselineFailure] = []
    var remaining: [BaselineFailure] = []
    var notInstalled: [BaselineStepKey] = []
    for key in head.keys.sorted(by: Self.order) {
      if head[key] == .notInstalled {
        // A whole-step failure recorded before not-installed was its own answer reads the same.
        if base[key] == .notInstalled || base[key] == .failed {
          notInstalled.append(key)
        } else {
          remaining.append(BaselineFailure(key: key, test: nil))
        }
        continue
      }
      let known = Set(base[key].map { failures(of: key, $0) } ?? [])
      for failure in failures(of: key, head[key] ?? .passed) {
        if known.contains(failure) {
          absorbed.append(failure)
        } else {
          remaining.append(failure)
        }
      }
    }
    return BaselineVerdict(absorbed: absorbed, remaining: remaining, notInstalled: notInstalled)
  }

  private static func order(_ lhs: BaselineStepKey, _ rhs: BaselineStepKey) -> Bool {
    (lhs.area, lhs.step.rawValue, lhs.command, lhs.selection.joined(separator: "\n"))
      < (rhs.area, rhs.step.rawValue, rhs.command, rhs.selection.joined(separator: "\n"))
  }
}
