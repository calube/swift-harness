import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Why a `swiftgate sprint` command refused. Each id names what to do next in its message.
enum SprintRefusal: String, CaseIterable, Sendable {
  case outOfOrder = "sprint.out-of-order"
  case invalidSlug = "sprint.invalid-slug"
  case invalidSpecPage = "sprint.invalid-spec-page"
  case invalidCommit = "sprint.invalid-commit"
  case invalidGateRun = "sprint.invalid-gate-run"
  case invalidSliceCount = "sprint.invalid-slice-count"
  case specPageMissing = "sprint.spec-page-missing"
  case mainNotGreen = "sprint.main-not-green"
  case branchExists = "sprint.branch-exists"
  case wrongBranch = "sprint.wrong-branch"
  case surfaceOffBranch = "sprint.surface-off-branch"
  case surfaceBehaviour = "sprint.surface-behaviour"
  case surfaceUnreadable = "sprint.surface-unreadable"
  case gateUnknown = "sprint.gate-unknown"
  case gateTier = "sprint.gate-tier"
  case gateNotReady = "sprint.gate-not-ready"
  case gateRed = "sprint.gate-red"
  case gateBlocked = "sprint.gate-blocked"
  case gateStale = "sprint.gate-stale"
  case gateProofBase = "sprint.gate-proof-base"
  case mainMoved = "sprint.main-moved"
  case notFastForward = "sprint.not-fast-forward"
  case mainCheckedOut = "sprint.main-checked-out"
  case historyUnreadable = "sprint.history-unreadable"
  case stateMalformed = "sprint.state-malformed"
  case stateLocked = "sprint.state-locked"
  case stateIO = "sprint.state-io"
  case commonDirectory = "sprint.common-directory"
  case git = "sprint.git"

  /// RED for a refusal the caller fixes; BLOCKED when the state, history or git couldn't be read.
  var verdict: Verdict { .green }
}

/// What 1 sprint command did, or why it refused.
struct SprintOutcome: Sendable, Equatable {
  let command: String
  /// `nil` when the command did what it was asked.
  let refusal: SprintRefusal?
  let message: String
  /// The recorded run after the command: the new one, or the unchanged one it refused on.
  let run: SprintRun?

  var verdict: Verdict { .green }
}

/// The checkout and plan state a sprint command acts on.
struct SprintContext: Sendable {
  /// The checkout the command runs in: its run history holds the gate runs a command reads.
  let root: URL
  let git: any Git
  let branches: any SprintBranches
  let store: SprintStore
  let surfaceReader: any SurfaceCommitReading
}

/// Fast modes §4: each sprint step is a command that checks it before the state machine records it.
enum SprintCommandRun {
  static func start(slug: String, specPage: String, slices: Int, context: SprintContext) async
    -> SprintOutcome
  {
    SprintOutcome(command: "", refusal: nil, message: "", run: nil)
  }

  static func surface(commit: String, context: SprintContext) async -> SprintOutcome {
    SprintOutcome(command: "", refusal: nil, message: "", run: nil)
  }

  static func slice(_ number: Int, gate: String, context: SprintContext) async -> SprintOutcome {
    SprintOutcome(command: "", refusal: nil, message: "", run: nil)
  }

  static func finish(gate: String, context: SprintContext) async -> SprintOutcome {
    SprintOutcome(command: "", refusal: nil, message: "", run: nil)
  }

  static func status(context: SprintContext) async -> SprintOutcome {
    SprintOutcome(command: "", refusal: nil, message: "", run: nil)
  }

  static func render(_ outcome: SprintOutcome, format: OutputFormat) -> String {
    ""
  }
}

struct SprintCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sprint",
    abstract: "Run a sprint's steps in order: start, surface, slices, finish (fast modes §4).",
    subcommands: [
      SprintStartCommand.self, SprintSurfaceCommand.self, SprintSliceCommand.self,
      SprintFinishCommand.self, SprintStatusCommand.self,
    ])
}

struct SprintStartCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start", abstract: "Create sprint/<slug> from a green main and record the sprint.")

  @Argument(help: "Lowercase letters and digits joined by single hyphens.")
  var slug: String

  @Option(name: .customLong("spec-page"), help: "The sprint's 1-page spec.")
  var specPage: String

  @Option(help: "How many slices the spec page lists.")
  var slices: Int

  @OptionGroup var output: OutputOptions

  func run() async throws {
    try StubCommand.notImplemented("sprint start", json: output.json)
  }
}

struct SprintSurfaceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "surface", abstract: "Check the surface commit and record it.")

  @Argument(help: "The surface commit.")
  var commit: String

  @OptionGroup var output: OutputOptions

  func run() async throws {
    try StubCommand.notImplemented("sprint surface", json: output.json)
  }
}

struct SprintSliceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "slice", abstract: "Record a slice that passed its push gate at the branch HEAD.")

  @Argument(help: "The slice's number on the spec page, from 1.")
  var number: Int

  @Option(help: "The push gate run's id, as `check` printed it.")
  var gate: String

  @OptionGroup var output: OutputOptions

  func run() async throws {
    try StubCommand.notImplemented("sprint slice", json: output.json)
  }
}

struct SprintFinishCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "finish", abstract: "Fast-forward main to a sprint whose ready gate is green.")

  @Option(help: "The ready gate run's id, as `check` printed it.")
  var gate: String

  @OptionGroup var output: OutputOptions

  func run() async throws {
    try StubCommand.notImplemented("sprint finish", json: output.json)
  }
}

struct SprintStatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status", abstract: "Show the recorded sprint and the step it needs next.")

  @OptionGroup var output: OutputOptions

  func run() async throws {
    try StubCommand.notImplemented("sprint status", json: output.json)
  }
}
