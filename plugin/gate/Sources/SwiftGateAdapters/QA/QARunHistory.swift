import Foundation
import SwiftGateDomain

/// The `qa run`s a clone's runs directory holds, read for what a later run or the cutoff can take
/// from them.
public enum QARunHistory {
  /// Every `qa run --before-merge` report of `plan` under `worktree`'s runs; a report that doesn't
  /// decode is passed over.
  public static func beforeMergeReports(worktree: URL, plan: String) -> [QAReport] {
    files(QAReport.fileName, worktree: worktree).compactMap { data in
      guard let report = try? QAReportJSON.decode(data), report.plan == plan,
        report.trialMerge != nil
      else { return nil }
      return report
    }
  }

  /// Every ``QAMergedTreeRun`` under `worktree`'s runs; a record that doesn't decode is passed
  /// over.
  public static func mergedTreeRuns(worktree: URL) -> [QAMergedTreeRun] {
    files(QAMergedTreeRun.fileName, worktree: worktree).compactMap {
      try? QAMergedTreeRun.decode($0)
    }
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

  /// The bytes of `runs/<run id>/qa/<name>` for each run that has one.
  private static func files(_ name: String, worktree: URL) -> [Data] {
    let runs = RunStore(worktreeRoot: worktree).state.url(
      RunLayout.runsDirectory, directoryHint: .isDirectory)
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []
    return ids.filter(RunID.isValid).compactMap { id in
      try? Data(contentsOf: runs.appending(path: "\(id)/\(QAReport.directory)/\(name)"))
    }
  }
}
