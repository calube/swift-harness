import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `swiftgate warmup [--areas a,b]`: runs every area's generate, build and test at the base tree
/// in parallel, filling the caches, the warm-up times and the baseline.
struct WarmupCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "warmup",
    abstract: "Warm every brownfield area's caches and record its times and baseline.")

  @Option(help: "Comma-separated area names; every area when absent.")
  var areas: String?

  @Flag(help: "Print JSON.")
  var json = false

  /// Why the warm-up couldn't start.
  struct SetupError: Error, Sendable, Equatable {
    let message: String
  }

  /// What 1 warm-up did.
  struct Outcome: Sendable {
    /// `git rev-parse HEAD^{tree}`: the base tree every file is named by.
    let tree: String
    let timesFile: String
    let areas: [WarmupAreaResult]
    /// Non-gating lines for stderr: a file not written, an event not recorded.
    let notes: [String]
  }

  /// The run's inputs a test replaces.
  struct Dependencies: Sendable {
    var processRunner: any ProcessRunner = LiveProcessRunner()
    /// `nil` runs each command through `/bin/sh` with ``processRunner``.
    var areaRunner: (any AreaCommandRunning)? = nil
    /// `nil` writes events under the repository's state root.
    var events: (any HarnessEventWriting)? = nil
    /// Per command run: a warm-up is never cut short by the gate budgets.
    var deadline: Duration = .seconds(3600)
  }

  /// The warm-up of `areaNames`, or of every area when `nil`, in the clone holding `directory`.
  static func warm(directory: URL, areaNames: [String]?, dependencies: Dependencies)
    async throws(SetupError) -> Outcome
  {
    Outcome(tree: "", timesFile: "", areas: [], notes: [])
  }

  /// A generator's outcome as the warm-up records it.
  static func generation(
    from outcome: XcodeGenerateOutcome<WarmupTreeRun>, milliseconds: Int
  ) -> WarmupGeneration {
    .notGenerated(milliseconds: milliseconds, outcome: .failed, detail: "")
  }

  func run() async throws {
    try StubCommand.notImplemented("warmup", json: json)
  }
}
