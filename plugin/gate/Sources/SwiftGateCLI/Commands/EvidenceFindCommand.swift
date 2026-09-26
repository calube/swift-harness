import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `evidence find` produced, or why it couldn't search at all (spec §6.1, §8.6).
struct EvidenceFindReport: Sendable, Equatable, Encodable {
  struct Hit: Sendable, Equatable, Encodable {
    let id: String
    let text: String
    let status: Claim.Status
    let origin: String
    let reuseCount: Int?
    let pin: String?
    let source: String

    init(_ hit: EvidenceFindHit) {
      id = hit.id
      text = hit.text
      status = hit.status
      origin = hit.origin.label
      reuseCount = hit.reuseCount
      pin = hit.pin
      source = hit.source
    }
  }

  let command = "evidence find"
  let verdict: Verdict
  let query: String
  let pkg: String?
  let hits: [Hit]
  /// Non-fatal degradation named rather than silently dropped: an unreadable or partly-corrupt
  /// `claims.jsonl`, or a cache line that doesn't decode (``EvidenceCacheContents/findings``).
  let notes: [String]
  let message: String
}

/// The deterministic body of `evidence find`: searches every repo `<slug>.evidence/claims.jsonl`
/// plus the user-level evidence reuse cache (`--cache-home`, defaulting to `$HOME`, matching
/// `context-pack`'s convention) for claims matching a free-text query. Factored out of the
/// `ParsableCommand` so it's testable without argument parsing or stdout (matches
/// `EvidenceCaptureRun`/`ContextPackRun`).
enum EvidenceFindRun {
  static func run(query text: String, pkg pkgRaw: String?, root: URL, cacheHome: String?)
    -> EvidenceFindReport
  {
    let pkg: EvidenceQuery.PackagePin?
    if let pkgRaw {
      guard let parsed = EvidenceQuery.PackagePin(rawValue: pkgRaw) else {
        return blocked(
          query: text, pkg: pkgRaw,
          "--pkg `\(pkgRaw)` must be `<name>@<version>`")
      }
      pkg = parsed
    } else {
      pkg = nil
    }
    let query = EvidenceQuery(text: text, pkg: pkg)

    let repo = repoHits(query: query, root: root)
    let cache: (hits: [EvidenceFindHit], notes: [String])
    switch cacheHits(query: query, pkg: pkg, cacheHome: cacheHome) {
    case .failure(let failure): return blocked(query: text, pkg: pkgRaw, failure.message)
    case .success(let value): cache = value
    }

    let hits = EvidenceFind.sorted(repo.hits + cache.hits)
    let notes = repo.notes + cache.notes
    let message =
      hits.isEmpty
      ? "no matches for \"\(text)\"" : "\(hits.count) hit(s) for \"\(text)\""
    return EvidenceFindReport(
      verdict: .green, query: text, pkg: pkgRaw, hits: hits.map(EvidenceFindReport.Hit.init),
      notes: notes, message: message)
  }

  static func render(_ report: EvidenceFindReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
    case .human:
      var lines = ["evidence find: \(report.message)"]
      for hit in report.hits {
        let reuse = hit.reuseCount.map { " reuse=\($0)" } ?? ""
        let pin = hit.pin.map { " pin=\($0)" } ?? ""
        lines.append(
          "  \(hit.id) [\(hit.status.rawValue)] origin=\(hit.origin)\(reuse)\(pin) "
            + "source=\(hit.source)")
      }
      for note in report.notes { lines.append("  note: \(note)") }
      return lines.joined(separator: "\n")
    }
  }

  // MARK: - Repo claims

  private static func repoHits(query: EvidenceQuery, root: URL)
    -> (hits: [EvidenceFindHit], notes: [String])
  {
    var hits: [EvidenceFindHit] = []
    var notes: [String] = []
    for path in RepositoryFiles.list(root: root, under: "docs", where: isClaimsFile) {
      guard let data = FileManager.default.contents(atPath: root.appending(path: path).path)
      else {
        notes.append("can't read \(path)")
        continue
      }
      let decoded = ClaimJSON.decode(data)
      if decoded.invalidLines > 0 {
        notes.append(
          "\(decoded.invalidLines) line(s) of \(path) didn't parse as a claim and were skipped")
      }
      hits += EvidenceFind.repoHits(decoded.claims, query: query, source: path)
    }
    return (hits, notes)
  }

  /// `path` is relative to `docs` (``RepositoryFiles/list(root:under:where:)``'s contract
  /// includes the `docs/` prefix it was given), so only the trailing components matter.
  private static func isClaimsFile(_ path: String) -> Bool {
    let components = path.split(separator: "/")
    guard components.count >= 2, components.last == "claims.jsonl" else { return false }
    return components[components.count - 2].hasSuffix(".evidence")
  }

  // MARK: - Evidence reuse cache

  /// A gathering-stage failure message (missing `--cache-home`). Wraps `String` only because
  /// `Result`'s failure type must conform to `Error`.
  private struct GatherFailure: Error, Sendable, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
  }

  private static func cacheHits(
    query: EvidenceQuery, pkg: EvidenceQuery.PackagePin?, cacheHome: String?
  ) -> Swift.Result<(hits: [EvidenceFindHit], notes: [String]), GatherFailure> {
    guard let cacheHome = cacheHome ?? ProcessInfo.processInfo.environment["HOME"] else {
      return .failure(
        GatherFailure("missing required option '--cache-home <path>' ($HOME is not set)"))
    }
    let layout = EvidenceCacheLayout(home: cacheHome)
    let store = EvidenceCacheStore(home: URL(filePath: cacheHome, directoryHint: .isDirectory))

    // A `--pkg` filter goes straight to that pin's own bucket file, never a scan of every pin:
    // the one file that could hold a match is named by the pin itself.
    let buckets: [EvidenceCacheBucket] =
      pkg.map { [.package(pin: "\($0.identity)@\($0.version)")] }
      ?? cacheBuckets(root: layout.root)

    var hits: [EvidenceFindHit] = []
    var notes: [String] = []
    for bucket in buckets {
      let contents: EvidenceCacheContents
      do {
        contents = try store.contents(of: bucket)
      } catch {
        notes.append("evidence cache: can't read \(bucket): \(error)")
        continue
      }
      notes += contents.findings.map { "evidence cache: \($0.message)" }
      let source = (try? layout.file(bucket)) ?? "evidence cache"
      hits += EvidenceFind.cacheHits(contents.claims, query: query, source: source)
    }
    return .success((hits, notes))
  }

  /// Every bucket file that currently exists under the cache root: package pins at the top level
  /// (`<pkg>@<version>.jsonl`) and SDK pins under `sdk/`. `verdicts.jsonl` holds only checker
  /// verdicts, never claims, so it's never a source of hits.
  private static func cacheBuckets(root: String) -> [EvidenceCacheBucket] {
    let fm = FileManager.default
    var buckets: [EvidenceCacheBucket] = []
    for name in (try? fm.contentsOfDirectory(atPath: root)) ?? []
    where name.hasSuffix(".jsonl") && name.contains("@") {
      buckets.append(.package(pin: String(name.dropLast(".jsonl".count))))
    }
    for name in (try? fm.contentsOfDirectory(atPath: root + "/sdk")) ?? []
    where name.hasSuffix(".jsonl") {
      buckets.append(.sdk(pin: String(name.dropLast(".jsonl".count))))
    }
    return buckets
  }

  private static func blocked(query: String, pkg: String?, _ message: String)
    -> EvidenceFindReport
  {
    EvidenceFindReport(
      verdict: .blocked, query: query, pkg: pkg, hits: [], notes: [], message: message)
  }
}

struct EvidenceFindCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "find",
    abstract: "Find repo claims and cached user claims matching a query, with status and origin.",
    discussion:
      "Searches every repo <slug>.evidence/claims.jsonl and the user-level evidence reuse cache "
      + "for claims whose text or quote contains the query (case-insensitive substring). --pkg "
      + "<name>@<version> restricts to that exact pin, never a prefix. Exit 0 with hits or with "
      + "\"no matches\"; exit 2 for a malformed --pkg or an unreadable --cache-home.")

  @Argument(help: "The claim query, e.g. a package or symbol name.")
  var query: String

  @Option(help: "Restrict to claims pinned to name@version, exact.")
  var pkg: String?

  @Option(help: "The evidence reuse cache's home directory; defaults to $HOME.")
  var cacheHome: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let report = EvidenceFindRun.run(query: query, pkg: pkg, root: root, cacheHome: cacheHome)
    Console.write(EvidenceFindRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
