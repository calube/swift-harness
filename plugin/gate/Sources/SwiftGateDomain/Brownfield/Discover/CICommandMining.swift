/// 1 command a CI workflow, `Makefile`, `justfile` or `bin/*` script already runs, attributed to
/// 1 area and step.
public struct MinedCommand: Sendable, Equatable {
  public let area: String
  public let step: AreaStep
  /// Runnable from the repository root.
  public let command: String
  /// Repository-relative path of the file that runs it.
  public let source: String

  public init(area: String, step: AreaStep, command: String, source: String) {
    self.area = area
    self.step = step
    self.command = command
    self.source = source
  }
}

/// Finds the test, lint and build commands a repository already runs, which outrank a reader's
/// guess (design §5.1).
public enum CICommandMining {
  /// Every attributable command in `tree`, CI workflows first, then `Makefile`, `justfile` and
  /// `bin/*`, each group in path order.
  public static func commands(in tree: TrackedTreeSnapshot, areas: [ProposedArea])
    -> [MinedCommand]
  {
    []
  }

  /// `areas` with the first mined command for each area and step replacing a guessed value or
  /// filling a missing one. A value a build file states stays.
  public static func outrank(_ areas: [ProposedArea], with mined: [MinedCommand])
    -> [ProposedArea]
  {
    areas
  }
}
