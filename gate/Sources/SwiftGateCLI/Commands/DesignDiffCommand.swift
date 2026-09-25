import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `design-diff` found: a classification of two revisions, or a verified clarify chain.
struct DesignDiffReport: Sendable, Equatable, Encodable {
  enum Mode: String, Sendable, Encodable {
    case diff
    case chain
  }

  enum Status: String, Sendable, Encodable {
    case classified
    case valid
    case broken
    case invalidRevision = "invalid-revision"
    case unknownRef = "unknown-ref"
    case missingPath = "missing-path"
    case unreadable
    case noApproval = "no-approval"
    case gitFailed = "git-failed"
  }

  struct BrokenLink: Sendable, Equatable, Encodable {
    enum Problem: String, Sendable, Encodable {
      case discontinuous
      case unknownFromSha = "unknown-from-sha"
      case unknownToSha = "unknown-to-sha"
      case noChange = "no-change"
      case amend
    }

    let index: Int
    let fromSha: String
    let toSha: String
    let problem: Problem
    let triggers: [DesignDiff.Trigger]?
    let changedIds: [String]?
  }

  let command = "design-diff"
  let mode: Mode
  let status: Status
  let verdict: Verdict
  var old: String?
  var new: String?
  var changeClass: DesignDiff.Class?
  var oldSha: String?
  var newSha: String?
  var triggers: [DesignDiff.Trigger]?
  var changedIds: [String]?
  var plan: String?
  var design: String?
  var approvedSha: String?
  var endSha: String?
  var brokenLink: BrokenLink?
  let message: String

  init(mode: Mode, status: Status, verdict: Verdict, message: String) {
    self.mode = mode
    self.status = status
    self.verdict = verdict
    self.message = message
  }

  enum CodingKeys: String, CodingKey {
    case command, mode, status, verdict, old, new, oldSha, newSha, triggers, changedIds, plan
    case design, approvedSha, endSha, brokenLink, message
    case changeClass = "class"
  }
}

/// One side of a diff as named on the command line: a file (read from the working tree) or
/// `<ref>:<path>` (read from that commit, path relative to the repository toplevel, as git reads
/// it). A committed revision never falls back to the working tree.
enum DesignRevision: Sendable, Equatable {
  case file(String)
  case committed(ref: String, path: String)
  case invalid(String)

  /// A leading `/`, `./` or `../` always names a file, so a path containing `:` stays reachable.
  static func parse(_ argument: String) -> DesignRevision {
    if argument.hasPrefix("/") || argument.hasPrefix("./") || argument.hasPrefix("../") {
      return .file(argument)
    }
    guard let colon = argument.firstIndex(of: ":") else { return .file(argument) }
    let ref = String(argument[..<colon])
    let path = String(argument[argument.index(after: colon)...])
    guard !ref.isEmpty, !path.isEmpty else { return .invalid(argument) }
    return .committed(ref: ref, path: path)
  }
}

enum DesignDiffRun {
  static func diff(old: String, new: String, workingDirectory: URL, git: any Git) async
    -> DesignDiffReport
  {
    let oldText: String
    let newText: String
    switch await read(old, workingDirectory: workingDirectory, git: git) {
    case .failure(let failure): return blocked(.diff, failure, old: old, new: new)
    case .success(let text): oldText = text
    }
    switch await read(new, workingDirectory: workingDirectory, git: git) {
    case .failure(let failure): return blocked(.diff, failure, old: old, new: new)
    case .success(let text): newText = text
    }
    let diff = DesignDiff.compare(old: oldText, new: newText)
    var report = DesignDiffReport(
      mode: .diff, status: .classified, verdict: .green, message: summary(diff))
    report.old = old
    report.new = new
    report.changeClass = diff.changeClass
    report.oldSha = diff.oldSha
    report.newSha = diff.newSha
    report.triggers = diff.triggers
    report.changedIds = diff.changedIds
    return report
  }

  static func chain(planPath: String, workingDirectory: URL, git: any Git) async
    -> DesignDiffReport
  {
    let plan: PlanFile
    do {
      let data = try Data(contentsOf: resolve(planPath, in: workingDirectory))
      plan = try PlanFileJSON.decode(data)
    } catch {
      return blocked(
        .chain, Failure(.unreadable, "can't read plan `\(planPath)`: \(error)"), plan: planPath)
    }
    guard let approval = plan.approval, approval.decision == "approve" else {
      var report = blocked(
        .chain,
        Failure(.noApproval, "plan `\(planPath)` records no approval, so no chain can start"),
        plan: planPath)
      report.design = plan.design
      return report
    }

    let history: DesignHistory
    do {
      history = try await DesignHistory.load(plan.design, git: git)
    } catch {
      var report = blocked(
        .chain, Failure(.gitFailed, "can't walk the history of `\(plan.design)`: \(error)"),
        plan: planPath)
      report.design = plan.design
      return report
    }

    let links = plan.clarifyChain.map { ClarifyChain.Link(fromSha: $0.fromSha, toSha: $0.toSha) }
    let verification = ClarifyChain.verify(
      approvedSha: approval.designSha, links: links, revisions: history.textBySha)
    var report: DesignDiffReport
    switch verification {
    case .valid(let endSha):
      report = DesignDiffReport(
        mode: .chain, status: .valid, verdict: .green,
        message: "clarify chain of \(links.count) link(s) is valid; the approval covers \(endSha)")
      report.endSha = endSha
    case .broken(let broken):
      report = DesignDiffReport(
        mode: .chain, status: .broken, verdict: .red,
        message: broken.message + history.caveat)
      report.brokenLink = DesignDiffReport.BrokenLink(broken)
    }
    report.plan = planPath
    report.design = plan.design
    report.approvedSha = approval.designSha
    return report
  }

  static func render(_ report: DesignDiffReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = (try? encoder.encode(report)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    case .human:
      return "design-diff: \(report.verdict.rawValue) \(report.message)"
    }
  }

  private static func summary(_ diff: DesignDiff) -> String {
    let shas = "\(diff.oldSha) → \(diff.newSha)"
    switch diff.changeClass {
    case .unchanged: return "unchanged (\(shas))"
    case .clarify: return "clarify (\(shas))"
    case .amend:
      let triggers = diff.triggers.map(\.rawValue).joined(separator: ", ")
      let ids = diff.changedIds.isEmpty ? "" : "; ids: " + diff.changedIds.joined(separator: ", ")
      return "amend: \(triggers)\(ids) (\(shas))"
    }
  }

  struct Failure: Error {
    let status: DesignDiffReport.Status
    let message: String
    init(_ status: DesignDiffReport.Status, _ message: String) {
      self.status = status
      self.message = message
    }
  }

  private static func blocked(
    _ mode: DesignDiffReport.Mode, _ failure: Failure, old: String? = nil, new: String? = nil,
    plan: String? = nil
  ) -> DesignDiffReport {
    var report = DesignDiffReport(
      mode: mode, status: failure.status, verdict: .blocked, message: failure.message)
    report.old = old
    report.new = new
    report.plan = plan
    return report
  }

  private static func resolve(_ path: String, in directory: URL) -> URL {
    path.hasPrefix("/")
      ? URL(filePath: path) : directory.appending(path: path, directoryHint: .notDirectory)
  }

  private static func read(_ argument: String, workingDirectory: URL, git: any Git) async
    -> Result<String, Failure>
  {
    switch DesignRevision.parse(argument) {
    case .invalid(let text):
      return .failure(
        Failure(.invalidRevision, "`\(text)` is neither a path nor a `<ref>:<path>` revision"))
    case .file(let path):
      let data: Data
      do {
        data = try Data(contentsOf: resolve(path, in: workingDirectory))
      } catch {
        return .failure(Failure(.unreadable, "can't read `\(path)`: \(error.localizedDescription)"))
      }
      guard let text = String(data: data, encoding: .utf8) else {
        return .failure(Failure(.unreadable, "`\(path)` is not UTF-8"))
      }
      return .success(text)
    case .committed(let ref, let path):
      do {
        guard let commit = try await git.revision(ref) else {
          return .failure(Failure(.unknownRef, "git can't resolve `\(ref)` to a commit"))
        }
        guard let text = try await git.contents(of: [path], at: commit)[path] else {
          return .failure(Failure(.missingPath, "`\(path)` doesn't exist at `\(ref)`"))
        }
        return .success(text)
      } catch GitError.invalidRef(let bad) {
        return .failure(Failure(.invalidRevision, "`\(bad)` is not a usable ref"))
      } catch {
        return .failure(Failure(.gitFailed, "git failed reading `\(argument)`: \(error)"))
      }
    }
  }
}

/// Every committed revision of one design doc, keyed by designSha (spec §5.4: hashed in process,
/// never written to git). Commits where the doc sat under an earlier name are counted, not read,
/// so a chain reaching back past a rename breaks and says why.
private struct DesignHistory {
  let textBySha: [String: String]
  let commits: Int
  let unreadable: Int

  var caveat: String {
    unreadable == 0
      ? ""
      : " (\(unreadable) of \(commits) commits hold the doc under another path and weren't hashed)"
  }

  static func load(_ path: String, git: any Git) async throws -> DesignHistory {
    let commits = try await git.revisions(of: path)
    var textBySha: [String: String] = [:]
    var unreadable = 0
    for commit in commits {
      guard let text = try await git.contents(of: [path], at: commit)[path] else {
        unreadable += 1
        continue
      }
      textBySha[DesignSha.of(text)] = text
    }
    return DesignHistory(textBySha: textBySha, commits: commits.count, unreadable: unreadable)
  }
}

extension DesignDiffReport.BrokenLink {
  init(_ broken: ClarifyChain.BrokenLink) {
    index = broken.index
    fromSha = broken.link.fromSha
    toSha = broken.link.toSha
    switch broken.problem {
    case .discontinuous: problem = .discontinuous
    case .unknownFromSha: problem = .unknownFromSha
    case .unknownToSha: problem = .unknownToSha
    case .noChange: problem = .noChange
    case .amend: problem = .amend
    }
    if case .amend(let diff) = broken.problem {
      triggers = diff.triggers
      changedIds = diff.changedIds
    } else {
      triggers = nil
      changedIds = nil
    }
  }
}

struct DesignDiffCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design-diff",
    abstract: "Classify a design revision as amend or clarify, and compute its designSha.",
    discussion:
      "`design-diff <old> <new>` classifies the change: one touching a req- line, Decision, "
      + "Module kinds or the Test plan is amend; anything else is clarify. A revision is a file "
      + "path or `<ref>:<path>` (path from the repository toplevel). Exits 0 once classified, "
      + "2 when a revision can't be read (unknown ref, path missing at the ref, unreadable file). "
      + "`design-diff --chain <plan.json>` re-verifies the plan's clarify chain against the "
      + "design's committed history: 0 valid, 1 a link is broken, 2 when it can't be checked.")

  @Argument(help: "Two revisions, old then new: file paths or `<ref>:<path>`.")
  var revisions: [String] = []

  @Option(help: "Verify the clarify chain recorded in this plan.json instead of diffing.")
  var chain: String?

  @OptionGroup var output: OutputOptions

  func validate() throws {
    if chain == nil, revisions.count != 2 {
      throw ValidationError("pass two revisions, old then new, or --chain <plan.json>")
    }
    if chain != nil, !revisions.isEmpty {
      throw ValidationError("--chain takes no revisions: it reads the design from plan.json")
    }
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let report: DesignDiffReport
    if let chain {
      report = await DesignDiffRun.chain(planPath: chain, workingDirectory: root, git: git)
    } else {
      report = await DesignDiffRun.diff(
        old: revisions[0], new: revisions[1], workingDirectory: root, git: git)
    }
    Console.write(DesignDiffRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
