import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `swiftgate judge bench` and `bench-render` (design §10.6): measure backends on a labelled
/// dataset with no cache, 1 request at a time, and render the comparison from the raw answers.
enum JudgeBench {
  static let metricsDifferStatus: Int32 = 1
  static let badInputStatus: Int32 = 2
  static let backendFailedStatus: Int32 = 3

  /// Why nothing was measured or rendered, and the exit status that says so.
  struct Refusal: Error, Equatable {
    let status: Int32
    let message: String
  }

  /// The flags as given.
  struct Options: Equatable {
    var dataset: String
    var arms: [String]
    var repeats = JudgeBenchmarkMetrics.minimumRepeats
    var concurrency = 1
    var threshold = JudgeCalibration.decisionThreshold
    var cases: [String] = []
    var smoke = false
    var sendTo: String?
  }

  /// What a run will ask: the dataset, its cases, and each arm with the set it asks.
  struct Plan: Sendable {
    let dataset: JudgeDataset
    let cases: [JudgeDatasetCase]
    let arms: [(arm: JudgeBenchmarkArm, questions: JudgeQuestionSet)]
    let repeats: Int
    let concurrency: Int
    let threshold: Double
    let purpose: JudgeBenchmarkPurpose

    /// The questions each case is asked, in case order.
    var judgments: [Int] { [] }
  }

  /// Validates the options and loads the dataset. `configNamesHost` is true when the
  /// repository's `[judge]` config has already named the Jev host.
  static func plan(
    _ options: Options, root: URL, harnessRoot: URL?, configNamesHost: Bool,
    environment: [String: String]
  ) -> Result<Plan, Refusal> {
    .failure(Refusal(status: badInputStatus, message: ""))
  }

  /// Why a remote arm can't reach its backend: its key isn't set.
  static func missingKey(_ plan: Plan, environment: [String: String]) -> Refusal? {
    nil
  }

  /// A dataset by path, or by id: `test-quality`, `comments` or `calibrate-design:<run id>`.
  static func dataset(_ spec: String, root: URL, harnessRoot: URL?) -> Result<
    JudgeDataset, Refusal
  > {
    .failure(Refusal(status: badInputStatus, message: ""))
  }

  /// The arm's judge at its model, never behind the answer cache.
  static func liveJudge(
    _ arm: JudgeBenchmarkArm, runner: any ProcessRunner, environment: [String: String]
  ) -> any Judge {
    ClaudeCLIJudge(runner: runner, model: arm.model)
  }

  /// Asks every case of `plan` through `judges` (1 per arm, in arm order) `plan.repeats` times,
  /// and builds the result. A served model that changes mid-run fails it.
  static func run(_ plan: Plan, judges: [any Judge], startedAt: Date) async -> Result<
    JudgeBenchmarkReport, Refusal
  > {
    .failure(Refusal(status: backendFailedStatus, message: ""))
  }

  /// Recomputes a result's metrics and renders its page, refusing edited metrics.
  static func render(_ data: Data) -> Result<String, Refusal> {
    .failure(Refusal(status: badInputStatus, message: ""))
  }
}

struct JudgeBenchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bench",
    abstract: "Measure judge backends on a labelled dataset and write the raw answers and metrics.")

  func run() async throws {}
}

struct JudgeBenchRenderCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bench-render",
    abstract: "Recompute a judge bench result's metrics and print its comparison page.")

  func run() async throws {}
}
