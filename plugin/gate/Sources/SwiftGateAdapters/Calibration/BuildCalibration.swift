import Foundation
import SwiftGateDomain

/// The build agents `calibrate build` knows how to seed. Each needs its own repository setup.
public enum BuildCalibrationRole: String, Sendable, Equatable, CaseIterable {
  case worker = "build-worker"
  case fixer = "build-fixer"

  /// Case entries besides `input.md` and `label.json`.
  public var requiredEntries: [String] {
    switch self {
    case .worker: ["base", "accept", "solution", "context.md"]
    case .fixer: ["base", "main", "task", "accept", "solution"]
    }
  }
}

/// A build seed's `label.json`: the outcome a correct agent returns, the files its commits may
/// touch and the acceptance tests that must pass on its branch (spec §12, "labelled by
/// construction": the seed's `solution/` meets it).
public struct BuildCalibrationLabel: CalibrationSeedLabel {
  public static let currentSchemaVersion = 1
  public static let suite = CalibrationSuite.build

  public let schemaVersion: Int
  public let outcome: TaskReturn.Outcome
  /// The tier the agent's gate run must cover: the task gate, or the fixer's merge gate.
  public let gate: CheckTier
  /// Repo-relative files the agent's branch may differ in from where it started: the task's
  /// base for a worker, `main` for a fixer.
  public let writeSet: [String]
  /// Acceptance tests as `<className>/<name>` from the xUnit report, such as
  /// `GreeterTests.CalibrationAcceptance/formalGreeting()`.
  public let tests: [String]

  public init(
    outcome: TaskReturn.Outcome, gate: CheckTier, writeSet: [String], tests: [String]
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.outcome = outcome
    self.gate = gate
    self.writeSet = writeSet
    self.tests = tests
  }

  private static let keys: Set<String> = ["schemaVersion", "outcome", "gate", "writeSet", "tests"]

  public static func requiredEntries(agent: String) -> [String] {
    BuildCalibrationRole(rawValue: agent)?.requiredEntries ?? []
  }

  /// Decodes and validates: every key present and no other, a known schema version, outcome and
  /// tier, a non-empty write set of distinct relative paths that stay inside the repository, and
  /// one or more distinct `<className>/<name>` tests.
  public static func decode(_ data: Data, agent: String)
    -> Result<BuildCalibrationLabel, CalibrationLabel.SeedError>
  {
    func failure(_ message: String) -> Result<BuildCalibrationLabel, CalibrationLabel.SeedError> {
      .failure(CalibrationLabel.SeedError(message: message))
    }
    guard
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return failure("not a JSON object") }
    let present = Set(object.keys)
    if let unknown = present.subtracting(keys).sorted().first {
      return failure("unknown key `\(unknown)`")
    }
    if let missing = keys.subtracting(present).sorted().first {
      return failure("missing key `\(missing)`")
    }
    guard let version = object["schemaVersion"] as? Int, version == currentSchemaVersion else {
      return failure("unsupported schemaVersion \(object["schemaVersion"] ?? "null")")
    }
    guard let outcomeText = object["outcome"] as? String,
      let outcome = TaskReturn.Outcome(rawValue: outcomeText)
    else {
      return failure(
        "outcome must be one of \(TaskReturn.Outcome.allCases.map(\.rawValue)), not "
          + "\(object["outcome"] ?? "null")")
    }
    guard let gateText = object["gate"] as? String, let gate = CheckTier(rawValue: gateText) else {
      return failure(
        "gate must be one of \(CheckTier.allCases.map(\.rawValue)), not \(object["gate"] ?? "null")"
      )
    }
    guard let writeSet = object["writeSet"] as? [String], !writeSet.isEmpty,
      Set(writeSet).count == writeSet.count
    else { return failure("writeSet needs one or more distinct paths") }
    if let escaping = writeSet.first(where: { path in
      path.isEmpty || path.hasPrefix("/") || path.split(separator: "/").contains("..")
    }) {
      return failure("writeSet path `\(escaping)` isn't a relative path inside the repository")
    }
    guard let tests = object["tests"] as? [String], !tests.isEmpty,
      Set(tests).count == tests.count
    else { return failure("tests needs one or more distinct tests") }
    if let malformed = tests.first(where: { BuildCalibrationTestID($0) == nil }) {
      return failure("test `\(malformed)` isn't `<className>/<name>`")
    }
    return .success(
      BuildCalibrationLabel(outcome: outcome, gate: gate, writeSet: writeSet, tests: tests))
  }
}

/// A labelled test: the xUnit `classname` and `name` of one test case.
struct BuildCalibrationTestID: Hashable {
  let className: String
  let name: String

  init?(_ text: String) {
    guard let slash = text.firstIndex(of: "/") else { return nil }
    className = String(text[..<slash])
    name = String(text[text.index(after: slash)...])
    guard !className.isEmpty, !name.isEmpty else { return nil }
  }
}

/// The build suite's seeds: a small git repository per case, set up for its agent.
public typealias BuildCalibrationSeeds = CalibrationSeeds<BuildCalibrationLabel>

/// Why a case couldn't be judged. A seed defect is the repository's to fix; `blocked` means the
/// environment couldn't answer (git, `swift` or `claude` failed to run).
public enum CalibrationCaseError: Error, Sendable, Equatable {
  case seedDefect(String)
  case blocked(String)
}
