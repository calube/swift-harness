import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Why `plan surface` refused a surface it could judge. Each is exit 1 and writes nothing.
enum PlanSurfaceRule: String, Sendable, Equatable, CaseIterable {
  /// The plan's spec page has no confirmation, or its bytes moved since the confirm.
  case notConfirmed = "plan-surface.not-confirmed"
  /// The surface's parent isn't `main`'s HEAD, so `main` can't fast-forward to it.
  case notOnMain = "plan-surface.not-on-main"
  /// `surface-check` found behaviour in the surface.
  case behaviour = "plan-surface.behaviour"
  /// The gate run id isn't in this checkout's run history.
  case gateUnknown = "plan-surface.gate-unknown"
  /// The gate run is RED or BLOCKED.
  case gateRed = "plan-surface.gate-red"
  /// The gate run ran at another commit than the surface.
  case gateStale = "plan-surface.gate-stale"
  /// The gate run's tier is below the preset's `merge_gate`.
  case gateTier = "plan-surface.gate-tier"
  /// A worktree has `main` checked out, whose files a moved ref would leave behind.
  case mainCheckedOut = "plan-surface.main-checked-out"
  /// The plan already records a surface; a plan has 1.
  case alreadyRecorded = "plan-surface.already-recorded"
}

/// What `plan surface` did to a spec-page plan's surface.
struct PlanSurfaceReport: Sendable, Equatable, Encodable {
  enum Status: String, Sendable, Encodable {
    case recorded
    case refused
    /// The lock is free or another session holds it; nothing was written.
    case notHeld = "not-held"
    case blocked
  }

  var plan: String
  var status: Status = .blocked
  var verdict: Verdict = .blocked
  var rule: PlanSurfaceRule?
  /// The session holding the lock when it isn't the caller.
  var holder: String?
  /// The surface's full sha, once resolved.
  var surfaceCommit: String?
  var gate: String?
  /// The preset's `merge_gate`, once the preset is known.
  var mergeGate: CheckTier?
  var findings: [Finding] = []
  var message = ""

  private enum CodingKeys: String, CodingKey {
    case command, plan, status, verdict, rule, holder, surfaceCommit, gate, mergeGate, findings
    case message
  }

  func encode(to encoder: any Encoder) throws {}
}

/// The checkout and adapters `plan surface` acts on.
struct PlanSurfaceContext: Sendable {
  /// The checkout the command runs in: its run history holds the gate run.
  let root: URL
  let git: any Git
  let branches: any SprintBranches
  let surfaceReader: any SurfaceCommitReading
  /// `.swiftgate.toml`'s `[build.presets]`.
  let presets: [String: BuildPreset]
}

/// The testable core of `plan surface` (fast modes §5.1 step 2, §6).
enum PlanSurfaceRun {
  static let command = "plan surface"

  static func run(
    slug: String, commit: String, gate: String, session: String?, preset: String,
    context: PlanSurfaceContext
  ) async -> PlanSurfaceReport {
    PlanSurfaceReport(plan: slug)
  }

  static func render(_ report: PlanSurfaceReport, format: OutputFormat) -> String {
    ""
  }
}

struct PlanSurfaceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "surface",
    abstract: "Land a spec-page plan's surface commit on main and record it, as its lock holder.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Argument(help: "The surface commit.")
  var commit: String

  @Option(help: "The merge gate run's id, as `check` printed it in this checkout.")
  var gate: String

  @Option(help: "The build preset whose merge_gate the run must reach.")
  var preset: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {}
}
