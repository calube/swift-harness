import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Where a `swiftgate run` stands in its time box.
struct RunClockReport: Sendable, Equatable, Encodable {
  let command: String
  let plan: String
  let startedAt: Date
  let now: Date
  let elapsedSeconds: Int
  let budgetMin: Int
  let source: TimeBoxSource
  let phase: BudgetPhase
  let deadlines: RunTimeBox.Deadlines
  /// The first deadline not yet passed, and the whole seconds left to it; `nil` once the box has
  /// ended.
  let next: Next?

  struct Next: Sendable, Equatable, Encodable {
    let deadline: String
    let secondsLeft: Int
  }
}

/// `run clock`'s behaviour, apart from argument parsing so tests drive it against a temp clone.
enum RunClockRun {
  static let command = "run clock"

  /// The outcome: the report, or the message and exit status of a refusal.
  enum Outcome: Sendable, Equatable {
    case report(RunClockReport)
    case refused(message: String, status: Int32)
  }

  /// The deadlines `--wait-until` takes, by their `deadlines` key.
  static let deadlineNames = [
    "exploreBy", "planBy", "contractBy", "noNewStartsAt", "cutoffAt", "endsAt",
  ]

  /// The longest 1 sleep of `--wait-until`: the clock is read again after each, since a
  /// measured `final` brings the cutoff earlier.
  static let waitStep: Duration = .seconds(30)

  /// ``run(slug:root:runner:now:)`` once `deadline` has passed, read after sleeps of at most
  /// ``waitStep``; a refusal, or an unknown deadline, returns at once.
  static func wait(
    until deadline: String, slug: String, root: URL, runner: any ProcessRunner,
    now: @Sendable () -> Date, sleep: @Sendable (Duration) async throws -> Void
  ) async -> Outcome {
    guard deadlineNames.contains(deadline) else {
      return .refused(
        message: "--wait-until \(deadline) is not 1 of \(deadlineNames.joined(separator: ", "))",
        status: 2)
    }
    while true {
      let outcome = await run(slug: slug, root: root, runner: runner, now: now())
      guard case .report(let report) = outcome else { return outcome }
      let left = date(of: deadline, in: report.deadlines).timeIntervalSince(report.now)
      if left <= 0 { return outcome }
      let step = min(Duration.milliseconds(Int64((left * 1000).rounded(.up))), waitStep)
      do {
        try await sleep(step)
      } catch {
        return outcome
      }
    }
  }

  private static func date(of deadline: String, in deadlines: RunTimeBox.Deadlines) -> Date {
    switch deadline {
    case "exploreBy": deadlines.exploreBy
    case "planBy": deadlines.planBy
    case "contractBy": deadlines.contractBy
    case "noNewStartsAt": deadlines.noNewStartsAt
    case "cutoffAt": deadlines.cutoffAt
    default: deadlines.endsAt
    }
  }

  static func run(slug: String, root: URL, runner: any ProcessRunner, now: Date) async -> Outcome {
    let layout: BrownfieldStateLayout
    do {
      layout = try await GitTrackedTree(runner: runner, directory: root).stateLayout()
    } catch {
      return .refused(message: "resolving the clone's git dirs: \(error.message)", status: 2)
    }
    let path = layout.plan(slug: slug).appending(path: RunClock.fileName)
    let clock: RunClock
    do {
      clock = try RunClock.decode(Data(contentsOf: path))
    } catch CocoaError.fileReadNoSuchFile {
      return .refused(
        message: "plan `\(slug)` has no \(path.path): no `swiftgate run` launched it", status: 2)
    } catch {
      return .refused(message: "\(path.path) doesn't decode: \(error)", status: 2)
    }
    guard let launched = clock.runTimeBox else {
      return .refused(
        message: "\(path.path) has no time box: its run started before runs had one", status: 2)
    }
    // The clone's measured `final` grows the reserve, so the cutoff comes earlier.
    let box = RunTimeBox(
      startedAt: launched.startedAt,
      limits: launched.limits.holding(finalSeconds: MeasuredFinalGateReader.seconds(worktree: root))
    )
    let deadlines = box.deadlines
    let named: [(String, Date)] = [
      ("exploreBy", deadlines.exploreBy), ("planBy", deadlines.planBy),
      ("contractBy", deadlines.contractBy), ("noNewStartsAt", deadlines.noNewStartsAt),
      ("cutoffAt", deadlines.cutoffAt), ("endsAt", deadlines.endsAt),
    ]
    let next = named.first { $0.1 > now }.map {
      RunClockReport.Next(
        deadline: $0.0, secondsLeft: Int($0.1.timeIntervalSince(now).rounded(.up)))
    }
    return .report(
      RunClockReport(
        command: command, plan: slug, startedAt: box.startedAt, now: now,
        elapsedSeconds: max(0, Int(now.timeIntervalSince(box.startedAt).rounded(.down))),
        budgetMin: box.limits.budgetMin, source: box.limits.source, phase: box.phase(at: now),
        deadlines: deadlines, next: next))
  }

  static func render(_ outcome: Outcome, json: Bool) -> String {
    switch outcome {
    case .refused(let message, _): return "\(command): \(message)"
    case .report(let report):
      guard json else {
        let next =
          report.next.map { "; \($0.deadline) in \($0.secondsLeft) s" } ?? "; the box has ended"
        return "\(command): \(report.plan) \(report.elapsedSeconds) s of \(report.budgetMin) min, "
          + "phase \(report.phase.rawValue)\(next)"
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      encoder.dateEncodingStrategy = .iso8601
      return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
    }
  }
}

/// `swiftgate run clock <slug>`: the run's time box, its deadlines and the time left to each.
struct RunClockCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "clock",
    abstract: "Print where a brownfield run stands in its time box.",
    discussion:
      "Reads the plan's clock.json, which `swiftgate run` wrote at launch. With --wait-until it "
      + "reports only once that deadline has passed. Exits 0 with the report, and 2 for a plan "
      + "with no clock, a clock with no time box, or a deadline --wait-until doesn't know.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Option(
    help: ArgumentHelp(
      "Return only once this deadline has passed: exploreBy, planBy, contractBy, noNewStartsAt, "
        + "cutoffAt or endsAt. Run it in the background so its exit wakes you at that deadline."))
  var waitUntil: String?

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let outcome: RunClockRun.Outcome
    if let waitUntil {
      outcome = await RunClockRun.wait(
        until: waitUntil, slug: slug, root: root, runner: LiveProcessRunner(), now: { Date() },
        sleep: { try await Task.sleep(for: $0) })
    } else {
      outcome = await RunClockRun.run(
        slug: slug, root: root, runner: LiveProcessRunner(), now: Date())
    }
    Console.write(RunClockRun.render(outcome, json: json))
    if case .refused(_, let status) = outcome { throw ExitCode(status) }
  }
}
