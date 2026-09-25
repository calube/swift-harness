import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// One `--json` element: the status the claim moves to, and its new `loc` only when the quote
/// was found elsewhere in the cited file. The design skill rewrites `claims.jsonl` from these.
struct EvidenceCheckLine: Sendable, Equatable, Encodable {
  let id: String
  let status: Claim.Status
  let loc: String?
}

/// Loads the design's claims and their sources, then hands every rule to ``EvidenceCheck``.
enum EvidenceCheckRun {
  struct Options: Sendable, Equatable {
    var design: String?
    var at: String?
    /// Repo-relative; read from the ref under `--at`.
    var packageResolved: String
    /// `nil` asks `xcrun`, and only when a probe or snapshot claim needs one.
    var sdk: String?
  }

  enum Outcome: Sendable, Equatable {
    case checked(claims: [Claim], results: [EvidenceCheckResult])
    /// The input couldn't be read, so no claim was judged.
    case blocked(String)
  }

  static func run(options: Options, root: URL, runner: any ProcessRunner) async -> Outcome {
    guard let design = options.design else {
      return .blocked("--design <doc> is required: it locates <slug>.evidence/claims.jsonl")
    }
    guard PlanFile.isValidDesignPath(design) else {
      return .blocked(
        "--design `\(design)` must be a repo-relative docs/**/designs/<name>.md path")
    }
    let layout = EvidenceLayout(designDocPath: design)
    do throws(EvidenceFiles.LoadError) {
      let claims = try EvidenceFiles.claims(root: root, layout: layout)
      var sdk = options.sdk
      if sdk == nil, claims.contains(where: { [.probe, .snapshot].contains($0.citation.kind) }) {
        sdk = await EvidenceFiles.currentSDKVersion(runner: runner)
      }
      let results: [EvidenceCheckResult]
      if let ref = options.at {
        let sources = try await EvidenceFiles.atRef(
          ref, claims: claims, root: root, layout: layout,
          packageResolvedPath: options.packageResolved, sdkVersion: sdk,
          git: LiveGit(runner: runner, repositoryRoot: root.path))
        results = EvidenceCheck.check(claims, sources: sources, mode: .atRef)
      } else {
        let sources = EvidenceFiles.workingTree(
          root: root, layout: layout, packageResolvedPath: options.packageResolved,
          sdkVersion: sdk)
        results = EvidenceCheck.check(claims, sources: sources, mode: .workingTree)
      }
      return .checked(claims: claims, results: results)
    } catch {
      return .blocked(describe(error))
    }
  }

  static func exitCode(_ outcome: Outcome) -> Int32 {
    switch outcome {
    case .blocked: Verdict.blocked.exitCode
    case .checked(_, let results):
      results.contains(where: \.isFailing) ? Verdict.red.exitCode : Verdict.green.exitCode
    }
  }

  static func lines(claims: [Claim], results: [EvidenceCheckResult]) -> [EvidenceCheckLine] {
    zip(claims, results).map { claim, result in
      let loc: String?
      if case .relocated(let newLoc) = result.outcome { loc = newLoc } else { loc = nil }
      // A probe with no usable verdict has no new status to move to; it keeps the recorded one
      // and still fails the check.
      return EvidenceCheckLine(
        id: result.claimID, status: result.claimStatus ?? claim.status, loc: loc)
    }
  }

  static func render(_ outcome: Outcome, format: OutputFormat) -> String {
    switch (outcome, format) {
    case (.blocked(let message), .json):
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let data =
        (try? encoder.encode(["verdict": Verdict.blocked.rawValue, "message": message])) ?? Data()
      return String(decoding: data, as: UTF8.self)
    case (.blocked(let message), .human):
      return "evidence check: \(Verdict.blocked.rawValue) \(message)"
    case (.checked(let claims, let results), .json):
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = (try? encoder.encode(lines(claims: claims, results: results))) ?? Data()
      return String(decoding: data, as: UTF8.self)
    case (.checked(let claims, let results), .human):
      let failing = results.filter(\.isFailing).count
      let verdict = failing == 0 ? Verdict.green : Verdict.red
      var text = [
        "evidence check: \(verdict.rawValue) \(results.count) claim(s), \(failing) failing or stale"
      ]
      for (line, result) in zip(lines(claims: claims, results: results), results) {
        text.append("  \(line.status.rawValue) \(line.id)\(detail(result.outcome))")
      }
      return text.joined(separator: "\n")
    }
  }

  private static func detail(_ outcome: EvidenceCheckResult.Outcome) -> String {
    switch outcome {
    case .passed: ""
    case .relocated(let loc): " — relocated to \(loc)"
    case .failed(let failure): " — failed: \(failure)"
    case .stale(let reason): " — stale: \(reason)"
    }
  }

  private static func describe(_ error: EvidenceFiles.LoadError) -> String {
    switch error {
    case .claimsFileMissing(let path): "\(path): no claims file"
    case .claimsFileUnreadable(let path, let detail): "\(path): unreadable: \(detail)"
    case .malformedClaimLine(let path, let line): "\(path):\(line): not a valid claim record"
    case .refNotFound(let ref): "--at `\(ref)` names no commit"
    case .git(let error): "git: \(error)"
    }
  }
}

struct EvidenceCheckCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check",
    abstract: "Re-check every claim in claims.jsonl against its cited file and Package.resolved.",
    discussion:
      "Per claim: quote-ok, quote-fail, supported, refuted, stale, or quote-ok with a relocated "
      + "loc. Under --at, cited repo files and Package.resolved are read from the ref; .build/ "
      + "checkouts and <slug>.evidence/ files from the working tree. Exit 0 all pass, 1 any "
      + "failing or stale claim, 2 unreadable or malformed input.")

  @Option(help: "The design doc whose <slug>.evidence/claims.jsonl is checked.")
  var design: String?

  @Option(help: "Check evidence as of this ref instead of the working tree.")
  var at: String?

  @Option(help: "The repo-relative Package.resolved that package pins are checked against.")
  var packageResolved = "Package.resolved"

  @Option(help: "The SDK version now in effect; defaults to what xcrun reports.")
  var sdk: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let outcome = await EvidenceCheckRun.run(
      options: .init(design: design, at: at, packageResolved: packageResolved, sdk: sdk),
      root: root, runner: LiveProcessRunner())
    Console.write(EvidenceCheckRun.render(outcome, format: output.format))
    let code = EvidenceCheckRun.exitCode(outcome)
    if code != 0 { throw ExitCode(code) }
  }
}
