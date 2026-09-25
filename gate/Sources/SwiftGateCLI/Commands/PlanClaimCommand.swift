import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `plan claim` or `plan release` did to a plan's lock.
struct PlanLockReport: Sendable, Equatable, Encodable {
  enum Status: String, Sendable, Encodable {
    case claimed
    case alreadyHeld = "already-held"
    case heldByOther = "held-by-other"
    case released
    case notClaimed = "not-claimed"
    case forceReleased = "force-released"
    case blocked
  }

  let command: String
  let plan: String
  let status: Status
  let verdict: Verdict
  /// The lock's holder when another session holds it, or the session a forced release overrode.
  let holder: String?
  let lockFile: String?
  let message: String
}

enum PlanLockRun {
  static func claim(
    slug: String, session: String?, design: String? = nil, tier: String? = nil, git: any Git
  ) async -> PlanLockReport {
    let command = "plan claim"
    if let design, !PlanFile.isValidDesignPath(design) {
      return blocked(
        command, slug,
        "--design `\(design)` must be a repo-relative docs/**/designs/<name>.md path without `..`")
    }
    if let tier, !PlanFile.tiers.contains(tier) {
      return blocked(command, slug, "--tier `\(tier)` must be quick, standard or deep")
    }
    let lock: PlanLock
    switch await locate(slug, session: session, requireSession: true, git: git) {
    case .failure(let message): return blocked(command, slug, message)
    case .success(let located): lock = located
    }
    if design == nil, !lock.hasPlanFile {
      return blocked(
        command, slug,
        "`\(slug)` is a new plan: --design is required, so the edit guard can tie the design doc "
          + "to it")
    }
    let file = lock.plan.orchestratorLock
    let outcome: PlanLock.ClaimOutcome
    do {
      outcome = try lock.claim(session: session ?? "")
    } catch {
      return blocked(command, slug, describe(error))
    }
    switch outcome {
    case .heldByOther(let holder):
      return report(
        command, slug, .heldByOther, .red, holder, file,
        "plan `\(slug)` is held by session \(holder); it stays live until that session runs "
          + "`swiftgate plan release`, or the user runs `swiftgate plan release \(slug) --force`")
    case .claimed, .alreadyHeld:
      var seeded = ""
      if let design, !lock.hasPlanFile {
        do {
          let data = try PlanFileJSON.encode(PlanFile.seed(slug: slug, design: design, tier: tier))
          if try lock.seedPlanFile(data) { seeded = "; seeded plan.json for \(design)" }
        } catch let error as PlanLockError {
          return blocked(command, slug, "claimed, but seeding plan.json failed: \(describe(error))")
        } catch {
          return blocked(command, slug, "claimed, but encoding plan.json failed: \(error)")
        }
      }
      return outcome == .claimed
        ? report(command, slug, .claimed, .green, nil, file, "claimed plan `\(slug)`" + seeded)
        : report(
          command, slug, .alreadyHeld, .green, nil, file,
          "plan `\(slug)` is already held by this session" + seeded)
    }
  }

  static func release(slug: String, session: String?, force: Bool, git: any Git) async
    -> PlanLockReport
  {
    let command = "plan release"
    let lock: PlanLock
    switch await locate(slug, session: session, requireSession: !force, git: git) {
    case .failure(let message): return blocked(command, slug, message)
    case .success(let located): lock = located
    }
    let file = lock.plan.orchestratorLock
    do {
      if force {
        switch try lock.forceRelease() {
        case .overrode(let holder):
          return report(
            command, slug, .forceReleased, .green, holder, file,
            "force-released plan `\(slug)`: overrode the lock held by session \(holder)")
        case .notClaimed:
          return report(
            command, slug, .notClaimed, .green, nil, file,
            "plan `\(slug)` is not claimed; nothing to release")
        }
      }
      switch try lock.release(session: session ?? "") {
      case .released:
        return report(command, slug, .released, .green, nil, file, "released plan `\(slug)`")
      case .notClaimed:
        return report(
          command, slug, .notClaimed, .green, nil, file,
          "plan `\(slug)` is not claimed; nothing to release")
      case .heldByOther(let holder):
        return report(
          command, slug, .heldByOther, .red, holder, file,
          "plan `\(slug)` is held by session \(holder), not this one; only the user takes it over, "
            + "with `swiftgate plan release \(slug) --force`")
      }
    } catch {
      return blocked(command, slug, describe(error))
    }
  }

  static func render(_ report: PlanLockReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = (try? encoder.encode(report)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    case .human:
      return "\(report.command): \(report.verdict.rawValue) \(report.message)"
    }
  }

  /// Validates the inputs and places the plan under the git common dir, so every worktree of
  /// the repository contends for the same lock.
  private static func locate(
    _ slug: String, session: String?, requireSession: Bool, git: any Git
  ) async -> Result<PlanLock, LocateFailure> {
    if let session, !PlanLock.isValidSession(session) {
      return .failure(LocateFailure("--session must be a non-empty id without whitespace"))
    }
    if requireSession, session == nil {
      return .failure(
        LocateFailure("--session is required: pass the id from the SessionStart context"))
    }
    let common: String
    do {
      common = try await git.commonDirectory()
    } catch {
      return .failure(LocateFailure("can't find the git common dir: \(error)"))
    }
    do {
      return .success(PlanLock(plan: try PlanStateLayout(commonDirectory: common).plan(slug)))
    } catch {
      return .failure(LocateFailure("invalid plan name `\(slug)`: \(error)"))
    }
  }

  private struct LocateFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  private static func describe(_ error: PlanLockError) -> String {
    switch error {
    case .invalidSession(let session): "invalid session id `\(session)`"
    case .io(let detail): detail
    }
  }

  private static func blocked(
    _ command: String, _ slug: String, _ failure: LocateFailure
  ) -> PlanLockReport {
    blocked(command, slug, failure.message)
  }

  private static func blocked(_ command: String, _ slug: String, _ message: String)
    -> PlanLockReport
  {
    report(command, slug, .blocked, .blocked, nil, nil, message)
  }

  private static func report(
    _ command: String, _ slug: String, _ status: PlanLockReport.Status, _ verdict: Verdict,
    _ holder: String?, _ lockFile: String?, _ message: String
  ) -> PlanLockReport {
    PlanLockReport(
      command: command, plan: slug, status: status, verdict: verdict, holder: holder,
      lockFile: lockFile, message: message)
  }
}

struct PlanClaimCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claim",
    abstract: "Create the plan directory under the git common dir and write orchestrator.lock.",
    discussion:
      "Exits 0 when this session now holds the plan (or already did), 1 when another session "
      + "holds it, and 2 for an invalid plan name, a missing session or no git repository.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Option(help: "The session id to record as the lock holder (from the SessionStart context).")
  var session: String?

  @Option(
    help: ArgumentHelp(
      "The design doc, repo-relative under a docs/**/designs/ directory. Required to claim a "
        + "new plan: it seeds plan.json, which is how the edit guard ties the doc to this plan."))
  var design: String?

  @Option(help: "The design's tier, recorded in a seeded plan.json: quick, standard or deep.")
  var tier: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let report = await PlanLockRun.claim(
      slug: slug, session: session, design: design, tier: tier, git: git)
    Console.write(PlanLockRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
