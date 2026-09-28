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
    /// A new plan named a design doc another plan's `plan.json` already names.
    case designOwned = "design-owned"
    case blocked
  }

  let command: String
  let plan: String
  let status: Status
  let verdict: Verdict
  /// The lock's holder when another session holds it, or the session a forced release overrode.
  let holder: String?
  /// The plan that already owns the design a refused claim named.
  let owner: String?
  let lockFile: String?
  let message: String
}

enum PlanLockRun {
  /// The accepted `--tier` values, listed from ``DesignTier``'s own cases so a tier the shared
  /// type gains never drifts out of sync with the message naming it.
  static var tierList: String {
    let names = DesignTier.allCases.map(\.rawValue)
    guard let last = names.last else { return "" }
    return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " or " + last
  }

  /// - Parameter root: the directory the command runs in. Design paths are compared after
  ///   resolving them against its worktree toplevel, so a symlinked alias names the same doc;
  ///   `nil` compares them as spelled.
  static func claim(
    slug: String, session: String?, design: String? = nil, specPage: Bool = false,
    tier: String? = nil, root: URL? = nil, git: any Git
  ) async -> PlanLockReport {
    let command = "plan claim"
    if specPage, design != nil || tier != nil {
      return blocked(
        command, slug,
        "--spec-page seeds a plan whose source is a spec page, with no design doc or tier: pass "
          + "it without --design and --tier")
    }
    if let design, !PlanFile.isValidDesignPath(design) {
      return blocked(
        command, slug,
        "--design `\(design)` must be a repo-relative docs/**/designs/<name>.md path without `..`")
    }
    let parsedTier: DesignTier?
    if let tier {
      guard let resolved = DesignTier(rawValue: tier) else {
        return blocked(command, slug, "--tier `\(tier)` must be \(tierList)")
      }
      parsedTier = resolved
    } else {
      parsedTier = nil
    }
    let located: Located
    switch await locate(slug, session: session, requireSession: true, git: git) {
    case .failure(let message): return blocked(command, slug, message)
    case .success(let value): located = value
    }
    let lock = located.lock
    if design == nil, !specPage, !lock.hasPlanFile {
      return blocked(
        command, slug,
        "`\(slug)` is a new plan: --design or --spec-page is required, so the edit guard can tie "
          + "its source to it")
    }
    // Every claim that may seed a plan.json runs its ownership check, lock and seed under one
    // repository-wide lock, so two new plans can't both pass the check for the same doc.
    var lease: LockLease?
    defer { lease?.release() }
    if let design, !lock.hasPlanFile {
      do {
        lease = try await FileCountingLock(
          directory: URL(filePath: located.layout.root, directoryHint: .isDirectory),
          name: "claim.lock", capacity: 1
        ).acquire(timeout: .seconds(30))
      } catch {
        return blocked(command, slug, "can't take the plan-state claim lock: \(error)")
      }
      if !lock.hasPlanFile {
        switch await owner(of: design, excluding: slug, in: located.layout, root: root, git: git) {
        case .failure(let failure): return blocked(command, slug, failure)
        case .success(let owner?):
          return PlanLockReport(
            command: command, plan: slug, status: .designOwned, verdict: .red, holder: nil,
            owner: owner, lockFile: nil,
            message:
              "plan `\(owner)` already owns \(design): one design doc belongs to one plan. "
              + "Continue that plan, or name a different design doc.")
        case .success(nil): break
        }
      }
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
        command, slug, .heldByOther, .red, holder, file, heldByOtherMessage(slug, holder))
    case .claimed, .alreadyHeld:
      var seeded = ""
      let seed: (file: PlanFile, names: String)? =
        if let design {
          (PlanFile.seed(slug: slug, design: design, tier: parsedTier), design)
        } else if specPage {
          (PlanFile.seedSpecPage(slug: slug), "a spec page, \(PlanFile.SpecPageSource.fileName)")
        } else {
          nil
        }
      if let seed, !lock.hasPlanFile {
        do {
          let data = try PlanFileJSON.encode(seed.file)
          if try lock.seedPlanFile(data) { seeded = "; seeded plan.json for \(seed.names)" }
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
    case .success(let located): lock = located.lock
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
          command, slug, .heldByOther, .red, holder, file, heldByOtherMessage(slug, holder))
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

  /// Names the situation and leaves the decision with the user. It never spells out a takeover
  /// command: an agent shown one tends to run it.
  static func heldByOtherMessage(_ slug: String, _ holder: String) -> String {
    "plan `\(slug)` is held by session \(holder), not this one. A held lock stays live until its "
      + "session releases it, and only the user can tell whether that session has ended. Stop "
      + "and ask the user to decide."
  }

  struct Located {
    let layout: PlanStateLayout
    let lock: PlanLock
  }

  /// The other plan whose `plan.json` names `design`, compared case-insensitively after both are
  /// resolved against this worktree's toplevel. A plan.json that can't be read or decoded fails
  /// the claim: it might name the doc.
  private static func owner(
    of design: String, excluding slug: String, in layout: PlanStateLayout, root: URL?,
    git: any Git
  ) async -> Result<String?, LocateFailure> {
    let toplevel: String?
    if let root {
      do {
        let prefix = try await git.workingDirectoryPrefix()
          .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = CanonicalPath.of(root)
        toplevel =
          prefix.isEmpty
          ? base : base.hasSuffix("/" + prefix) ? String(base.dropLast(prefix.count + 1)) : base
      } catch {
        return .failure(LocateFailure("can't find the worktree toplevel: \(error)"))
      }
    } else {
      toplevel = nil
    }
    func key(_ path: String) -> String {
      let absolute = path.hasPrefix("/") ? path : toplevel.map { $0 + "/" + path }
      let resolved = absolute.map { CanonicalPath.of(URL(filePath: $0)) } ?? path
      return resolved.lowercased()
    }
    let wanted = key(design)
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: layout.root)
    } catch CocoaError.fileReadNoSuchFile {
      return .success(nil)
    } catch {
      return .failure(LocateFailure("listing \(layout.root): \(error.localizedDescription)"))
    }
    for name in names.sorted() where name != slug {
      guard let plan = try? layout.plan(name) else { continue }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: plan.directory, isDirectory: &isDirectory),
        isDirectory.boolValue, FileManager.default.fileExists(atPath: plan.planFile)
      else { continue }
      let file: PlanFile
      do {
        file = try PlanFileJSON.decode(try Data(contentsOf: URL(filePath: plan.planFile)))
      } catch {
        return .failure(
          LocateFailure(
            "\(plan.planFile) can't be read, so it can't be ruled out as the owner of "
              + "\(design): \(error)"))
      }
      if let source = file.designSource, key(source.design) == wanted { return .success(name) }
    }
    return .success(nil)
  }

  /// Validates the inputs and places the plan under the git common dir, so every worktree of
  /// the repository contends for the same lock.
  private static func locate(
    _ slug: String, session: String?, requireSession: Bool, git: any Git
  ) async -> Result<Located, LocateFailure> {
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
      let layout = try PlanStateLayout(commonDirectory: common)
      return .success(Located(layout: layout, lock: PlanLock(plan: try layout.plan(slug))))
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
      command: command, plan: slug, status: status, verdict: verdict, holder: holder, owner: nil,
      lockFile: lockFile, message: message)
  }
}

struct PlanClaimCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claim",
    abstract: "Create the plan directory under the git common dir and write orchestrator.lock.",
    discussion:
      "Exits 0 when this session now holds the plan (or already did), 1 when another session "
      + "holds it or another plan already owns the --design doc, and 2 for an invalid plan name, "
      + "a missing session or no git repository.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Option(help: "The session id to record as the lock holder (from the SessionStart context).")
  var session: String?

  @Option(
    help: ArgumentHelp(
      "The design doc, repo-relative under a docs/**/designs/ directory. Required to claim a "
        + "new plan: it seeds plan.json, which is how the edit guard ties the doc to this plan."))
  var design: String?

  @Flag(
    help: ArgumentHelp(
      "Seed a new plan whose source is a spec page, <plans>/<slug>/\(PlanFile.SpecPageSource.fileName), "
        + "instead of a design doc. Not with --design or --tier."))
  var specPage = false

  @Option(
    help: ArgumentHelp(
      "The design's tier, recorded in a seeded plan.json.",
      discussion: "One of \(PlanLockRun.tierList)."))
  var tier: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let report = await PlanLockRun.claim(
      slug: slug, session: session, design: design, specPage: specPage, tier: tier, root: root,
      git: git)
    Console.write(PlanLockRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
