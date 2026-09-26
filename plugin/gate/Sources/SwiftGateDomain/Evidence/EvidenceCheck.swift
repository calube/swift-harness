import CryptoKit
import Foundation

/// Everything `evidence check` reads, handed in by the caller so the per-kind rules stay IO-free.
/// The command resolves each lookup against the working tree, or against a ref for `--at`.
public protocol EvidenceSources {
  /// The text of a repo-relative file (a codebase path or `.build/checkouts/<pkg>/…`) at the ref
  /// under check; `nil` when the file doesn't exist there.
  func repoFile(_ path: String) -> String?
  /// The bytes of a file under the design's `<slug>.evidence/` root, addressed relative to that
  /// root (`snapshots/…`, `captures/…`, `probes/…`, `answers.jsonl`); `nil` when absent.
  func evidenceFile(_ path: String) -> Data?
  /// The raw bytes of the target's `Package.resolved`; `nil` when it has none.
  var packageResolved: Data? { get }
  /// The SDK version now in effect; `nil` when it couldn't be determined.
  var sdkVersion: String? { get }
  /// The first prefix of the repo-relative `path` that is a symbolic link on disk; `nil` when
  /// none is. A link can hide a package checkout, or a file outside the repo, behind a plain path.
  func repoSymlink(_ path: String) -> String?
  /// Like ``repoSymlink(_:)``, for a path relative to the design's evidence root.
  func evidenceSymlink(_ path: String) -> String?
}

/// A value-typed ``EvidenceSources`` whose contents were read up front.
public struct InMemoryEvidenceSources: EvidenceSources, Sendable, Equatable {
  public var repoFiles: [String: String]
  public var evidenceFiles: [String: Data]
  public var packageResolved: Data?
  public var sdkVersion: String?

  public init(
    repoFiles: [String: String] = [:], evidenceFiles: [String: Data] = [:],
    packageResolved: Data? = nil, sdkVersion: String? = nil
  ) {
    self.repoFiles = repoFiles
    self.evidenceFiles = evidenceFiles
    self.packageResolved = packageResolved
    self.sdkVersion = sdkVersion
  }

  /// Files held by value are never links.
  public func repoSymlink(_ path: String) -> String? { nil }
  public func evidenceSymlink(_ path: String) -> String? { nil }

  public func repoFile(_ path: String) -> String? { repoFiles[path] }
  public func evidenceFile(_ path: String) -> Data? { evidenceFiles[path] }
}

/// Spec §6.2: a plain check judges claims as recorded; `--at <ref>` re-checks them against a later
/// state, where drift is `stale` (or a relocation) rather than a failure of the claim's author.
public enum EvidenceCheckMode: Sendable, Equatable {
  case workingTree
  case atRef
}

/// Why a citation's `loc` can't be resolved identically on every machine and checkout.
public enum LocPathProblem: String, Sendable, Equatable, CaseIterable {
  case empty
  case absolute
  case homeRelative = "home-relative"
  case homeVariable = "home-variable"
  case escapesRepoRoot = "escapes-repo-root"
  /// A `..` anywhere, even one that stays inside the root: a loc names its file one way only, so
  /// no respelling can move it out of the class (checkout or not) its rules depend on.
  case parentReference = "parent-reference"
  /// Under a `.build` directory but not a file of `.build/checkouts/<pkg>/`: a bare clone or a
  /// build product carries no pin to check.
  case buildOutput = "build-output"
  case symlink
}

public enum RepoRelativePath {
  /// `nil` when `path` stays inside the repository root without naming a machine-specific
  /// location. Only whole components are judged, so a directory that happens to be called
  /// `Users` or `home` is fine.
  public static func problem(_ path: String) -> LocPathProblem? {
    if path.isEmpty { return .empty }
    if path.hasPrefix("/") { return .absolute }
    if path.hasPrefix("~") { return .homeRelative }
    var depth = 0
    var climbs = false
    for component in path.split(separator: "/") {
      switch component {
      case "$HOME", "${HOME}":
        return .homeVariable
      case ".":
        continue
      case "..":
        if depth == 0 { return .escapesRepoRoot }
        depth -= 1
        climbs = true
      default:
        depth += 1
      }
    }
    return climbs ? .parentReference : nil
  }
}

public enum PathPrefixes {
  /// `a`, `a/b`, `a/b/c` for `a/./b//c`: every directory a lookup of the path walks through.
  public static func of(_ path: String) -> [String] {
    var prefixes: [String] = []
    var current = ""
    for component in path.split(separator: "/") where component != "." {
      current = current.isEmpty ? String(component) : current + "/" + component
      prefixes.append(current)
    }
    return prefixes
  }
}

/// The `loc` shape each citation kind requires (raw value = the form, for messages).
public enum LocForm: String, Sendable, Equatable, CaseIterable {
  case fileLineRange = "<path>:L<start>[-L<end>]"
  case snapshot = "snapshots/<name>"
  case capture = "captures/<sha256>.txt"
  case probe = "probes/Probe_<id>.swift"
  case answer = "answers.jsonl#<runId>/<n>"
}

/// Why a claim's mechanical check failed: the claim as recorded is not backed by its citation.
public enum EvidenceCheckFailure: Sendable, Equatable {
  case locPath(LocPathProblem)
  case locMalformed(expected: LocForm)
  case quoteMissing
  case quoteNotFound
  case citedFileMissing
  case lineRangeOutOfBounds(lineCount: Int)
  case pinMissing
  case pinMalformed
  /// A `.build/checkouts/<pkg>` citation pinned to a different package than the one it cites.
  case pinPackageMismatch(pinned: String, cited: String)
  case packageResolvedMissing
  case packageResolvedMalformed
  case packageNotResolved(identity: String)
  case pinVersionMismatch(pinned: String, resolved: String)
  case storedFileMissing
  /// The capture's file name and its `pin` disagree about which output it is.
  case captureNameMismatch
  case captureHashMismatch(pinned: String, actual: String)
  case sdkVersionUnavailable
  case probeVerdictMissing
  case probeVerdictMalformed(detail: String)
  case probeVerdictForOtherClaim(claimId: String)
  case probeFailed
  /// The verdict records no hash of the snippet and wrapper it judged, so nothing ties it to a
  /// probe that was built.
  case probeVerdictUnbound
  /// `path` is evidence-root relative: the snippet or the wrapper the verdict hashed.
  case probeSourceMissing(path: String)
  case probeSourceMismatch(path: String)
  case answersFileMissing
  case answersFileMalformed(line: Int)
  case answerNotFound(runId: String, ordinal: Int)
  case answerQuestionMismatch
  /// Another claim in the same file has this id; none of them is judged, so a later line can't
  /// mask an earlier one.
  case duplicateClaimID
}

/// Why a claim no longer reflects the source it was checked against (spec §8.5).
public enum EvidenceStaleReason: Sendable, Equatable {
  case citedFileGone
  case quoteGone
  case pinChanged(pinned: String, resolved: String)
  case sdkChanged(pinned: String, current: String)
  case probePinChanged(identity: String, pinned: String, resolved: String?)
}

public struct EvidenceCheckResult: Sendable, Equatable {
  public enum Outcome: Sendable, Equatable {
    case passed
    /// The quote was found elsewhere in the same file; `loc` is the citation's new location.
    case relocated(loc: String)
    case failed(EvidenceCheckFailure)
    case stale(EvidenceStaleReason)
  }

  public let claimID: String
  public let kind: Citation.Kind
  public let outcome: Outcome

  public init(claimID: String, kind: Citation.Kind, outcome: Outcome) {
    self.claimID = claimID
    self.kind = kind
    self.outcome = outcome
  }

  /// The status the claim moves to (spec §5.2). A probe takes its verdict directly
  /// (`supported`/`refuted`); `nil` when a probe claim reached no verdict at all (its verdict
  /// file is missing, malformed or unusable), which still fails the check.
  public var claimStatus: Claim.Status? {
    switch outcome {
    case .passed, .relocated:
      return kind == .probe ? .supported : .quoteOk
    case .stale:
      return .stale
    case .failed(let failure):
      guard kind == .probe else { return .quoteFail }
      return failure == .probeFailed ? .refuted : nil
    }
  }

  /// `evidence check` exits 1 when any result fails or is stale.
  public var isFailing: Bool {
    switch outcome {
    case .passed, .relocated: return false
    case .failed, .stale: return true
    }
  }
}

/// `Probe_<id>.verdict.json` under `<slug>.evidence/probes/`: written by `swiftgate probe`, read
/// by `evidence check`. Both sides use this type so the file has one definition.
public struct ProbeVerdictRecord: Sendable, Equatable, Codable {
  public enum Outcome: String, Sendable, Equatable, Codable, CaseIterable {
    case pass
    case fail
  }

  public struct Diagnostic: Sendable, Equatable, Codable {
    public let file: String
    public let line: Int
    public let column: Int
    public let level: LintLevel
    public let message: String

    public init(file: String, line: Int, column: Int, level: LintLevel, message: String) {
      self.file = file
      self.line = line
      self.column = column
      self.level = level
      self.message = message
    }
  }

  public let claimId: String
  public let verdict: Outcome
  public let diagnostics: [Diagnostic]
  /// Package identity → resolved version the probe was built against.
  public let pins: [String: String]
  public let sdk: String
  /// Lowercase hex SHA-256 of the `<id>.snippet.swift` bytes the probe built. Optional only so a
  /// verdict without it still decodes and fails `probeVerdictUnbound` by name.
  public let snippetSha256: String?
  /// Lowercase hex SHA-256 of the generated `Probe_<id>.swift`, the file a probe claim cites.
  public let sourceSha256: String?

  public init(
    claimId: String, verdict: Outcome, diagnostics: [Diagnostic], pins: [String: String],
    sdk: String, snippetSha256: String? = nil, sourceSha256: String? = nil
  ) {
    self.claimId = claimId
    self.verdict = verdict
    self.diagnostics = diagnostics
    self.pins = pins
    self.sdk = sdk
    self.snippetSha256 = snippetSha256
    self.sourceSha256 = sourceSha256
  }

  public static let snippetSuffix = ".snippet.swift"

  /// `probes/<id>.snippet.swift`, relative to the evidence root: the probe's input.
  public static func snippetPath(forClaimID claimID: String) -> String {
    "probes/" + claimID + snippetSuffix
  }

  /// `probes/Probe_<id>.verdict.json`, relative to the evidence root.
  public static func path(forClaimID claimID: String) -> String {
    "probes/" + ProbeIdentifier.enumName(forClaimID: claimID) + ".verdict.json"
  }

  public static func encode(_ record: ProbeVerdictRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(record)
    data.append(UInt8(ascii: "\n"))
    return data
  }
}

/// One line of `<slug>.evidence/answers.jsonl`: a user's answer to a question the design skill
/// asked during run `runId`.
public struct AnswerRecord: Sendable, Equatable, Codable {
  public let runId: String
  public let question: String
  public let options: [String]
  public let answer: String
  public let at: Date

  public init(runId: String, question: String, options: [String], answer: String, at: Date) {
    self.runId = runId
    self.question = question
    self.options = options
    self.answer = answer
    self.at = at
  }
}

public enum AnswerRecordJSON {
  public enum DecodeError: Error, Sendable, Equatable {
    /// 1-based line number of the first line that isn't a valid record.
    case malformedLine(Int)
  }

  public static func encodeLine(_ record: AnswerRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(record)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  /// Unlike claims, a bad line fails the whole file: an answer record is the only proof of a user
  /// decision, so a torn file must not quietly shift every later ordinal.
  public static func decode(_ data: Data) throws(DecodeError) -> [AnswerRecord] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var records: [AnswerRecord] = []
    for (index, line) in data.split(
      separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false
    ).enumerated() where !line.isEmpty {
      guard let record = try? decoder.decode(AnswerRecord.self, from: Data(line)) else {
        throw .malformedLine(index + 1)
      }
      records.append(record)
    }
    return records
  }
}

public enum CaptureDigest {
  /// Lowercase hex SHA-256 of the stored output: a capture's file-name stem, and its `pin` after
  /// the `sha256:` prefix.
  public static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { byte in
      let hex = String(byte, radix: 16)
      return byte < 0x10 ? "0" + hex : hex
    }.joined()
  }
}

/// The D3 per-kind mechanical rules (spec §5.2 table, §6.2).
public enum EvidenceCheck {
  public static func check(
    _ claims: [Claim], sources: some EvidenceSources, mode: EvidenceCheckMode
  ) -> [EvidenceCheckResult] {
    var checker = Checker(sources: sources, mode: mode)
    let counts = Dictionary(claims.map { ($0.id, 1) }, uniquingKeysWith: +)
    return claims.map { claim in
      let outcome: EvidenceCheckResult.Outcome =
        counts[claim.id, default: 0] > 1
        ? .failed(.duplicateClaimID) : checker.outcome(for: claim)
      return EvidenceCheckResult(claimID: claim.id, kind: claim.citation.kind, outcome: outcome)
    }
  }
}

private enum ResolvedPinsState {
  case missing
  case malformed
  case pins([String: String])
}

private struct Checker<Sources: EvidenceSources> {
  typealias Outcome = EvidenceCheckResult.Outcome

  let sources: Sources
  let mode: EvidenceCheckMode
  /// By project directory, `""` for the repo root.
  private var resolvedCache: [String: ResolvedPinsState] = [:]

  init(sources: Sources, mode: EvidenceCheckMode) {
    self.sources = sources
    self.mode = mode
  }

  mutating func outcome(for claim: Claim) -> Outcome {
    let citation = claim.citation
    switch citation.kind {
    case .file: return fileOutcome(citation)
    case .snapshot: return snapshotOutcome(citation)
    case .capture: return captureOutcome(citation)
    case .probe: return probeOutcome(claim)
    case .answer: return answerOutcome(citation)
    }
  }

  /// The root's pins come from the `Package.resolved` the caller names; a nested project's from
  /// the one beside its `.build`, since that's the file its checkouts were resolved from.
  private mutating func resolvedPins(project: String = "") -> ResolvedPinsState {
    if let cached = resolvedCache[project] { return cached }
    let state: ResolvedPinsState
    let data =
      project.isEmpty
      ? sources.packageResolved
      : sources.repoFile(project + "/Package.resolved").map { Data($0.utf8) }
    if let data {
      if let pins = try? ResolvedPins.parse(data) {
        state = .pins(pins)
      } else {
        state = .malformed
      }
    } else {
      state = .missing
    }
    resolvedCache[project] = state
    return state
  }

  // MARK: file

  private mutating func fileOutcome(_ citation: Citation) -> Outcome {
    let parsed = FileLoc.parse(citation.loc)
    if let problem = RepoRelativePath.problem(parsed?.rawPath ?? citation.loc) {
      return .failed(.locPath(problem))
    }
    guard let loc = parsed else { return .failed(.locMalformed(expected: .fileLineRange)) }
    if sources.repoSymlink(loc.path) != nil { return .failed(.locPath(.symlink)) }
    let checkout = loc.checkout
    if checkout == .buildOutput { return .failed(.locPath(.buildOutput)) }
    guard let quote = citation.quote, !quote.isEmpty else { return .failed(.quoteMissing) }
    if case .package(let package, let project) = checkout {
      if let outcome = packagePinOutcome(citation.pin, package: package, project: project) {
        return outcome
      }
    }
    guard let text = sources.repoFile(loc.path) else {
      return mode == .atRef ? .stale(.citedFileGone) : .failed(.citedFileMissing)
    }
    let lines = TextLines.split(text)
    let inBounds = loc.end <= lines.count
    if inBounds, lines[(loc.start - 1)..<loc.end].joined(separator: "\n").contains(quote) {
      return .passed
    }
    guard mode == .atRef else {
      return inBounds
        ? .failed(.quoteNotFound) : .failed(.lineRangeOutOfBounds(lineCount: lines.count))
    }
    guard let span = TextLines.nearestSpan(of: quote, in: lines, near: loc.start) else {
      return .stale(.quoteGone)
    }
    return .relocated(loc: FileLoc(path: loc.path, start: span.start, end: span.end).rendered)
  }

  private mutating func packagePinOutcome(_ pin: String?, package: String, project: String)
    -> Outcome?
  {
    guard let pin else { return .failed(.pinMissing) }
    guard let at = pin.lastIndex(of: "@"), at != pin.startIndex,
      pin.index(after: at) != pin.endIndex
    else { return .failed(.pinMalformed) }
    let pinnedPackage = String(pin[..<at])
    let pinnedVersion = String(pin[pin.index(after: at)...])
    guard pinnedPackage.lowercased() == package.lowercased() else {
      return .failed(.pinPackageMismatch(pinned: pinnedPackage, cited: package))
    }
    switch resolvedPins(project: project) {
    case .missing: return .failed(.packageResolvedMissing)
    case .malformed: return .failed(.packageResolvedMalformed)
    case .pins(let pins):
      let identity = package.lowercased()
      guard let resolved = pins[identity] else {
        return .failed(.packageNotResolved(identity: identity))
      }
      guard resolved == pinnedVersion else {
        return mode == .atRef
          ? .stale(.pinChanged(pinned: pinnedVersion, resolved: resolved))
          : .failed(.pinVersionMismatch(pinned: pinnedVersion, resolved: resolved))
      }
      return nil
    }
  }

  // MARK: snapshot

  private func snapshotOutcome(_ citation: Citation) -> Outcome {
    if let problem = RepoRelativePath.problem(citation.loc) { return .failed(.locPath(problem)) }
    guard Self.isStoredFile(citation.loc, under: "snapshots/") else {
      return .failed(.locMalformed(expected: .snapshot))
    }
    if sources.evidenceSymlink(citation.loc) != nil { return .failed(.locPath(.symlink)) }
    guard let pin = citation.pin, !pin.isEmpty else { return .failed(.pinMissing) }
    guard let quote = citation.quote, !quote.isEmpty else { return .failed(.quoteMissing) }
    guard let data = sources.evidenceFile(citation.loc) else {
      return .failed(.storedFileMissing)
    }
    guard String(decoding: data, as: UTF8.self).contains(quote) else {
      return .failed(.quoteNotFound)
    }
    if mode == .atRef {
      guard let current = sources.sdkVersion else { return .failed(.sdkVersionUnavailable) }
      if current != pin { return .stale(.sdkChanged(pinned: pin, current: current)) }
    }
    return .passed
  }

  // MARK: capture

  private func captureOutcome(_ citation: Citation) -> Outcome {
    if let problem = RepoRelativePath.problem(citation.loc) { return .failed(.locPath(problem)) }
    let prefix = "captures/"
    let suffix = ".txt"
    guard citation.loc.hasPrefix(prefix), citation.loc.hasSuffix(suffix) else {
      return .failed(.locMalformed(expected: .capture))
    }
    let nameHash = String(citation.loc.dropFirst(prefix.count).dropLast(suffix.count))
    guard Self.isSHA256Hex(nameHash) else { return .failed(.locMalformed(expected: .capture)) }
    guard let pin = citation.pin else { return .failed(.pinMissing) }
    let pinPrefix = "sha256:"
    guard pin.hasPrefix(pinPrefix), Self.isSHA256Hex(String(pin.dropFirst(pinPrefix.count)))
    else { return .failed(.pinMalformed) }
    guard pinPrefix + nameHash == pin else { return .failed(.captureNameMismatch) }
    if sources.evidenceSymlink(citation.loc) != nil { return .failed(.locPath(.symlink)) }
    guard let data = sources.evidenceFile(citation.loc) else {
      return .failed(.storedFileMissing)
    }
    let actual = pinPrefix + CaptureDigest.sha256Hex(data)
    guard actual == pin else { return .failed(.captureHashMismatch(pinned: pin, actual: actual)) }
    if let quote = citation.quote, !String(decoding: data, as: UTF8.self).contains(quote) {
      return .failed(.quoteNotFound)
    }
    return .passed
  }

  // MARK: probe

  private mutating func probeOutcome(_ claim: Claim) -> Outcome {
    let loc = claim.citation.loc
    if let problem = RepoRelativePath.problem(loc) { return .failed(.locPath(problem)) }
    guard loc == "probes/" + ProbeIdentifier.fileName(forClaimID: claim.id) else {
      return .failed(.locMalformed(expected: .probe))
    }
    guard let data = sources.evidenceFile(ProbeVerdictRecord.path(forClaimID: claim.id)) else {
      return .failed(.probeVerdictMissing)
    }
    let record: ProbeVerdictRecord
    do {
      record = try JSONDecoder().decode(ProbeVerdictRecord.self, from: data)
    } catch {
      return .failed(.probeVerdictMalformed(detail: String(describing: error)))
    }
    guard record.claimId == claim.id else {
      return .failed(.probeVerdictForOtherClaim(claimId: record.claimId))
    }
    guard let snippetHash = record.snippetSha256, let sourceHash = record.sourceSha256 else {
      return .failed(.probeVerdictUnbound)
    }
    let bound = [
      (ProbeVerdictRecord.snippetPath(forClaimID: claim.id), snippetHash), (loc, sourceHash),
    ]
    for (path, hash) in bound {
      if sources.evidenceSymlink(path) != nil { return .failed(.locPath(.symlink)) }
      guard let data = sources.evidenceFile(path) else {
        return .failed(.probeSourceMissing(path: path))
      }
      guard CaptureDigest.sha256Hex(data) == hash else {
        return .failed(.probeSourceMismatch(path: path))
      }
    }
    if !record.pins.isEmpty {
      switch resolvedPins() {
      case .missing: return .failed(.packageResolvedMissing)
      case .malformed: return .failed(.packageResolvedMalformed)
      case .pins(let pins):
        for identity in record.pins.keys.sorted() {
          let pinned = record.pins[identity] ?? ""
          let resolved = pins[identity.lowercased()]
          if resolved != pinned {
            return .stale(
              .probePinChanged(identity: identity, pinned: pinned, resolved: resolved))
          }
        }
      }
    }
    guard let current = sources.sdkVersion else { return .failed(.sdkVersionUnavailable) }
    if current != record.sdk { return .stale(.sdkChanged(pinned: record.sdk, current: current)) }
    switch record.verdict {
    case .pass: return .passed
    case .fail: return .failed(.probeFailed)
    }
  }

  // MARK: answer

  private func answerOutcome(_ citation: Citation) -> Outcome {
    let loc = citation.loc
    let hash = loc.firstIndex(of: "#")
    let file = hash.map { String(loc[..<$0]) } ?? loc
    if let problem = RepoRelativePath.problem(file) { return .failed(.locPath(problem)) }
    guard let hash, file == "answers.jsonl" else {
      return .failed(.locMalformed(expected: .answer))
    }
    if sources.evidenceSymlink(file) != nil { return .failed(.locPath(.symlink)) }
    let reference = loc[loc.index(after: hash)...]
    guard let slash = reference.lastIndex(of: "/"),
      slash != reference.startIndex,
      let ordinal = Int(reference[reference.index(after: slash)...]),
      ordinal >= 1
    else { return .failed(.locMalformed(expected: .answer)) }
    let runId = String(reference[..<slash])
    guard let data = sources.evidenceFile("answers.jsonl") else {
      return .failed(.answersFileMissing)
    }
    let records: [AnswerRecord]
    do {
      records = try AnswerRecordJSON.decode(data)
    } catch {
      switch error {
      case .malformedLine(let line): return .failed(.answersFileMalformed(line: line))
      }
    }
    let run = records.filter { $0.runId == runId }
    guard ordinal <= run.count else {
      return .failed(.answerNotFound(runId: runId, ordinal: ordinal))
    }
    if let quote = citation.quote, !run[ordinal - 1].question.contains(quote) {
      return .failed(.answerQuestionMismatch)
    }
    return .passed
  }

  // MARK: helpers

  private static func isStoredFile(_ loc: String, under prefix: String) -> Bool {
    loc.hasPrefix(prefix) && loc.count > prefix.count && !loc.hasSuffix("/")
  }

  private static func isSHA256Hex(_ text: String) -> Bool {
    text.utf8.count == 64
      && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }
}

/// A `file` citation's `loc`: `<path>:L<start>` or `<path>:L<start>-L<end>`, 1-based, inclusive.
private struct FileLoc {
  let rawPath: String
  let path: String
  let start: Int
  let end: Int

  /// `path` comes back without `.` or empty components; `..` is the path rule's to reject, on
  /// `rawPath`.
  static func parse(_ loc: String) -> FileLoc? {
    guard let marker = loc.range(of: ":L", options: .backwards) else { return nil }
    let rawPath = String(loc[..<marker.lowerBound])
    let path = PathPrefixes.of(rawPath).last ?? ""
    let parts = loc[marker.upperBound...].components(separatedBy: "-L")
    guard !path.isEmpty, parts.count <= 2, let start = Int(parts[0]), start >= 1 else {
      return nil
    }
    let end = parts.count == 2 ? Int(parts[1]) : start
    guard let end, end >= start else { return nil }
    return FileLoc(path: path, start: start, end: end, rawPath: rawPath)
  }

  init(path: String, start: Int, end: Int, rawPath: String? = nil) {
    self.rawPath = rawPath ?? path
    self.path = path
    self.start = start
    self.end = end
  }

  var rendered: String {
    start == end ? "\(path):L\(start)" : "\(path):L\(start)-L\(end)"
  }

  enum Checkout: Equatable {
    /// A file of `<project>/.build/checkouts/<package>/`; `project` is `""` at the repo root.
    case package(String, project: String)
    case buildOutput
  }

  /// `.build` and `checkouts` compare case-insensitively: a case-insensitive file system reads
  /// `.BUILD/checkouts/…` from the same checkout, so it must meet the same pin.
  var checkout: Checkout? {
    let components = path.split(separator: "/")
    guard let build = components.firstIndex(where: { $0.lowercased() == ".build" }) else {
      return nil
    }
    guard components.count > build + 3, components[build + 1].lowercased() == "checkouts" else {
      return .buildOutput
    }
    return .package(
      String(components[build + 2]), project: components[..<build].joined(separator: "/"))
  }
}

private enum TextLines {
  /// Lines without their terminators; a CRLF file splits like an LF one. A final terminator
  /// ends the last line rather than starting an empty one, as context-pack counts lines.
  static func split(_ text: String) -> [String] {
    // `\r\n` is one `Character`, so it has to be named as a separator of its own.
    var lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
      .map(String.init)
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  /// The line span of the occurrence of `quote` closest to line `near`.
  static func nearestSpan(of quote: String, in lines: [String], near: Int) -> (
    start: Int, end: Int
  )? {
    let text = lines.joined(separator: "\n")
    let quoteNewlines = quote.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    var best: (start: Int, end: Int)?
    var searchStart = text.startIndex
    while let match = text.range(of: quote, range: searchStart..<text.endIndex) {
      let start = text[..<match.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
      if best.map({ abs(start - near) < abs($0.start - near) }) ?? true {
        best = (start, start + quoteNewlines)
      }
      searchStart = text.index(after: match.lowerBound)
    }
    return best
  }
}
