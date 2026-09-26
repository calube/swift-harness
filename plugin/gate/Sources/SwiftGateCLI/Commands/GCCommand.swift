import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `gc` removed, and what it could not.
struct GCSummary: Sendable, Equatable, Encodable {
  var removed: [String] = []
  var orphanClones: [String] = []
  var errors: [String] = []
}

/// `gc`: prunes this worktree's stale DerivedData and run directories and deletes simulator
/// clones whose owning process died (spec §4.4). Only paths under `.harness/` are ever removed.
enum GCRun {
  static func run(
    root: URL, maxAgeDays: Int, now: Date, sweepOrphans: () async throws -> [String]
  ) async -> GCSummary {
    var summary = GCSummary()
    let entries =
      HarnessFiles.agedEntries(root: root, directory: HarnessGC.derivedDataDirectory)
      + HarnessFiles.agedEntries(
        root: root, directory: RunLayout.runsDirectory,
        excluding: [URL(filePath: RunLayout.historyFile).lastPathComponent])
    for path in HarnessGC.expired(entries, now: now, maxAgeDays: maxAgeDays) {
      do {
        try FileManager.default.removeItem(at: root.appending(path: path))
        summary.removed.append(path)
      } catch {
        summary.errors.append("\(path): \(error.localizedDescription)")
      }
    }
    do {
      summary.orphanClones = try await sweepOrphans()
    } catch {
      summary.errors.append("orphan clones: \(error)")
    }
    return summary
  }

  static func render(_ summary: GCSummary, format: OutputFormat, maxAgeDays: Int) throws -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      return String(decoding: try encoder.encode(summary), as: UTF8.self)
    case .human:
      var lines = [
        "gc: removed \(summary.removed.count) item(s) older than \(maxAgeDays) day(s), "
          + "\(summary.orphanClones.count) orphan clone(s)"
      ]
      lines += summary.removed.map { "  removed \($0)" }
      lines += summary.orphanClones.map { "  deleted clone \($0)" }
      lines += summary.errors.map { "  error: \($0)" }
      return lines.joined(separator: "\n")
    }
  }
}

struct GCCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "gc",
    abstract: "Prune stale per-worktree DerivedData and runs, and orphaned simulator clones.")

  @Option(help: "Remove entries untouched for more than this many days.")
  var days = 7

  @OptionGroup var output: OutputOptions

  func validate() throws {
    guard days >= 1 else { throw ValidationError("--days must be at least 1") }
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    // The sweep reads only clone names, so the simulator pin is irrelevant; without a config the
    // default slot count is as good as any.
    let simulator =
      (try? ConfigLoader().load(repositoryRoot: root))??.simulator
      ?? SimulatorConfig(device: "-", os: "-")
    let clones = SimulatorClones.live(config: simulator, runner: LiveProcessRunner())
    let summary = await GCRun.run(root: root, maxAgeDays: days, now: Date()) {
      try await clones.sweepOrphans()
    }
    Console.write(try GCRun.render(summary, format: output.format, maxAgeDays: days))
    if !summary.errors.isEmpty { throw ExitCode(Verdict.blocked.exitCode) }
  }
}
