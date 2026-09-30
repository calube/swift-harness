import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `swiftgate judge ask` (design §8): any caller's question set, answered by the gate's judge,
/// with no policy.
enum JudgeAsk {
  static let badInputStatus: Int32 = 2
  static let backendFailedStatus: Int32 = 3

  /// Why nothing was answered, and the exit status that says so.
  struct Refusal: Error, Equatable {
    let status: Int32
    let message: String
  }

  /// The backend and model that answer.
  struct Choice: Equatable {
    let backend: JudgeBackend
    let model: String
  }

  /// The backend and model the flags and the repository's config name, or why they may not be
  /// used. `config` is the repository's config as it loaded.
  static func choose(
    backend: JudgeBackend?, model: String?, sendTo: String?,
    config: Result<Config?, StaticCheckInputs.ConfigFailure>
  ) -> Result<Choice, Refusal> {
    .failure(Refusal(status: 0, message: ""))
  }

  /// `judge` behind the answer cache under `root`, unless `noCache`.
  static func caching(_ judge: any Judge, root: URL, noCache: Bool) -> any Judge {
    judge
  }

  /// Every subject's answers as ``JudgeAskOutput`` JSON, or why the input or backend refused.
  /// `secrets` never appear in a refusal's message.
  static func answer(_ input: Data, judge: any Judge, secrets: [String]) async -> Result<
    Data, Refusal
  > {
    .success(Data())
  }
}

struct JudgeAskCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ask",
    abstract: "Ask the judge any question set about any subjects, and print the answers as JSON.")

  @Option(help: ArgumentHelp("The input JSON, or - for standard input.", valueName: "file|-"))
  var input: String

  @Option(
    name: [.customLong("backend"), .customLong("judge-backend")],
    help: "The backend that answers; the [judge] config's when unset.")
  var backend: JudgeBackend?

  @Option(
    name: [.customLong("model"), .customLong("judge-model")],
    help: "The backend's model; the config's, or the backend's default, when unset.")
  var model: String?

  @Option(
    help: ArgumentHelp(
      "The host a remote backend may send the input to; `--backend jev` needs it, or a [judge] "
        + "config naming it.",
      valueName: "host"))
  var sendTo: String?

  @Flag(help: "Ask the backend even when .harness/judge-cache/ holds the answers.")
  var noCache = false

  func run() async throws {}
}
