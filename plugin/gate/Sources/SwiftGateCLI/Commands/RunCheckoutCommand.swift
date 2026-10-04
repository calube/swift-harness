import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `run checkout create` and `remove`: the brownfield plan branch's own checkout, where the run's
/// contract commit lands and its gates run.
enum RunCheckoutRun {
  static func create(slug: String, session: String?, root: URL, runner: any ProcessRunner)
    async -> WorktreeReport
  {
    notBuilt("run checkout create", slug: slug)
  }

  static func remove(slug: String, session: String?, root: URL, runner: any ProcessRunner)
    async -> WorktreeReport
  {
    notBuilt("run checkout remove", slug: slug)
  }

  private static func notBuilt(_ command: String, slug: String) -> WorktreeReport {
    WorktreeReport(
      command: command, plan: slug, task: nil, status: .blocked, verdict: .blocked, holder: nil,
      worktree: nil, branch: nil, cloned: nil, missing: nil, message: "\(command) isn't built yet")
  }
}

struct RunCheckoutCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "checkout",
    abstract: "Create or remove a brownfield plan's checkout of its plan branch.",
    subcommands: [RunCheckoutCreateCommand.self, RunCheckoutRemoveCommand.self])
}

struct RunCheckoutCreateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Check out a brownfield plan's branch in the plan's own checkout.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let report = await RunCheckoutRun.create(
      slug: plan, session: session, root: root, runner: LiveProcessRunner())
    Console.write(WorktreeRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

struct RunCheckoutRemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Remove a brownfield plan's checkout, keeping its gate reports.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let report = await RunCheckoutRun.remove(
      slug: plan, session: session, root: root, runner: LiveProcessRunner())
    Console.write(WorktreeRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
