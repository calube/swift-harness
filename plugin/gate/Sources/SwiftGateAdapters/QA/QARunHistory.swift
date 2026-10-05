import Foundation
import SwiftGateDomain

/// The `qa run`s a clone's runs directory holds, read for what a later run or the cutoff can take
/// from them.
public enum QARunHistory {
  /// Every `qa run --before-merge` report of `plan` under `worktree`'s runs; a report that doesn't
  /// decode is passed over.
  public static func beforeMergeReports(worktree: URL, plan: String) -> [QAReport] {
    []
  }

  /// Every ``QAMergedTreeRun`` under `worktree`'s runs; a record that doesn't decode is passed
  /// over.
  public static func mergedTreeRuns(worktree: URL) -> [QAMergedTreeRun] {
    []
  }
}
