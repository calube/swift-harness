import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// What `gc` removed, and what it could not.
struct GCSummary: Sendable, Equatable, Encodable {
  var removed: [String] = []
  var orphanClones: [String] = []
  /// Runs whose holder had died: session closed, lease removed, claims released.
  var releasedLeases: [String] = []
  /// What a sweep skipped without failing, such as an unreadable lease.
  var notes: [String] = []
  var errors: [String] = []
  /// Sealed segments, indexes and rollups removed by `--events`, relative to the root.
  var removedEvents: [String] = []
}

/// `gc`: prunes this worktree's stale DerivedData and run directories and deletes simulator
/// clones whose owning process died (spec §4.4), releasing `agent-device`'s stale claims on each.
/// Before the clones, it frees each lease a dead `sim hold` left: its session, claims and file.
/// Only paths under the state root are ever removed.
enum GCRun {
  /// - Parameter eventsOlderThanDays: `nil` leaves every event file; a count removes each sealed
  ///   segment whose index's last time is older.
  /// - Parameter sweepLeases: runs before `sweepOrphans`, so a lease's session is closed while
  ///   its device still exists.
  static func run(
    root: URL, maxAgeDays: Int, eventsOlderThanDays: Int? = nil, now: Date,
    sweepLeases: () async -> SimLeaseSweep = { SimLeaseSweep() },
    sweepOrphans: () async throws -> [String]
  ) async -> GCSummary {
    var summary = GCSummary()
    let state = StateRootResolver.resolve(worktree: root)
    let entries =
      HarnessFiles.agedEntries(root: state.directory, directory: RunLayout.derivedDataDirectory)
      + HarnessFiles.agedEntries(
        root: state.directory, directory: RunLayout.runsDirectory,
        excluding: [URL(filePath: RunLayout.historyFile).lastPathComponent])
    for path in HarnessGC.expired(entries, now: now, maxAgeDays: maxAgeDays) {
      do {
        try FileManager.default.removeItem(at: state.url(path))
        summary.removed.append(state.displayPath(path))
      } catch {
        summary.errors.append("\(state.displayPath(path)): \(error.localizedDescription)")
      }
    }
    if let days = eventsOlderThanDays {
      removeSealedEvents(
        root: root, before: now.addingTimeInterval(-Double(days) * 86_400), into: &summary)
    }
    let leases = await sweepLeases()
    summary.releasedLeases = leases.released
    summary.errors += leases.problems
    summary.notes += leases.notes
    do {
      summary.orphanClones = try await sweepOrphans()
    } catch {
      summary.errors.append("orphan clones: \(error)")
    }
    return summary
  }

  /// Removes each sealed segment, with its index and rollup, whose index's last time is before
  /// `cutoff`, in the state root's `events/` and every imported or unkept store below it. Never an active file, and never
  /// a segment without an index, whose age isn't known. The index goes last, so a gc stopped
  /// halfway leaves it for the next to finish.
  private static func removeSealedEvents(
    root: URL, before cutoff: Date, into summary: inout GCSummary
  ) {
    let files = LiveEventStoreFiles(root: root)
    let state = files.state
    func listed(_ directory: String) -> [String] {
      do throws(EventStoreFileError) {
        return try files.list(directory).filter { !$0.hasPrefix(".") }
      } catch {
        summary.errors.append("\(error)")
        return []
      }
    }
    let stores =
      [RunLayout.eventsDirectory]
      + [EventCopyUp.importedDirectory, EventCopyUp.unkeptDirectory].flatMap { parent in
        listed(parent).map { "\(parent)/\($0)" }
      }
    for store in stores {
      for stream in listed("\(store)/sealed") {
        let directory = "\(store)/sealed/\(stream)"
        for name in listed(directory) {
          guard case .index(let sequence) = EventSegmentLayout.file(named: name) else { continue }
          let indexPath = "\(directory)/\(name)"
          let index: EventSegmentIndex
          do {
            guard let data = try files.read(indexPath) else { continue }
            index = try EventSegmentIndex.decode(data)
          } catch {
            summary.errors.append("\(state.displayPath(indexPath)): \(error)")
            continue
          }
          guard index.lastTime < cutoff else { continue }
          for path in [
            EventSegmentLayout.plainName(sequence), EventSegmentLayout.compressedName(sequence),
            "\(sequence).rollup.json", name,
          ].map({ "\(directory)/\($0)" }) {
            do {
              try FileManager.default.removeItem(at: state.url(path))
              summary.removedEvents.append(state.displayPath(path))
            } catch CocoaError.fileNoSuchFile {
              continue
            } catch {
              summary.errors.append("\(state.displayPath(path)): \(error.localizedDescription)")
            }
          }
        }
      }
    }
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
          + "\(summary.orphanClones.count) orphan clone(s), "
          + "\(summary.releasedLeases.count) dead holder lease(s)"
      ]
      lines += summary.removed.map { "  removed \($0)" }
      lines += summary.removedEvents.map { "  removed event file \($0)" }
      lines += summary.orphanClones.map { "  deleted clone \($0)" }
      lines += summary.releasedLeases.map {
        "  released run \($0): session closed, lease removed, claims released"
      }
      lines += summary.notes.map { "  note: \($0)" }
      lines += summary.errors.map { "  error: \($0)" }
      return lines.joined(separator: "\n")
    }
  }
}

struct GCCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "gc",
    abstract: "Prune stale per-worktree DerivedData and runs, and orphaned simulator clones.",
    discussion:
      "Events are touched only with --events --older-than <days>, which removes sealed segments "
      + "by their index's last time. Exits 0, or 2 when anything couldn't be removed or read.")

  @Option(help: "Remove entries untouched for more than this many days.")
  var days = 7

  @Flag(
    help: ArgumentHelp(
      "Also remove sealed event segments, their indexes and rollups whose last event is older "
        + "than --older-than days, here and in every imported or unkept store. Never an active file."
    ))
  var events = false

  @Option(
    name: .customLong("older-than"),
    help: "With --events: the age in days, by the index's last time."
  )
  var olderThan: Int?

  @OptionGroup var output: OutputOptions

  func validate() throws {
    guard days >= 1 else { throw ValidationError("--days must be at least 1") }
    guard events == (olderThan != nil) else {
      throw ValidationError("--events and --older-than <days> go together")
    }
    if let olderThan, olderThan < 1 {
      throw ValidationError("--older-than must be at least 1")
    }
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    // The sweep reads only clone names, so the simulator pin is irrelevant; without a config the
    // default slot count is as good as any.
    let simulator =
      (try? ConfigLoader().load(repositoryRoot: root))??.simulator
      ?? SimulatorConfig(device: "-", os: "-")
    let runner = LiveProcessRunner()
    let claimFailures = Mutex<[String]>([])
    let clones = SimulatorClones.live(
      config: simulator, runner: runner,
      releaseClaims: SimulatorClones.agentDeviceClaimRelease(LiveAgentDevice(runner: runner)) {
        failure in claimFailures.withLock { $0.append(failure) }
      })
    let down = SimDown.live(runner: runner)
    var summary = await GCRun.run(
      root: root, maxAgeDays: days, eventsOlderThanDays: events ? olderThan : nil, now: Date(),
      sweepLeases: { await down.sweepDeadHolders(simDirectory: SimDown.simDirectory(for:)) },
      sweepOrphans: { try await clones.sweepOrphans() })
    summary.errors += claimFailures.withLock { $0 }
    Console.write(try GCRun.render(summary, format: output.format, maxAgeDays: days))
    if !summary.errors.isEmpty { throw ExitCode(Verdict.blocked.exitCode) }
  }
}
