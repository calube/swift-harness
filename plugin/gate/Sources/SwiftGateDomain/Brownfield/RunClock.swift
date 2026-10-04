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
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.formatted(Self.timeStyle))
    }
    return try encoder.encode(self) + Data("\n".utf8)
  }

  public static func decode(_ data: Data) throws -> RunClock {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard let date = try? Date(text, strategy: timeStyle) else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "\(text) is not an ISO 8601 time")
      }
      return date
    }
    return try decoder.decode(RunClock.self, from: data)
  }

  /// Milliseconds, so the clock orders against events written in the same second.
  private static let timeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// A run's plan slug, which also names its plan dir and plan branch.
public enum RunSlug {
  /// The spec file's stem in lowercase letters, digits and dashes, or `run` when nothing is left;
  /// `-2`, `-3`, … is appended while `isTaken` says a plan dir or branch already uses it.
  public static func make(specPath: String, isTaken: (String) -> Bool) -> String {
    let name = specPath.split(separator: "/").last.map(String.init) ?? ""
    let stem = name.lastIndex(of: ".").map { String(name[..<$0]) } ?? name
    var words: [String] = []
    var word = ""
    for character in stem.lowercased() {
      if character.isASCII, character.isLetter || character.isNumber {
        word.append(character)
      } else if !word.isEmpty {
        words.append(word)
        word = ""
      }
    }
    if !word.isEmpty { words.append(word) }
    let base = words.isEmpty ? "run" : words.joined(separator: "-")
    if !isTaken(base) { return base }
    var suffix = 2
    while isTaken("\(base)-\(suffix)") { suffix += 1 }
    return "\(base)-\(suffix)"
  }
}

/// The orchestrator session `swiftgate run` starts.
public enum RunLaunch {
  /// The model the orchestrator runs on, pinned by id.
  public static let model = BuildPreset.WorkerModel.claudeOpus55.rawValue

  /// The prompt that starts the run skill, naming the slug, the spec and the plan branch.
  public static func prompt(slug: String, spec: String, planBranch: String) -> String {
    "/swift-harness:run This run comes from `swiftgate run`. Plan slug: \(slug). Spec: \(spec). "
      + "Plan branch: \(planBranch)."
  }

  /// `claude`'s argv: the clone's hook settings, the pinned model, the prompt, then `extra`
  /// unchanged. The prompt comes before `extra` so a variadic option there can't swallow it.
  public static func arguments(settings: String, prompt: String, extra: [String]) -> [String] {
    ["--settings", settings, "--model", model, prompt] + extra
  }
}
