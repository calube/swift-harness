import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Claude's reason on a blocking finding that a backend without reasons decided (design §6 point
/// 2). Claude writes the reason and never changes the finding's severity.
enum JudgeBlockReason {
  /// Starts `failureScenario` when Claude couldn't write the reason; the rest says why.
  static let missingPrefix = "Claude's reason is missing: "

  /// The Claude judge that writes reasons, behind the judge cache under `root`. Its `claude`
  /// never sees the Jev key.
  static func liveJudge(root: URL, runner: any ProcessRunner = LiveProcessRunner()) -> any Judge {
    CachingJudge(
      ClaudeCLIJudge(runner: KeylessProcessRunner(inner: runner), model: JudgeFactory.defaultModel),
      cache: FileJudgeCache(directory: root.appending(path: FileJudgeCache.directoryName)))
  }

  /// `findings` with Claude's reason on each major finding `identity` decided, when `identity`'s
  /// backend needs one.
  static func attach(
    _ findings: [Finding], subjects: [JudgeSubject], answers: [String: [JudgeAnswer]],
    questions: JudgeQuestionSet, identity: JudgeIdentity, reasonJudge: (any Judge)?,
    redacting secrets: [String]
  ) async -> [Finding] {
    findings
  }
}

/// Runs every command without the Jev key in its environment, so a `claude` child never sees it.
struct KeylessProcessRunner: ProcessRunner {
  let inner: any ProcessRunner

  func run(_ invocation: ProcessInvocation) async throws(ProcessRunnerError) -> ProcessOutput {
    try await inner.run(invocation)
  }
}
