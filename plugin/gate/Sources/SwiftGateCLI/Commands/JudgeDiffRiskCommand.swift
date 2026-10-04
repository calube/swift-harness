import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `judge diff-risk`: how much review the change since a base needs (design §11.5).
enum JudgeDiffRiskRun {
  enum Outcome: Sendable, Equatable {
    case rated(DiffRiskVerdict)
    /// No level, and why: never a default level.
    case noAnswer(String)
  }

  /// Rates the change from the merge base of `HEAD` and `base` to the working tree. A path
  /// matching `sensitive` is `high` without asking `judge`.
  static func run(
    base: String, git: any Git, diff: any DiffReading, sensitive: [String],
    judge: BrownfieldJudge?
  ) async -> Outcome {
    .noAnswer("judge diff-risk is not built yet")
  }

  /// The printed line and the exit status: 0 with a level, 1 without one.
  static func render(_ outcome: Outcome, json: Bool) -> (text: String, status: Int32) {
    switch outcome {
    case .rated(let verdict): (verdict.level.rawValue, 0)
    case .noAnswer(let why): (why, 1)
    }
  }
}

struct JudgeDiffRiskCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "diff-risk",
    abstract: "Rate how much review the change since --base needs: low, medium or high.")

  @Option(help: "The change is measured from the merge base of HEAD and this ref.")
  var base: String

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let (text, status) = JudgeDiffRiskRun.render(
      .noAnswer("judge diff-risk is not built yet"), json: output.json)
    Console.write(text)
    if status != 0 { throw ExitCode(status) }
  }
}
