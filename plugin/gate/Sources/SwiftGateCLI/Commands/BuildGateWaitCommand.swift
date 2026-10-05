import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `build gate-wait` saw of a gate running in the background, and what to do next.
struct BuildGateWaitReport: Sendable, Equatable, Encodable {
  let command: String
  let plan: String
  let runId: String
  let tier: String
  /// The gate's JSON output file, as given.
  let output: String
  let action: GateWatchAction
  /// When the gate's output file was created: when its shell redirect launched it.
  let startedAt: Date
  let elapsedSeconds: Int
  let deadlineAt: Date
  let secondsToDeadline: Int
  let budget: GateBudget
  /// The gate's own verdict and run id, once ``action`` is `read`.
  let gateVerdict: Verdict?
  let gateRunId: String?
  let message: String
}

/// `build gate-wait`: watches the JSON file a background gate writes, for at most `maxWait`
/// seconds, and says whether to read it, wait again, stop it as overrun, or run the cutoff.
enum BuildGateWaitRun {
  static let command = "build gate-wait"
  /// The longest 1 call waits, under the Bash tool's 600 s timeout.
  static let maxWaitLimit = 540
  static let defaultMaxWait = 120
  static let pollSeconds = 5

  static func run(
    slug: String, tier: CheckTier, output: URL, maxWait: Int, git: any Git,
    clock: any BuildClock, events: @Sendable () -> [HarnessEvent],
    sleep: @Sendable (Int) async -> Void
  ) async -> BuildLoopResult<BuildGateWaitReport> {
    guard (0...maxWaitLimit).contains(maxWait) else {
      return .blocked(command, slug, "--max-wait must be 0 to \(maxWaitLimit) seconds")
    }
    let store: BuildRunStore
    let record: BuildRunRecord
    do throws(BuildRunStoreError) {
      guard let latest = try await BuildRunStore.latest(plan: slug, git: git) else {
        return .blocked(command, slug, "plan `\(slug)` has no build run")
      }
      store = latest
      record = try store.record()
    } catch {
      return .blocked(command, slug, "reading plan `\(slug)`'s build run: \(error)")
    }
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
      let startedAt = attributes[.creationDate] as? Date
    else {
      return .blocked(
        command, slug,
        "no gate output at \(output.path): launch the gate with its JSON redirected there first")
    }
    let budget = GateBudget.estimate(tier: tier, events: events())
    let cutoffFile = store.layout.directory + "/" + CutoffRecord.fileName
    var waited = 0
    while true {
      let verdict = finishedGate(output)
      let watch = GateWatch.decide(
        finished: verdict != nil, startedAt: startedAt, now: clock.now(), budget: budget,
        timeBox: record.timeBox,
        cutoffDecided: FileManager.default.fileExists(atPath: cutoffFile))
      if watch.action != .wait || waited >= maxWait {
        return BuildLoopResult(
          command: command, plan: slug, verdict: .green,
          report: BuildGateWaitReport(
            command: command, plan: slug, runId: record.runID, tier: tier.rawValue,
            output: output.path, action: watch.action, startedAt: startedAt,
            elapsedSeconds: watch.elapsedSeconds, deadlineAt: watch.deadlineAt,
            secondsToDeadline: watch.secondsToDeadline, budget: budget,
            gateVerdict: verdict?.verdict, gateRunId: verdict?.runID, message: watch.reason),
          holder: nil, message: watch.reason)
      }
      let step = max(1, min(pollSeconds, maxWait - waited, watch.secondsToDeadline))
      await sleep(step)
      waited += step
    }
  }

  private struct GateOutput: Decodable {
    let verdict: Verdict
    let runID: String?
  }

  /// The gate's verdict once its whole JSON is in the file; `nil` while it is empty or partial.
  private static func finishedGate(_ output: URL) -> GateOutput? {
    guard let data = try? Data(contentsOf: output), !data.isEmpty else { return nil }
    return try? JSONDecoder().decode(GateOutput.self, from: data)
  }

  static func render(_ result: BuildLoopResult<BuildGateWaitReport>, format: OutputFormat)
    -> String
  {
    BuildLoop.render(result, format: format) { report in
      "build gate-wait: \(report.tier) gate \(report.action.rawValue) after "
        + "\(report.elapsedSeconds) s, expected \(report.budget.expectedSeconds) s, "
        + "\(report.secondsToDeadline) s to its deadline: \(report.message)"
    }
  }
}

struct BuildGateWaitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "gate-wait",
    abstract: "Watch a gate running in the background and say what to do next.",
    discussion:
      "Reads the JSON file a background `check` writes. Its creation time is the gate's start. "
      + "The expected time comes from the tier's recent gate runs in the event store, else "
      + "from the warm-up's build and test times. The gate overruns at 3 times that, or "
      + "earlier when the time box needs the time for final and the report. Waits up to "
      + "--max-wait seconds, then prints `action`: `read` (the verdict is in), `wait` (call "
      + "again), `overrun` (stop the gate and treat it as RED) or `cutoff` (run `build "
      + "cutoff` first). Writes nothing. Exits 0 with the report, and 2 for a missing output "
      + "file, no build run, or a --max-wait outside 0 to 540.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The gate's tier: merge or final.")
  var tier: CheckTier

  @Option(help: "The file the gate's --json output is redirected to.")
  var output: String

  @Option(name: .customLong("max-wait"), help: "Seconds to wait for a decision, 0 to 540.")
  var maxWait: Int = BuildGateWaitRun.defaultMaxWait

  @OptionGroup var outputFormat: OutputOptions

  func run() async throws {
    let directory = URL(
      filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let result = await BuildGateWaitRun.run(
      slug: plan, tier: tier, output: URL(filePath: output, relativeTo: directory),
      maxWait: maxWait, git: BuildLoop.git(), clock: LiveBuildClock(),
      events: {
        EventStoreReader(files: LiveEventStoreFiles(root: directory))
          .read(EventQuery(kinds: [.gateRun, .gateStep, .warmupRun])).events.map(\.event)
      },
      sleep: { seconds in try? await Task.sleep(for: .seconds(seconds)) })
    Console.write(BuildGateWaitRun.render(result, format: outputFormat.format))
    try BuildLoop.exit(result)
  }
}
