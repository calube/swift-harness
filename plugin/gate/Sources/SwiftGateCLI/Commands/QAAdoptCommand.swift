import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `qa adopt` did with a worktree's prepared checks.
struct QAAdoptReport: Sendable, Equatable, Encodable {
  /// 1 plan's `qa/` folder copied into plan state.
  struct Adopted: Sendable, Equatable, Encodable {
    var plan: String
    var files: Int
    var destination: String
  }

  var worktree: String
  var verdict: Verdict = .blocked
  var adopted: [Adopted] = []
  var message = ""

  private enum CodingKeys: String, CodingKey {
    case command, worktree, verdict, adopted, message
  }

  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(QAAdoptRun.command, forKey: .command)
    try c.encode(worktree, forKey: .worktree)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(adopted, forKey: .adopted)
    try c.encode(message, forKey: .message)
  }
}

/// `qa adopt`'s behaviour, apart from argument parsing so tests drive it against a temp repository.
enum QAAdoptRun {
  static let command = "qa adopt"
  /// Where a validation worker leaves its checks in its worktree, 1 folder per plan.
  static let preparedDirectory = ".harness/qa"

  static func run(worktree: String, root: URL, git: any Git, runner: any ProcessRunner) async
    -> QAAdoptReport
  {
    QAAdoptReport(worktree: worktree, message: "not implemented yet")
  }

  static func render(_ report: QAAdoptReport, json: Bool) -> String {
    guard json else { return "\(command): \(report.verdict.rawValue) \(report.message)" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
  }
}

/// `swiftgate qa adopt <worktree> [--json]`.
struct QAAdoptCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "adopt",
    abstract: "Copy a validation worktree's .harness/qa/<plan>/ into that plan's state as qa/.")

  @Argument(help: "A checkout of this repository holding .harness/qa/<plan>/.")
  var worktree: String

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    try StubCommand.notImplemented(QAAdoptRun.command, json: json)
  }
}
