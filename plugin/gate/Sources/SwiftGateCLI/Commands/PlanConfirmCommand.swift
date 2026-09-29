import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Why `plan confirm` refused a page it could read. Each is exit 1.
enum PlanConfirmRule: String, Sendable, Equatable, CaseIterable {
  /// `spec-page check` found a major problem with the page.
  case pageRed = "plan-confirm.page-red"
  /// `--by spec-quotes` on a page the check says the user, or a delegate, must confirm.
  case needsUser = "plan-confirm.needs-user"
}

/// What `plan confirm` did to a spec-page plan's confirmation.
struct PlanConfirmReport: Sendable, Equatable, Encodable {
  enum Status: String, Sendable, Encodable {
    case confirmed
    case refused
    /// The lock is free or another session holds it; nothing was written.
    case notHeld = "not-held"
    case blocked
  }

  var plan: String
  var status: Status = .blocked
  var verdict: Verdict = .blocked
  var rule: PlanConfirmRule?
  /// The session holding the lock when it isn't the caller.
  var holder: String?
  var by: PlanFile.PageApprover?
  var confirm: SpecPageCheck.Confirm?
  var pageSha: String?
  var findings: [Finding] = []
  var message = ""

  private enum CodingKeys: String, CodingKey {
    case command, plan, status, verdict, rule, holder, by, confirm, pageSha, findings, message
  }

  /// Every key is always present; an absent value is `null`.
  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(PlanConfirmRun.command, forKey: .command)
    try c.encode(plan, forKey: .plan)
    try c.encode(status, forKey: .status)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(rule?.rawValue, forKey: .rule)
    try c.encode(holder, forKey: .holder)
    try c.encode(by, forKey: .by)
    try c.encode(confirm?.rawValue, forKey: .confirm)
    try c.encode(pageSha, forKey: .pageSha)
    try c.encode(findings, forKey: .findings)
    try c.encode(message, forKey: .message)
  }
}

/// The testable core of `plan confirm` (fast modes §5.1 step 1): the lock holder's confirmation of
/// a spec page, bound to the sha of the bytes `spec-page check` passed.
enum PlanConfirmRun {
  static let command = "plan confirm"

  static var approverList: String {
    PlanFile.PageApprover.allCases.map(\.rawValue).joined(separator: " or ")
  }

  static func run(
    slug: String, session: String?, by: String, specPath: String, git: any Git,
    now: Date = Date()
  ) async -> PlanConfirmReport {
    guard let approver = PlanFile.PageApprover(rawValue: by) else {
      return blocked(slug, "--by `\(by)` must be \(approverList)")
    }
    guard let session else {
      return blocked(slug, "--session is required: pass the id from the SessionStart context")
    }
    guard PlanLock.isValidSession(session) else {
      return blocked(slug, "--session must be a non-empty id without whitespace")
    }
    let store: PlanStateStore
    let indexPath: String
    do {
      let common = try await git.commonDirectory()
      let layout = try PlanStateLayout(commonDirectory: common)
      store = PlanStateStore(plan: try layout.plan(slug))
      indexPath = layout.indexFile
    } catch let error as GitError {
      return blocked(slug, "can't find the git common dir: \(error)")
    } catch {
      return blocked(slug, "invalid plan name `\(slug)`: \(error)")
    }
    let lock = PlanLock(plan: store.plan)
    let holder: String?
    do {
      holder = try lock.holder()
    } catch {
      return blocked(slug, "can't read \(store.plan.orchestratorLock): \(error)")
    }
    guard let holder, holder == session else {
      return PlanConfirmReport(
        plan: slug, status: .notHeld, verdict: .red, rule: nil, holder: holder, by: approver,
        confirm: nil, pageSha: nil, findings: [],
        message: holder.map { PlanLockRun.heldByOtherMessage(slug, $0) }
          ?? "plan `\(slug)` isn't claimed; only the session holding its lock confirms its "
          + "spec page. Claim it with `swiftgate plan claim \(slug) --spec-page --session <id>` "
          + "first.")
    }
    let current: PlanFile
    do {
      current = try store.planFile()
    } catch {
      return blocked(slug, "\(store.plan.planFile) can't be read or decoded: \(error)")
    }
    let source: PlanFile.SpecPageSource
    switch current.source {
    case .design(let design):
      return blocked(
        slug,
        "plan `\(slug)` is a design plan (its design is \(design.design)); only a spec-page "
          + "plan has a spec page to confirm, and plan.json was left as it is")
    case .specPage(let page):
      source = page
    }

    // The sha recorded is of the same bytes the check read, so an edit after this read can't
    // ride on the confirmation.
    let pagePath = store.specPageFile(source)
    let pageData: Data
    do {
      pageData = try Data(contentsOf: URL(filePath: pagePath))
    } catch {
      return blocked(slug, "can't read the spec page \(pagePath): \(error.localizedDescription)")
    }
    let pageSha = SpecPageCheck.pageSha(pageData)
    guard let pageText = String(data: pageData, encoding: .utf8) else {
      return blocked(slug, "the spec page \(pagePath) isn't UTF-8 text", pageSha: pageSha)
    }
    let spec: String
    do {
      spec = try String(contentsOf: URL(filePath: specPath), encoding: .utf8)
    } catch {
      return blocked(
        slug, "can't read the spec file \(specPath) as UTF-8 text: \(error.localizedDescription)",
        pageSha: pageSha)
    }
    let check: SpecPageReport
    do {
      check = try SpecPageCheck.check(page: pageText, pagePath: pagePath, spec: spec)
    } catch {
      return blocked(slug, "spec-page check built an invalid finding: \(error)", pageSha: pageSha)
    }

    switch check.verdict {
    case .green:
      break
    case .red:
      let majors = check.findings.filter { $0.severity != .nit }
      let named = majors.map { "\($0.ruleID) (\($0.message))" }.joined(separator: "; ")
      return refused(
        slug, .pageRed, approver, check, pageSha,
        "the spec page \(pagePath) fails spec-page check: \(named). Fix the page, then confirm "
          + "it again.")
    case .blocked:
      return blocked(slug, "spec-page check couldn't judge \(pagePath)", pageSha: pageSha)
    }
    if approver == .specQuotes, check.confirm != .skippable {
      return refused(
        slug, .needsUser, approver, check, pageSha,
        "spec-page check says confirm: required for \(pagePath): a slice says Spec: none or "
          + "quotes a line the spec file doesn't hold. Show the page to the user and record "
          + "their confirm with --by user, or --by delegate when a session answers on the "
          + "user's behalf under their delegation.")
    }

    let updated = PlanFile(
      schemaVersion: current.schemaVersion, slug: current.slug,
      source: .specPage(
        PlanFile.SpecPageSource(
          path: source.path, pageSha: pageSha,
          approval: PlanFile.PageApproval(pageSha: pageSha, by: approver, at: now))),
      surfaceCommit: current.surfaceCommit, resume: current.resume)
    do {
      // Written beside the old file and renamed over it: a reader sees one whole file or the other.
      try PlanFileJSON.encode(updated).write(
        to: URL(filePath: store.plan.planFile), options: .atomic)
    } catch {
      return blocked(slug, "writing \(store.plan.planFile): \(error)", pageSha: pageSha)
    }
    do {
      try await PlanIndexStore(path: indexPath).update { index in
        let resume = index.plans.first { $0.slug == slug }?.resume ?? current.resume
        return index.settingStatus(
          slug: slug, status: PlanStatus.approved.rawValue, resume: resume)
      }
    } catch {
      return blocked(
        slug,
        "recorded the confirmation in \(store.plan.planFile), but setting \(indexPath) to "
          + "approved failed: \(error). Run `swiftgate index set \(slug) approved` to finish.",
        pageSha: pageSha)
    }
    return PlanConfirmReport(
      plan: slug, status: .confirmed, verdict: .green, rule: nil, holder: nil, by: approver,
      confirm: check.confirm, pageSha: pageSha, findings: check.findings,
      message: "confirmed plan `\(slug)`'s spec page \(pageSha) by \(approver.rawValue)")
  }

  static func render(_ report: PlanConfirmReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = (try? encoder.encode(report)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    case .human:
      let rule = report.rule.map { "\($0.rawValue) " } ?? ""
      return "\(command): \(report.verdict.rawValue) \(rule)\(report.message)"
    }
  }

  private static func refused(
    _ slug: String, _ rule: PlanConfirmRule, _ approver: PlanFile.PageApprover,
    _ check: SpecPageReport, _ pageSha: String, _ message: String
  ) -> PlanConfirmReport {
    PlanConfirmReport(
      plan: slug, status: .refused, verdict: .red, rule: rule, holder: nil, by: approver,
      confirm: check.confirm, pageSha: pageSha, findings: check.findings, message: message)
  }

  private static func blocked(_ slug: String, _ message: String, pageSha: String? = nil)
    -> PlanConfirmReport
  {
    PlanConfirmReport(
      plan: slug, status: .blocked, verdict: .blocked, rule: nil, holder: nil, by: nil,
      confirm: nil, pageSha: pageSha, findings: [], message: message)
  }
}

struct PlanConfirmCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "confirm",
    abstract: "Confirm a spec-page plan's page, as its lock holder.",
    discussion:
      "Runs spec-page check on the plan's spec-page.md against --spec, then records "
      + "{pageSha, by, at} as plan.json's approval and sets the plan's index entry to approved. "
      + "--by delegate records a confirm a session gives on the user's behalf and is accepted "
      + "wherever --by user is. --by spec-quotes is refused (plan-confirm.needs-user) unless the check prints confirm: "
      + "skippable; a RED page is refused under every --by (plan-confirm.page-red). Exits 0 "
      + "when recorded, 1 when refused or this session doesn't hold the plan's lock, and 2 for "
      + "a missing or invalid flag, a design plan, or a page, spec file or plan.json that can't "
      + "be read.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Option(
    help: ArgumentHelp(
      "Who confirms the page.",
      discussion:
        "user; delegate for a session answering on the user's behalf under their "
        + "delegation; or spec-quotes when every slice quotes the spec file."))
  var by: String

  @Option(help: "The spec file the page quotes.")
  var spec: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let report = await PlanConfirmRun.run(
      slug: slug, session: session, by: by, specPath: spec, git: git)
    Console.write(PlanConfirmRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
