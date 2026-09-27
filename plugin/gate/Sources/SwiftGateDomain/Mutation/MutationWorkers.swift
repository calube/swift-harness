/// How many scratch worktrees run mutants at once. Each worker pays one cold build of every
/// package it tests, and a cold build of a package over TCA takes minutes of CPU and gigabytes of
/// memory, so more workers than a few costs more in builds than it saves in parallel test runs.
public enum MutationWorkers {
  public static let defaultCeiling = 4

  /// - Parameters:
  ///   - configured: `--jobs` or `[mutation] max_workers`; replaces the default formula.
  ///   - mutants: mutants that will run; no worker is started without one to take.
  public static func count(configured: Int?, cores: Int, mutants: Int) -> Int {
    let wanted =
      configured ?? min(cores - 1, (mutants + 1) / 2, defaultCeiling)
    return max(1, min(wanted, mutants))
  }
}
