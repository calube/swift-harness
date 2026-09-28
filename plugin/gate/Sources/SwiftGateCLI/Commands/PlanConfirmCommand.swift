import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Why `plan confirm` refused a page it could read. Each is exit 1.
enum PlanConfirmRule: String, Sendable, Equatable, CaseIterable {
  /// `spec-page check` found a major problem with the page.
  case pageRed = "plan-confirm.page-red"
  /// `--by spec-quotes` on a page the check says the user must confirm.
  case needsUser = "plan-confirm.needs-user"
}

/// What `plan confirm` did to a spec-page plan's confirmation.
struct PlanConfirmReport: Sendable, Equatable, Encodable {
  enum Status: String, Sendable, Encodable {
    case confirmed
    case refused
    /// The lock is free or another session holds it; nothing was written.
    case notHeld = "not-held"
    case blocked
  }

  var plan: String
  var status: Status = .blocked
  var verdict: Verdict = .blocked
  var rule: PlanConfirmRule?
  /// The session holding the lock when it isn't the caller.
  var holder: String?
  var by: PlanFile.PageApprover?
  var confirm: SpecPageCheck.Confirm?
  var pageSha: String?
  var findings: [Finding] = []
  var message = ""

  func encode(to encoder: any Encoder) throws {}
}

/// The testable core of `plan confirm`: the lock holder's confirmation of a spec page.
enum PlanConfirmRun {
  static let command = "plan confirm"

  static func run(
    slug: String, session: String?, by: String, specPath: String, git: any Git,
    now: Date = Date()
  ) async -> PlanConfirmReport {
    PlanConfirmReport(plan: slug)
  }

  static func render(_ report: PlanConfirmReport, format: OutputFormat) -> String {
    ""
  }
}

struct PlanConfirmCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "confirm",
    abstract: "Confirm a spec-page plan's page, as its lock holder.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Option(help: "Who confirms the page: user or spec-quotes.")
  var by: String

  @Option(help: "The spec file the page quotes.")
  var spec: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {}
}
