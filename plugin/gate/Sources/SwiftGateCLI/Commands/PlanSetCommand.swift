import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `plan set` did to a plan's `plan.json`.
struct PlanSetReport: Sendable, Equatable, Encodable {
  enum Status: String, Sendable, Encodable {
    case updated
    /// The lock is free or another session holds it; `plan.json` is unchanged.
    case notHeld = "not-held"
    case blocked
  }

  let command: String
  let plan: String
  let status: Status
  let verdict: Verdict
  /// The session holding the lock when it isn't the caller.
  let holder: String?
  let tier: DesignTier?
  let resume: String?
  let message: String
}

/// The testable core of `plan set`: the lock holder's update of the tier and resume note that a
/// re-scope changes.
enum PlanSetRun {
  static func run(
    slug: String, session: String?, tier: String?, resume: String?, git: any Git
  ) async -> PlanSetReport {
    let parsedTier: DesignTier?
    if let tier {
      guard let resolved = DesignTier(rawValue: tier) else {
        return blocked(slug, "--tier `\(tier)` must be \(PlanLockRun.tierList)")
      }
      parsedTier = resolved
    } else {
      parsedTier = nil
    }
    if let resume,
      resume.trimmingCharacters(in: .whitespaces).isEmpty
        || resume.contains(where: \.isNewline)
    {
      return blocked(slug, "--resume must be one non-empty line")
    }
    guard parsedTier != nil || resume != nil else {
      return blocked(slug, "nothing to set: pass --tier, --resume or both")
    }
    guard let session else {
      return blocked(slug, "--session is required: pass the id from the SessionStart context")
    }
    guard PlanLock.isValidSession(session) else {
      return blocked(slug, "--session must be a non-empty id without whitespace")
    }
    let lock: PlanLock
    do {
      let common = try await git.commonDirectory()
      lock = PlanLock(plan: try PlanStateLayout(commonDirectory: common).plan(slug))
    } catch let error as GitError {
      return blocked(slug, "can't find the git common dir: \(error)")
    } catch {
      return blocked(slug, "invalid plan name `\(slug)`: \(error)")
    }
    let holder: String?
    do {
      holder = try lock.holder()
    } catch {
      return blocked(slug, "can't read \(lock.plan.orchestratorLock): \(error)")
    }
    guard let holder, holder == session else {
      return PlanSetReport(
        command: "plan set", plan: slug, status: .notHeld, verdict: .red, holder: holder,
        tier: nil, resume: nil,
        message: holder.map { PlanLockRun.heldByOtherMessage(slug, $0) }
          ?? "plan `\(slug)` isn't claimed; only the session holding its lock updates it. "
          + "Claim it with `swiftgate plan claim \(slug) --session <id>` first.")
    }
    let path = lock.plan.planFile
    let current: PlanFile
    do {
      current = try PlanFileJSON.decode(try Data(contentsOf: URL(filePath: path)))
    } catch {
      return blocked(slug, "\(path) can't be read or decoded, so it was left as it is: \(error)")
    }
    let source: PlanFile.Source
    switch current.source {
    case .design(let design):
      source = .design(
        PlanFile.DesignSource(
          design: design.design, designSha: design.designSha, approval: design.approval,
          clarifyChain: design.clarifyChain, tier: parsedTier ?? design.tier))
    case .specPage(let page):
      guard parsedTier == nil else {
        return blocked(
          slug,
          "plan `\(slug)` is a spec-page plan, which has no design tier; plan.json was left as it is"
        )
      }
      source = .specPage(page)
    case .livePlan(let live):
      guard parsedTier == nil else {
        return blocked(
          slug,
          "plan `\(slug)` is a live plan, which has no design tier; plan.json was left as it is")
      }
      source = .livePlan(live)
    }
    let updated = PlanFile(
      schemaVersion: current.schemaVersion, slug: current.slug, source: source,
      surfaceCommit: current.surfaceCommit, resume: resume ?? current.resume)
    do {
      // Written beside the old file and renamed over it: a reader sees one whole file or the other.
      try PlanFileJSON.encode(updated).write(to: URL(filePath: path), options: .atomic)
    } catch {
      return blocked(slug, "writing \(path): \(error)")
    }
    return PlanSetReport(
      command: "plan set", plan: slug, status: .updated, verdict: .green, holder: nil,
      tier: updated.designSource?.tier, resume: updated.resume,
      message:
        "updated plan `\(slug)`: tier \(updated.designSource?.tier?.rawValue ?? "unset"), resume "
        + "\"\(updated.resume)\"")
  }

  static func render(_ report: PlanSetReport, format: OutputFormat) -> String {
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

  private static func blocked(_ slug: String, _ message: String) -> PlanSetReport {
    PlanSetReport(
      command: "plan set", plan: slug, status: .blocked, verdict: .blocked, holder: nil,
      tier: nil, resume: nil, message: message)
  }
}

struct PlanSetCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set",
    abstract: "Update a plan's tier and resume note in plan.json, as its lock holder.",
    discussion:
      "Rewrites plan.json whole, keeping every other field. Exits 0 when updated, 1 when this "
      + "session doesn't hold the plan's lock, and 2 for a missing or invalid flag, an invalid "
      + "plan name, a missing or malformed plan.json, or no git repository.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @Option(
    help: ArgumentHelp("The design's tier.", discussion: "One of \(PlanLockRun.tierList)."))
  var tier: String?

  @Option(help: "The one-line resume note.")
  var resume: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let report = await PlanSetRun.run(
      slug: slug, session: session, tier: tier, resume: resume, git: git)
    Console.write(PlanSetRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
