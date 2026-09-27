import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `evidence cache record` wrote to the user-level reuse cache (spec §8.6), and what it left
/// out and why.
struct EvidenceCacheRecordReport: Sendable, Equatable, Encodable {
  enum Entry: String, Sendable, Equatable, Encodable {
    case claim, verdict, tombstone
  }

  enum Outcome: String, Sendable, Equatable, Encodable {
    case appended
    /// The same entry was already there, so the file is unchanged.
    case alreadyCached = "already-cached"
    /// A claim or verdict held back because its fingerprint is tombstoned in that file.
    case tombstoned
  }

  enum SkipReason: String, Sendable, Equatable, Encodable {
    /// A `file` citation into the repository itself: the code under it changes, so it's never
    /// cached.
    case codebase
    /// `capture` and `answer` citations mean nothing outside this design's run.
    case notReusable = "not-reusable"
    /// Neither `supported` nor `refuted`: verify hasn't settled it.
    case unverified
    /// `swiftgate probe` caches its own verdicts under the snippet's key.
    case probe
    case missingPin = "missing-pin"
    case invalidPin = "invalid-pin"
  }

  struct Write: Sendable, Equatable, Encodable {
    let claimId: String
    let entry: Entry
    /// The cache file, relative to the cache root: `<pkg>@<ver>.jsonl`, `sdk/<pin>.jsonl` or
    /// `verdicts.jsonl`.
    let bucket: String
    let outcome: Outcome
  }

  struct Skip: Sendable, Equatable, Encodable {
    let claimId: String
    let reason: SkipReason
  }

  let command = "evidence cache record"
  let verdict: Verdict
  let design: String
  let base: String?
  let writes: [Write]
  let skipped: [Skip]
  let notes: [String]
  let message: String
}

/// Records a verified design's reusable claims in the evidence reuse cache: supported package
/// claims per `<pkg>@<version>`, supported snapshot claims per SDK, the claim checker's verdicts,
/// and tombstones for refuted claims and, under `--base`, for claims an amend replaced. Every
/// write goes through ``EvidenceCacheStore``, whose entries are immutable once written, so a
/// rerun over the same claims appends nothing.
enum EvidenceCacheRecordRun {
  struct Options: Sendable, Equatable {
    var design: String
    /// The ref holding the claims before an amend; `nil` records without looking for
    /// replacements.
    var base: String?
    /// Stands in for `~`; `nil` reads `$HOME`.
    var cacheHome: String?
  }

  private struct Blocked: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  private typealias Write = EvidenceCacheRecordReport.Write
  private typealias Skip = EvidenceCacheRecordReport.Skip

  static func run(options: Options, root: URL, runner: any ProcessRunner) async
    -> EvidenceCacheRecordReport
  {
    do {
      return try await record(options: options, root: root, runner: runner)
    } catch let blocked as Blocked {
      return EvidenceCacheRecordReport(
        verdict: .blocked, design: options.design, base: options.base, writes: [], skipped: [],
        notes: [], message: blocked.message)
    } catch {
      return EvidenceCacheRecordReport(
        verdict: .blocked, design: options.design, base: options.base, writes: [], skipped: [],
        notes: [], message: "\(error)")
    }
  }

  private static func record(options: Options, root: URL, runner: any ProcessRunner) async throws
    -> EvidenceCacheRecordReport
  {
    let design = options.design
    guard PlanFile.isValidDesignPath(design) else {
      throw Blocked("--design `\(design)` must be a repo-relative docs/**/designs/<name>.md path")
    }
    guard let cacheHome = options.cacheHome ?? ProcessInfo.processInfo.environment["HOME"] else {
      throw Blocked("missing required option '--cache-home <path>' ($HOME is not set)")
    }
    let layout = EvidenceLayout(designDocPath: design)
    let claims: [Claim]
    do {
      claims = try EvidenceFiles.claims(root: root, layout: layout)
    } catch {
      throw Blocked(describe(error))
    }

    var notes: [String] = []
    var replaced: [ReusableClaim] = []
    if let base = options.base {
      let before = try await claimsAtBase(base, layout: layout, root: root, runner: runner)
      notes += before.notes
      replaced = replacedClaims(before: before.claims, after: claims)
    }

    let store = EvidenceCacheStore(home: URL(filePath: cacheHome, directoryHint: .isDirectory))
    var skipped: [Skip] = []
    var refuted: [ReusableClaim] = []
    var supported: [ReusableClaim] = []
    for claim in claims {
      switch reusable(claim) {
      case .failure(let reason): skipped.append(Skip(claimId: claim.id, reason: reason))
      case .success(let entry):
        if claim.status == .refuted { refuted.append(entry) } else { supported.append(entry) }
      }
    }

    // Tombstones go first, so a supported claim this run shares a fingerprint with is held back
    // in the same run rather than served until the next one.
    var writes: [Write] = []
    for claim in replaced {
      writes.append(try await tombstone(claim, .amended, store: store))
    }
    for claim in refuted {
      writes.append(try await tombstone(claim, .refuted, store: store))
      if let write = try await verdict(.refuted, claim, store: store, notes: &notes) {
        writes.append(write)
      }
    }
    for claim in supported {
      let outcome: EvidenceCacheWrite
      do {
        outcome = try await store.record(claim, origin: .researchLane)
      } catch {
        throw Blocked("\(claim.claim.id): the claim was not cached: \(error)")
      }
      writes.append(
        Write(
          claimId: claim.claim.id, entry: .claim, bucket: bucketName(claim.bucket, store),
          outcome: reportOutcome(outcome)))
      if let write = try await verdict(.supported, claim, store: store, notes: &notes) {
        writes.append(write)
      }
    }

    let appended = writes.filter { $0.outcome == .appended }.count
    return EvidenceCacheRecordReport(
      verdict: .green, design: design, base: options.base, writes: writes, skipped: skipped,
      notes: notes,
      message:
        "\(appended) appended, \(writes.count - appended) unchanged, \(skipped.count) skipped")
  }

  /// A claim the cache may hold, or why it can't. Only a settled status is recorded.
  private enum Admission {
    case success(ReusableClaim)
    case failure(EvidenceCacheRecordReport.SkipReason)
  }

  private static func reusable(_ claim: Claim) -> Admission {
    guard claim.status == .supported || claim.status == .refuted else {
      return .failure(.unverified)
    }
    guard claim.citation.kind != .probe else { return .failure(.probe) }
    do throws(EvidenceCacheRefusal) {
      return .success(try ReusableClaim(claim))
    } catch {
      switch error {
      case .codebaseClaim: return .failure(.codebase)
      case .notReusable: return .failure(.notReusable)
      case .missingPin: return .failure(.missingPin)
      case .invalidPin: return .failure(.invalidPin)
      }
    }
  }

  /// A claim that was supported at the base and whose id now carries another fact or pin. A
  /// claim that only moved within its file keeps its fingerprint and bucket, so it isn't one.
  private static func replacedClaims(before: [Claim], after: [Claim]) -> [ReusableClaim] {
    let current = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return before.compactMap { old in
      guard old.status == .supported, let now = current[old.id],
        let oldEntry = try? ReusableClaim(old)
      else { return nil }
      if let newEntry = try? ReusableClaim(now), newEntry.fingerprint == oldEntry.fingerprint,
        newEntry.bucket == oldEntry.bucket
      {
        return nil
      }
      return oldEntry
    }
  }

  private static func claimsAtBase(
    _ base: String, layout: EvidenceLayout, root: URL, runner: any ProcessRunner
  ) async throws -> (claims: [Claim], notes: [String]) {
    let git = LiveGit(runner: runner, repositoryRoot: root.path)
    let revision: String?
    let prefix: String
    let contents: [String: String]
    do {
      revision = try await git.revision(base)
      prefix = try await git.workingDirectoryPrefix()
      guard let revision else { throw Blocked("--base `\(base)` names no commit") }
      contents = try await git.contents(of: [prefix + layout.claimsFile], at: revision)
    } catch let blocked as Blocked {
      throw blocked
    } catch {
      throw Blocked("git: \(error)")
    }
    guard let text = contents[prefix + layout.claimsFile] else {
      return ([], ["`\(base)` has no \(layout.claimsFile): no claim was replaced"])
    }
    let decoded = ClaimJSON.decode(Data(text.utf8))
    var notes: [String] = []
    if decoded.invalidLines > 0 {
      notes.append(
        "\(decoded.invalidLines) line(s) of \(layout.claimsFile) at `\(base)` didn't parse, so "
          + "a claim they held can't be tombstoned")
    }
    return (decoded.claims, notes)
  }

  private static func tombstone(
    _ claim: ReusableClaim, _ reason: EvidenceCacheTombstoneReason, store: EvidenceCacheStore
  ) async throws -> Write {
    // The store skips a fingerprint that already has a tombstone, so the read only decides what
    // the report says; the write stays the store's own locked decision.
    let standing: Bool
    do {
      standing = try store.contents(of: claim.bucket).tombstones[claim.fingerprint] != nil
      try await store.tombstone(claim, reason: reason)
    } catch {
      throw Blocked("\(claim.claim.id): the \(reason.rawValue) tombstone was not written: \(error)")
    }
    return Write(
      claimId: claim.claim.id, entry: .tombstone, bucket: bucketName(claim.bucket, store),
      outcome: standing ? .alreadyCached : .appended)
  }

  /// The checker judged the quote against the text, so the verdict is keyed by both; a claim
  /// without a quote has no key and is named in a note.
  private static func verdict(
    _ verdict: EvidenceCacheVerdict, _ claim: ReusableClaim, store: EvidenceCacheStore,
    notes: inout [String]
  ) async throws -> Write? {
    guard claim.fingerprint.quoteHash != nil else {
      notes.append("\(claim.claim.id): no quote, so no checker verdict was cached")
      return nil
    }
    let outcome: EvidenceCacheWrite
    do {
      outcome = try await store.recordVerdict(verdict, for: claim, origin: .claimChecker)
    } catch {
      throw Blocked("\(claim.claim.id): the verdict was not cached: \(error)")
    }
    return Write(
      claimId: claim.claim.id, entry: .verdict, bucket: bucketName(.verdicts, store),
      outcome: reportOutcome(outcome))
  }

  private static func reportOutcome(_ write: EvidenceCacheWrite)
    -> EvidenceCacheRecordReport.Outcome
  {
    switch write {
    case .appended: .appended
    case .alreadyCached: .alreadyCached
    case .tombstoned: .tombstoned
    }
  }

  private static func bucketName(_ bucket: EvidenceCacheBucket, _ store: EvidenceCacheStore)
    -> String
  {
    let root = store.layout.root + "/"
    guard let path = try? store.layout.file(bucket) else { return "\(bucket)" }
    return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
  }

  private static func describe(_ error: EvidenceFiles.LoadError) -> String {
    switch error {
    case .claimsFileMissing(let path): "\(path): no claims file"
    case .claimsFileUnreadable(let path, let detail): "\(path): unreadable: \(detail)"
    case .malformedClaimLine(let path, let line): "\(path):\(line): not a valid claim record"
    case .refNotFound(let ref): "`\(ref)` names no commit"
    case .git(let error): "git: \(error)"
    }
  }

  static func render(_ report: EvidenceCacheRecordReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
    case .human:
      var lines = ["evidence cache record: \(report.verdict.rawValue) \(report.message)"]
      for write in report.writes {
        lines.append(
          "  \(write.outcome.rawValue) \(write.entry.rawValue) \(write.claimId) in \(write.bucket)")
      }
      for skip in report.skipped {
        lines.append("  skipped \(skip.claimId): \(skip.reason.rawValue)")
      }
      for note in report.notes { lines.append("  note: \(note)") }
      return lines.joined(separator: "\n")
    }
  }
}

struct EvidenceCacheCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cache",
    abstract: "Write a verified design's reusable evidence to the user-level reuse cache.",
    subcommands: [EvidenceCacheRecordCommand.self])
}

struct EvidenceCacheRecordCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "record",
    abstract: "Record a design's verified package and snapshot claims in the reuse cache.",
    discussion:
      "Run after verify's final statuses. Supported package claims go to <pkg>@<version>.jsonl, "
      + "supported snapshot claims to sdk/<pin>.jsonl, and the checker's verdicts to "
      + "verdicts.jsonl. Refuted claims are tombstoned; with --base, so is every claim the base "
      + "held as supported whose id now states another fact or pin. Codebase, capture, answer "
      + "and probe claims are never recorded. A rerun appends nothing. Exit 0 recorded, 2 "
      + "unreadable claims, an unknown --base or a cache write that failed.")

  @Option(help: "The design doc whose <slug>.evidence/claims.jsonl is recorded.")
  var design: String

  @Option(help: "The ref holding the claims before an amend; replaced claims are tombstoned.")
  var base: String?

  @Option(help: "The evidence reuse cache's home directory; defaults to $HOME.")
  var cacheHome: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let report = await EvidenceCacheRecordRun.run(
      options: .init(design: design, base: base, cacheHome: cacheHome), root: root,
      runner: LiveProcessRunner())
    Console.write(EvidenceCacheRecordRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
