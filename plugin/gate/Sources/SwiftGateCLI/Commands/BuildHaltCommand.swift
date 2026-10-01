import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `build halt` and `build resume` against 1 checkout's store, with the config already read.
enum BuildHaltRun {
  /// What a halt or resume prints and exits with.
  struct Output: Equatable {
    let stdout: String
    let stderr: String
    let status: Int32
  }

  /// - Parameters:
  ///   - enabled: `.swiftgate.toml`'s `[telemetry] enabled`; `false` records nothing.
  static func halt(
    log: BuildHaltLog, enabled: Bool, buildRun: String, task: String?, reason: BuildHaltReason,
    json: Bool
  ) -> Output {
    Output(stdout: "", stderr: "", status: 0)
  }

  static func resume(
    log: BuildHaltLog, enabled: Bool, buildRun: String, task: String?,
    answer: BuildResumeAnswer, json: Bool
  ) -> Output {
    Output(stdout: "", stderr: "", status: 0)
  }
}

struct BuildHaltCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "halt",
    abstract: "Record that a build run stopped to ask a person, and why.")

  @Option(name: .customLong("run"), help: "The build run id that `build start` printed.")
  var buildRun: String

  @Option(help: "The task the halt is about; leave it out for a halt of the whole run.")
  var task: String?

  @Option(help: "Why the build stopped.")
  var reason: String

  @OptionGroup var output: OutputOptions

  func run() throws {}
}

struct BuildResumeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resume",
    abstract: "Record the answer to a build run's newest open halt and how long it waited.")

  @Option(name: .customLong("run"), help: "The build run id the halt named.")
  var buildRun: String

  @Option(help: "The task the halt named; leave it out for a halt of the whole run.")
  var task: String?

  @Option(help: "What the person answered.")
  var answer: String

  @OptionGroup var output: OutputOptions

  func run() throws {}
}
