import Foundation

/// Where the spec a run reads comes from.
public enum RunSpecSource: String, Codable, Sendable, Equatable {
  /// Untracked, or outside the clone: copied into the plan dir so the run reads a fixed copy and
  /// the user's tree gains nothing.
  case copied
  /// Tracked by the clone: read where it is.
  case tracked
}

/// `<plan-dir>/clock.json`: when a one-shot run started and what it started from. The clock
/// starts when `swiftgate run` reads the spec, before discovery, so every later event of the run
/// falls after it.
public struct RunClock: Codable, Sendable, Equatable {
  public static let fileName = "clock.json"
  /// The name an untracked spec's copy takes in the plan dir.
  public static let specCopyName = "spec.md"

  public let started: Date
  /// The spec the run reads: the copy, or the tracked file in place. Absolute.
  public let spec: String
  /// The path the user passed, made absolute.
  public let origin: String
  public let specSource: RunSpecSource
  public let planBranch: String
  /// The commit the plan branch starts at: the user's `HEAD` when the run started.
  public let base: String

  public init(
    started: Date, spec: String, origin: String, specSource: RunSpecSource, planBranch: String,
    base: String
  ) {
    self.started = started
    self.spec = spec
    self.origin = origin
    self.specSource = specSource
    self.planBranch = planBranch
    self.base = base
  }

  /// Pretty, key-sorted JSON with ISO 8601 times and a trailing newline.
  public func encoded() throws -> Data {
    Data()
  }

  public static func decode(_ data: Data) throws -> RunClock {
    try JSONDecoder().decode(RunClock.self, from: data)
  }
}

/// A run's plan slug, which also names its plan dir and plan branch.
public enum RunSlug {
  /// The spec file's stem in lowercase letters, digits and dashes, or `run` when nothing is left;
  /// `-2`, `-3`, … is appended while `isTaken` says a plan dir or branch already uses it.
  public static func make(specPath: String, isTaken: (String) -> Bool) -> String {
    "run"
  }
}

/// The orchestrator session `swiftgate run` starts.
public enum RunLaunch {
  /// The model the orchestrator runs on, pinned by id.
  public static let model = BuildPreset.WorkerModel.claudeOpus55.rawValue

  /// The prompt that starts the run skill, naming the slug, the spec and the plan branch.
  public static func prompt(slug: String, spec: String, planBranch: String) -> String {
    ""
  }

  /// `claude`'s argv: the clone's hook settings, the pinned model, the prompt, then `extra`
  /// unchanged. The prompt comes before `extra` so a variadic option there can't swallow it.
  public static func arguments(settings: String, prompt: String, extra: [String]) -> [String] {
    []
  }
}
