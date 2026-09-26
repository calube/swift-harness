import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

struct PlanReleaseCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "release",
    abstract: "Remove orchestrator.lock for a plan.",
    discussion:
      "Only the holder releases: exits 0 when released (or not claimed), 1 when another session "
      + "holds the plan, 2 for an invalid plan name, a missing session or no git repository. A "
      + "held lock counts as live until released; --force takes over an abandoned lock, prints "
      + "whose it was, and is run by the user, never by an agent.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Option(help: "The releasing session's id; must match the lock. Not needed with --force.")
  var session: String?

  @Flag(help: "Take over an abandoned lock without checking who holds it.")
  var force = false

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let report = await PlanLockRun.release(slug: slug, session: session, force: force, git: git)
    Console.write(PlanLockRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
