/// `discover.run`: 1 `swiftgate discover`. Counts and closed values only: commands and paths never
/// go in.
public struct DiscoverRunEvent: Sendable, Equatable, Codable {
  public let milliseconds: Int
  public let areas: Int
  public let languages: [AreaLanguage]
  /// Values read from a build file or a CI command.
  public let found: Int
  /// Values discovery inferred without a file that states them.
  public let guessed: Int
  /// Steps an area has no command for.
  public let missing: Int
  /// Values `--set` or `--drop` changed.
  public let edited: Int

  public init(
    milliseconds: Int, areas: Int, languages: [AreaLanguage], found: Int, guessed: Int,
    missing: Int, edited: Int
  ) {
    self.milliseconds = milliseconds
    self.areas = areas
    self.languages = languages
    self.found = found
    self.guessed = guessed
    self.missing = missing
    self.edited = edited
  }

  /// The event for 1 applied `proposal`. Every command and Xcode table counts once by its
  /// confidence; an orchestrator value counts only in `edited`, which `--set` and `--drop` give.
  public init(proposal: DiscoverProposal, milliseconds: Int, edited: Int) {
    let confidences = proposal.areas.flatMap { area in
      area.commands.values.map(\.confidence) + (area.xcode.map { [$0.confidence] } ?? [])
    }
    let languages = Set(proposal.areas.map(\.language))
    self.init(
      milliseconds: milliseconds, areas: proposal.areas.count,
      languages: AreaLanguage.allCases.filter(languages.contains),
      found: confidences.filter { $0 == .found }.count,
      guessed: confidences.filter { $0 == .guessed }.count,
      missing: proposal.areas.reduce(0) { $0 + $1.missing.count }, edited: edited)
  }

  private enum CodingKeys: String, CodingKey {
    case areas, languages, found, guessed, missing, edited
    case milliseconds = "ms"
  }
}

/// The steps the warm-up runs, in order, per area.
public enum WarmupStep: String, Sendable, Codable, CaseIterable {
  case generate, build, test
}

/// Whether a warm-up step found its caches already filled.
public enum WarmupCache: String, Sendable, Codable, CaseIterable {
  case cold, warm
}

public enum WarmupOutcome: String, Sendable, Codable, CaseIterable {
  case passed
  case failed
  /// The orchestrator dropped the step before it ran.
  case dropped
  /// The tool the step needs isn't on this machine.
  case notInstalled = "not-installed"
}

/// `warmup.run`: 1 area's 1 step of the warm-up.
public struct WarmupRunEvent: Sendable, Equatable, Codable {
  public let area: String
  public let step: WarmupStep
  public let milliseconds: Int
  public let cache: WarmupCache
  public let outcome: WarmupOutcome

  public init(
    area: String, step: WarmupStep, milliseconds: Int, cache: WarmupCache, outcome: WarmupOutcome
  ) {
    self.area = area
    self.step = step
    self.milliseconds = milliseconds
    self.cache = cache
    self.outcome = outcome
  }

  private enum CodingKeys: String, CodingKey {
    case area, step, cache, outcome
    case milliseconds = "ms"
  }
}
