import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `plan import` did with a brownfield plan's `PLAN.md`.
struct PlanImportReport: Sendable, Equatable, Encodable {
  enum Status: String, Sendable, Encodable {
    case imported
    /// `PLAN.md` doesn't parse into a schedulable ledger; nothing was written.
    case invalid
    /// The clone, its config or its plan state couldn't be read or written.
    case blocked
  }

  var plan: String
  var status: Status = .blocked
  var verdict: Verdict = .blocked
  var tasks: Int?
  var waves: Int?
  /// Whether this import appended the `PLAN.md` line to `info/exclude`; `nil` before that step.
  var excludeAdded: Bool?
  var assumptions: [String] = []
  var message = ""

  private enum CodingKeys: String, CodingKey {
    case command, plan, status, verdict, tasks, waves, excludeAdded, assumptions, message
  }

  /// Every key is always present; an absent value is `null`.
  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(PlanImportRun.command, forKey: .command)
    try c.encode(plan, forKey: .plan)
    try c.encode(status, forKey: .status)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(tasks, forKey: .tasks)
    try c.encode(waves, forKey: .waves)
    try c.encode(excludeAdded, forKey: .excludeAdded)
    try c.encode(assumptions, forKey: .assumptions)
    try c.encode(message, forKey: .message)
  }
}

/// `plan import`'s behaviour, apart from argument parsing so tests drive it against a temp clone.
enum PlanImportRun {
  static let command = "plan import"

  /// Reads `<common>/swift-harness/plans/<slug>/PLAN.md`, writes `ledger.json` and `plan.json`
  /// beside it, links `<root>/PLAN.md` to it and excludes that link once.
  static func run(slug: String, root: URL, git: any Git) async -> PlanImportReport {
    PlanImportReport(plan: slug, message: "\(command): not implemented yet")
  }

  static func render(_ report: PlanImportReport, json: Bool) -> String {
    report.message
  }
}

/// `swiftgate plan import <slug>`: derives a brownfield plan's ledger and plan file from its
/// `PLAN.md`.
struct PlanImportCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "import",
    abstract: "Write a brownfield plan's ledger.json and plan.json from its PLAN.md.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    try StubCommand.notImplemented("plan import", json: json)
  }
}
