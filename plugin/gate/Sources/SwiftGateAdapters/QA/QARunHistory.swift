import Foundation
import SwiftGateDomain

/// The `qa run`s a clone's runs directory holds, read for what a later run or the cutoff can take
/// from them.
public enum QARunHistory {
  /// Every `qa run --before-merge` report of `plan` under the runs of each checkout of
  /// `worktree`'s clone, so the plan checkout reads a fixer's `--fix` run in its slot; a report
  /// that doesn't decode is passed over, and 1 run read twice counts once.
  public static func beforeMergeReports(worktree: URL, plan: String) -> [QAReport] {
    var seen = Set<String>()
    return stateRoots(sharing: worktree).flatMap { files(QAReport.fileName, state: $0) }
      .compactMap { data -> QAReport? in
        guard let report = try? QAReportJSON.decode(data), report.plan == plan,
          report.trialMerge != nil, seen.insert(report.runID ?? "").inserted
        else { return nil }
        return report
      }
  }

  /// Every `qa run --at-base` report of `plan` under the runs of each checkout of `worktree`'s
  /// clone, prepared runs included; a report that doesn't decode is passed over, and 1 run read
  /// twice counts once.
  public static func atBaseReports(worktree: URL, plan: String) -> [QAReport] {
    var seen = Set<String>()
    return stateRoots(sharing: worktree).flatMap { files(QAReport.fileName, state: $0) }
      .compactMap { data -> QAReport? in
        guard let report = try? QAReportJSON.decode(data), report.plan == plan, report.atBase,
          let runID = report.runID, seen.insert(runID).inserted
        else { return nil }
        return report
      }
  }

  /// Every ``QAMergedTreeRun`` under the runs of each checkout of `worktree`'s clone, so a run
  /// in the plan checkout finds 1 a fixer's slot made on the same tree; a record that doesn't
  /// decode is passed over, and 1 run read twice counts once.
  public static func mergedTreeRuns(worktree: URL) -> [QAMergedTreeRun] {
    var seen = Set<String>()
    return stateRoots(sharing: worktree).flatMap { files(QAMergedTreeRun.fileName, state: $0) }
      .compactMap { try? QAMergedTreeRun.decode($0) }
      .filter { seen.insert($0.run.runID).inserted }
  }

  /// The runs directory of each state root ``stateRoots(sharing:)`` names, `worktree`'s own
  /// first: where a run made in any checkout of the clone, or kept from a removed one, lies.
  public static func runsDirectories(sharing worktree: URL) -> [URL] {
    stateRoots(sharing: worktree).map {
      $0.url(RunLayout.runsDirectory, directoryHint: .isDirectory).standardizedFileURL
    }
  }

  /// `worktree`'s own state root first, then, when it is under a git dir, the common dir's and
  /// each linked worktree's: where every checkout of the clone, and every removed checkout's
  /// kept runs, keep their runs.
  static func stateRoots(sharing worktree: URL) -> [StateRoot] {
    let own = StateRootResolver.resolve(worktree: worktree)
    guard case .gitDir(let gitDir) = own else { return [own] }
    let common = StateRootResolver.commonDirectory(of: gitDir).standardizedFileURL
    let linked = common.appending(path: "worktrees", directoryHint: .isDirectory)
    let names =
      ((try? FileManager.default.contentsOfDirectory(atPath: linked.path)) ?? []).sorted()
    let others =
      [StateRoot.gitDir(common)]
      + names.map { StateRoot.gitDir(linked.appending(path: $0, directoryHint: .isDirectory)) }
    var roots = [own]
    for root in others {
      let directory = root.directory.standardizedFileURL
      if !roots.contains(where: { $0.directory.standardizedFileURL == directory }) {
        roots.append(root)
      }
    }
    return roots
  }

  /// The `qa/report.json` of `runID` in the first of `worktrees` whose runs hold one that
  /// decodes.
  public static func report(runID: String, worktrees: [URL]) -> QAReport? {
    guard RunID.isValid(runID) else { return nil }
    for worktree in worktrees {
      let file = RunStore(worktreeRoot: worktree).state.url(
        RunLayout.runDirectory(for: runID), directoryHint: .isDirectory
      ).appending(path: "\(QAReport.directory)/\(QAReport.fileName)")
      if let data = try? Data(contentsOf: file), let report = try? QAReportJSON.decode(data) {
        return report
      }
    }
    return nil
  }

  /// The bytes of `runs/<run id>/qa/<name>` under `state` for each run that has one.
  private static func files(_ name: String, state: StateRoot) -> [Data] {
    let runs = state.url(RunLayout.runsDirectory, directoryHint: .isDirectory)
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []
    return ids.filter(RunID.isValid).compactMap { id in
      try? Data(contentsOf: runs.appending(path: "\(id)/\(QAReport.directory)/\(name)"))
    }
  }
}
