/// Flaky tests per tree, and the slowest tests. Sealed segments are read through their rollups,
/// active files through the events the query kept.
public struct TestsSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .tests }

  /// How many of the slowest tests the section lists.
  static let slowest = 10

  /// What 1 run did, per test: `true` when any of its results failed, `false` when one passed
  /// and none failed. A test that was skipped or not selected isn't there.
  private struct RunOutcomes {
    let label: String
    let parentID: String?
    var failed: [String: Bool] = [:]
  }

  private struct TreeTally {
    var passed: [String] = []
    var failed: [String] = []
  }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    let sealed = TestRollupRead.read(files: input.files, query: input.query)
    var runs: [RunOutcomes] = []
    var timings: [String: [Int]] = [:]
    var seen = Set<String>()
    func add(_ rollup: TestRollup, keeping keep: (TestRollup.Run) -> Bool) {
      for run in rollup.runs where keep(run) {
        // A run is in 1 segment, or still active; an imported copy of either names it again.
        guard seen.insert(run.parentID ?? "run \(run.runID ?? "")").inserted else { continue }
        var outcomes = RunOutcomes(label: run.runID ?? run.parentID ?? "?", parentID: run.parentID)
        let failed = Set(run.failed)
        let skipped = Set(run.skipped)
        for (position, test) in run.results.enumerated() where !skipped.contains(position) {
          let name = rollup.tests[test]
          if failed.contains(position) {
            outcomes.failed[name] = true
          } else if outcomes.failed[name] == nil {
            outcomes.failed[name] = false
          }
          if let ms = run.milliseconds[position] { timings[name, default: []].append(ms) }
        }
        runs.append(outcomes)
      }
    }
    for rollup in sealed.rollups {
      add(rollup) { run in
        if let since = input.query.since, run.firstTime < since { return false }
        if let runID = input.query.runID, run.runID != runID { return false }
        return true
      }
    }
    add(TestRollup(results: input.events.map(\.event))) { _ in true }
    guard !runs.isEmpty || !sealed.damage.isEmpty else { return nil }

    var lines: [String] = []
    var metrics: [EventSummaryMetric] = []
    flakes(runs, input: input, lines: &lines, metrics: &metrics)
    slowest(timings, lines: &lines, metrics: &metrics)
    lines += sealed.damage.map { "damage: \($0)" }
    return EventSummarySectionReport(id: id, state: .reported, lines: lines, metrics: metrics)
  }

  private func flakes(
    _ runs: [RunOutcomes], input: EventSummaryInput, lines: inout [String],
    metrics: inout [EventSummaryMetric]
  ) {
    var treeOfRun: [String: String] = [:]
    for stored in input.events {
      guard case .gateRun(let run) = stored.event.payload, let tree = run.treeHash,
        run.dirty == false
      else { continue }
      treeOfRun[stored.event.eventID] = tree
    }
    var trees: [String: [String: TreeTally]] = [:]
    var cleanRuns = 0
    for run in runs {
      guard let tree = run.parentID.flatMap({ treeOfRun[$0] }) else { continue }
      cleanRuns += 1
      for (test, failed) in run.failed {
        if failed {
          trees[tree, default: [:]][test, default: TreeTally()].failed.append(run.label)
        } else {
          trees[tree, default: [:]][test, default: TreeTally()].passed.append(run.label)
        }
      }
    }
    var comparableTrees: [String: Int] = [:]
    var flaked: [String: [(tree: String, tally: TreeTally)]] = [:]
    for (tree, tests) in trees {
      for (test, tally) in tests where tally.passed.count + tally.failed.count >= 2 {
        comparableTrees[test, default: 0] += 1
        if !tally.passed.isEmpty && !tally.failed.isEmpty {
          flaked[test, default: []].append((tree, tally))
        }
      }
    }
    let uncompared = runs.count - cleanRuns
    metrics += [
      EventSummaryMetric(
        name: "clean-runs", group: [], value: Double(cleanRuns), unit: .count, n: runs.count),
      EventSummaryMetric(
        name: "uncompared-runs", group: [], value: Double(uncompared), unit: .count,
        n: runs.count),
      EventSummaryMetric(
        name: "clean-trees", group: [], value: Double(trees.count), unit: .count, n: cleanRuns),
      EventSummaryMetric(
        name: "flaky-tests", group: [], value: Double(flaked.count), unit: .count, n: cleanRuns),
    ]
    lines.append(
      "flaky: \(flaked.count) tests passed and failed on 1 clean tree (n=\(cleanRuns) clean runs "
        + "on \(trees.count) trees); \(uncompared) dirty, unhashed or unmatched runs not compared")
    let ranked = flaked.sorted { ($1.value.count, $0.key) < ($0.value.count, $1.key) }
    for (test, onTrees) in ranked {
      let comparable = comparableTrees[test] ?? onTrees.count
      let share = Double(onTrees.count) / Double(comparable)
      metrics.append(
        EventSummaryMetric(
          name: "flaky-tree-share", group: [test], value: share, unit: .share, n: comparable))
      lines.append(
        "  \(test): flaked on \(onTrees.count) of \(comparable) clean trees it ran on twice "
          + "(n=\(comparable))")
      for (tree, tally) in onTrees.sorted(by: { $0.tree < $1.tree }) {
        let n = tally.passed.count + tally.failed.count
        metrics += [
          EventSummaryMetric(
            name: "flaky-passed", group: [test, tree], value: Double(tally.passed.count),
            unit: .count, n: n),
          EventSummaryMetric(
            name: "flaky-failed", group: [test, tree], value: Double(tally.failed.count),
            unit: .count, n: n),
        ]
        lines.append(
          "    \(test) on tree \(tree.prefix(12)): \(tally.passed.count) passed, "
            + "\(tally.failed.count) failed (runs "
            + (tally.passed + tally.failed).sorted().joined(separator: ", ") + ")")
      }
    }
  }

  private func slowest(
    _ timings: [String: [Int]], lines: inout [String], metrics: inout [EventSummaryMetric]
  ) {
    let ranked = timings.compactMap { test, ms in TimingStats(milliseconds: ms).map { (test, $0) } }
      .sorted { ($1.1.p95, $1.1.p50, $0.0) < ($0.1.p95, $0.1.p50, $1.0) }
      .prefix(Self.slowest)
    guard !ranked.isEmpty else { return }
    lines.append("slowest \(ranked.count) of \(timings.count) timed tests, by p95:")
    for (test, stats) in ranked {
      let group = ["slowest", test]
      metrics += [
        EventSummaryMetric(
          name: "p50", group: group, value: Double(stats.p50), unit: .milliseconds, n: stats.n),
        EventSummaryMetric(
          name: "p95", group: group, value: Double(stats.p95), unit: .milliseconds, n: stats.n),
        EventSummaryMetric(
          name: "sd", group: group, value: stats.standardDeviation, unit: .milliseconds,
          n: stats.n),
      ]
      lines.append("  \(test): \(stats.rendered)")
    }
  }
}
