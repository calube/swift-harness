import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `judge events` prints and the status it exits with.
struct JudgeEventsReport: Equatable {
  let stdout: String
  let stderr: String
  let status: Int32

  /// Reads the judge stream, the shared log or 1 run's copy, and summarizes what `filter` keeps.
  static func make(
    reader: any HarnessEventReading, runID: String?, filter: JudgeEventFilter, json: Bool
  ) -> JudgeEventsReport {
    JudgeEventsReport(stdout: "", stderr: "", status: 0)
  }
}
