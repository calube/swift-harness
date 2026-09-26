import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway repository for `evidence check`: real commits, so `--at <ref>` reads what git
/// itself has at that ref. Never this checkout, whose git common dir other worktrees share.
private struct EvidenceRepo {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  static let design = "docs/ordering/designs/queue.md"
  static let layout = EvidenceLayout(designDocPath: design)
  static let source = "Sources/Queue/Queue.swift"
  static let quote = "public func enqueue(_ order: Order) async throws"
  static let original = """
    import Foundation

    public struct Queue {
      \(quote)
    }

    """

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  init() async throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-evidence-check-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func git(_ arguments: String...) async throws {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      struct GitFailure: Error { let message: String }
      throw GitFailure(message: "git \(arguments): \(output.stderr.text)")
    }
  }

  func commitAll(_ message: String) async throws {
    try await git("add", "-A")
    try await git("commit", "-q", "-m", message)
  }

  func write(_ path: String, _ data: Data) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }

  func write(_ path: String, _ text: String) throws { try write(path, Data(text.utf8)) }

  func writeClaims(_ claims: [Claim]) throws {
    var data = Data()
    for claim in claims { data.append(try ClaimJSON.encodeLine(claim)) }
    try write(Self.layout.claimsFile, data)
  }

  /// Writes the verdict with a snippet and wrapper beside it, bound by their hashes the way
  /// `probe` writes them.
  func writeVerdict(_ record: ProbeVerdictRecord) throws {
    let snippet = Data("static func run() {}\n".utf8)
    let wrapper = Data(
      ProbeWrapper.source(
        claimID: record.claimId, snippet: String(decoding: snippet, as: UTF8.self)
      )
      .utf8)
    try write(Self.layout.probesDirectory + "/\(record.claimId).snippet.swift", snippet)
    try write(
      Self.layout.probesDirectory + "/" + ProbeIdentifier.fileName(forClaimID: record.claimId),
      wrapper)
    guard
      var bound = try JSONSerialization.jsonObject(with: try ProbeVerdictRecord.encode(record))
        as? [String: Any]
    else { throw CocoaError(.coderReadCorrupt) }
    bound["snippetSha256"] = CaptureDigest.sha256Hex(snippet)
    bound["sourceSha256"] = CaptureDigest.sha256Hex(wrapper)
    try write(
      Self.layout.root + "/" + ProbeVerdictRecord.path(forClaimID: record.claimId),
      try JSONSerialization.data(withJSONObject: bound, options: [.sortedKeys]))
  }

  /// A verbatim `Package.resolved` from a real SwiftPM resolve (see `Tests/Fixtures/README.md`),
  /// which pins `swift-composable-architecture` at 1.26.2.
  func writeRealPackageResolved() throws {
    try write("Package.resolved", try Fixture.data("Doctor/Package.resolved-CounterFeature.json"))
  }

  func check(at ref: String? = nil, sdk: String? = nil, design: String = Self.design) async
    -> EvidenceCheckRun.Outcome
  {
    await EvidenceCheckRun.run(
      options: .init(design: design, at: ref, packageResolved: "Package.resolved", sdk: sdk),
      root: root, runner: runner)
  }

  static func fileClaim(
    id: String = "ev-queue-enqueue-is-async", loc: String = "\(source):L4", pin: String = "HEAD",
    quote: String = quote
  ) -> Claim {
    Claim(
      id: id, lane: "codebase", text: "Enqueue is async.",
      citation: Citation(kind: .file, loc: loc, pin: pin, quote: quote), status: .quoteOk)
  }

  static let probeClaimID = "ev-queue-reducer-api-exists"

  static var probeClaim: Claim {
    Claim(
      id: probeClaimID, lane: "packages", text: "The reducer API exists.",
      citation: Citation(
        kind: .probe, loc: "probes/" + ProbeIdentifier.fileName(forClaimID: probeClaimID),
        pin: "swift-composable-architecture@1.26.2"),
      status: .new)
  }

  static func verdict(
    _ outcome: ProbeVerdictRecord.Outcome, tca: String = "1.26.2", sdk: String = "26.2"
  ) -> ProbeVerdictRecord {
    ProbeVerdictRecord(
      claimId: probeClaimID, verdict: outcome, diagnostics: [],
      pins: ["swift-composable-architecture": tca], sdk: sdk)
  }
}

/// Decodes one `--json` element and refuses any key outside `{id, status, loc}`, so an extra
/// field the design skill would copy into `claims.jsonl` fails here first.
private struct StrictLine: Decodable, Equatable {
  let id: String
  let status: Claim.Status
  let loc: String?

  private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  init(id: String, status: Claim.Status, loc: String?) {
    self.id = id
    self.status = status
    self.loc = loc
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: AnyKey.self)
    let unexpected = container.allKeys.map(\.stringValue).filter {
      !["id", "status", "loc"].contains($0)
    }
    guard unexpected.isEmpty else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "unexpected keys \(unexpected)"))
    }
    id = try container.decode(String.self, forKey: AnyKey(stringValue: "id"))
    status = try container.decode(Claim.Status.self, forKey: AnyKey(stringValue: "status"))
    loc = try container.decodeIfPresent(String.self, forKey: AnyKey(stringValue: "loc"))
  }
}

private func jsonLines(_ outcome: EvidenceCheckRun.Outcome) throws -> [StrictLine] {
  try JSONDecoder().decode(
    [StrictLine].self, from: Data(EvidenceCheckRun.render(outcome, format: .json).utf8))
}

@Suite("swiftgate evidence check")
struct EvidenceCheckCommandTests {
  @Test(
    "a cited line deleted in a later commit is stale at --at HEAD even when the working tree still has it — catches drift read from the checkout instead of the ref"
  )
  func deletedLineIsStaleAtRef() async throws {
    let repo = try await EvidenceRepo()
    defer { repo.remove() }
    try repo.write(EvidenceRepo.source, EvidenceRepo.original)
    try repo.writeClaims([EvidenceRepo.fileClaim()])
    try await repo.commitAll("add queue")
    try repo.write(
      EvidenceRepo.source,
      EvidenceRepo.original.replacingOccurrences(of: EvidenceRepo.quote, with: "// gone"))
    try await repo.commitAll("drop enqueue")
    // Restored only in the working tree: a ref check must not see it.
    try repo.write(EvidenceRepo.source, EvidenceRepo.original)

    let atHead = await repo.check(at: "HEAD")
    #expect(
      try jsonLines(atHead) == [
        StrictLine(id: "ev-queue-enqueue-is-async", status: .stale, loc: nil)
      ])
    #expect(EvidenceCheckRun.exitCode(atHead) == 1)

    let atParent = await repo.check(at: "HEAD~1")
    #expect(
      try jsonLines(atParent) == [
        StrictLine(id: "ev-queue-enqueue-is-async", status: .quoteOk, loc: nil)
      ])
    #expect(EvidenceCheckRun.exitCode(atParent) == 0)
  }

  @Test(
    "a cited line moved in a later commit reports its new loc at --at HEAD — catches a relocation dropped from the output"
  )
  func movedLineReportsNewLoc() async throws {
    let repo = try await EvidenceRepo()
    defer { repo.remove() }
    try repo.write(EvidenceRepo.source, EvidenceRepo.original)
    try repo.writeClaims([EvidenceRepo.fileClaim()])
    try await repo.commitAll("add queue")
    try repo.write(
      EvidenceRepo.source,
      EvidenceRepo.original.replacingOccurrences(
        of: "public struct Queue {\n",
        with: "public struct Queue {\n  let id = 1\n  let name = \"\"\n"))
    try await repo.commitAll("move enqueue down")

    let outcome = await repo.check(at: "HEAD")
    #expect(
      try jsonLines(outcome) == [
        StrictLine(
          id: "ev-queue-enqueue-is-async", status: .quoteOk, loc: "\(EvidenceRepo.source):L6")
      ])
    #expect(EvidenceCheckRun.exitCode(outcome) == 0)
  }

  @Test(
    "a probe claim takes its verdict file: fail refutes, other pins or another SDK are stale — catches a probe result reused across versions"
  )
  func probeVerdicts() async throws {
    let cases: [(ProbeVerdictRecord, Claim.Status, Int32)] = [
      (EvidenceRepo.verdict(.pass), .supported, 0),
      (EvidenceRepo.verdict(.fail), .refuted, 1),
      (EvidenceRepo.verdict(.pass, tca: "1.25.0"), .stale, 1),
      (EvidenceRepo.verdict(.pass, sdk: "18.0"), .stale, 1),
    ]
    for (record, status, exit) in cases {
      let repo = try await EvidenceRepo()
      defer { repo.remove() }
      try repo.writeRealPackageResolved()
      try repo.writeClaims([EvidenceRepo.probeClaim])
      try repo.writeVerdict(record)

      let outcome = await repo.check(sdk: "26.2")
      #expect(
        try jsonLines(outcome) == [
          StrictLine(id: EvidenceRepo.probeClaimID, status: status, loc: nil)
        ],
        "\(record)")
      #expect(EvidenceCheckRun.exitCode(outcome) == exit, "\(record)")
    }
  }

  @Test(
    "under --at the probe verdict comes from the working tree and Package.resolved from the ref — catches a fresh probe run ignored until committed"
  )
  func atRefReadsEvidenceFromWorkingTreeAndPinsFromRef() async throws {
    let repo = try await EvidenceRepo()
    defer { repo.remove() }
    try repo.writeRealPackageResolved()
    try repo.writeClaims([EvidenceRepo.probeClaim])
    try await repo.commitAll("claims and pins")
    try repo.writeVerdict(EvidenceRepo.verdict(.fail))
    // Only the working tree loses the pins; the ref still resolves them.
    try FileManager.default.removeItem(at: repo.root.appending(path: "Package.resolved"))

    let outcome = await repo.check(at: "HEAD", sdk: "26.2")
    #expect(
      try jsonLines(outcome) == [
        StrictLine(id: EvidenceRepo.probeClaimID, status: .refuted, loc: nil)
      ])
    #expect(EvidenceCheckRun.exitCode(outcome) == 1)
  }

  @Test(
    "--json prints exactly one {id, status} per claim and loc only on a relocated one — catches a key the design skill would copy into claims.jsonl"
  )
  func jsonShapePerClaim() async throws {
    let repo = try await EvidenceRepo()
    defer { repo.remove() }
    let kept = EvidenceRepo.fileClaim(
      id: "ev-queue-imports-foundation", loc: "\(EvidenceRepo.source):L1",
      quote: "import Foundation")
    let moved = EvidenceRepo.fileClaim()
    try repo.write(EvidenceRepo.source, EvidenceRepo.original)
    try repo.writeClaims([kept, moved])
    try await repo.commitAll("add queue")
    try repo.write(
      EvidenceRepo.source,
      EvidenceRepo.original.replacingOccurrences(
        of: "public struct Queue {\n", with: "public struct Queue {\n  let id = 1\n"))
    try await repo.commitAll("move enqueue")

    let outcome = await repo.check(at: "HEAD")
    let text = EvidenceCheckRun.render(outcome, format: .json)
    let raw = try #require(
      try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    #expect(raw.count == 2)
    #expect(raw.map { Set($0.keys) } == [["id", "status"], ["id", "status", "loc"]])
    #expect(
      try jsonLines(outcome) == [
        StrictLine(id: kept.id, status: .quoteOk, loc: nil),
        StrictLine(id: moved.id, status: .quoteOk, loc: "\(EvidenceRepo.source):L5"),
      ])
  }

  @Test(
    "a package claim with no Package.resolved fails naming the missing file, never passes — catches an unpinned checkout quote accepted"
  )
  func packageClaimWithoutResolvedFails() async throws {
    let repo = try await EvidenceRepo()
    defer { repo.remove() }
    let checkout = ".build/checkouts/swift-composable-architecture/Sources/Effect.swift"
    try repo.write(checkout, "public func cancellable(id: some Hashable) -> Self\n")
    try repo.writeClaims([
      EvidenceRepo.fileClaim(
        id: "ev-tca-effect-is-cancellable", loc: "\(checkout):L1",
        pin: "swift-composable-architecture@1.26.2", quote: "public func cancellable")
    ])

    let outcome = await repo.check()
    #expect(
      try jsonLines(outcome) == [
        StrictLine(id: "ev-tca-effect-is-cancellable", status: .quoteFail, loc: nil)
      ])
    #expect(EvidenceCheckRun.exitCode(outcome) == 1)
    #expect(EvidenceCheckRun.render(outcome, format: .human).contains("packageResolvedMissing"))
  }

  static let tcaCheckout = ".build/checkouts/swift-composable-architecture/Sources/Effect.swift"
  static let tcaLine = "public func cancellable(id: some Hashable) -> Self\n"

  static func packageClaim(
    _ loc: String, pin: String = "swift-composable-architecture@1.26.2",
    id: String = "ev-tca-effect-is-cancellable"
  ) -> Claim {
    EvidenceRepo.fileClaim(id: id, loc: loc, pin: pin, quote: "public func cancellable")
  }

  @Test(
    "a checkout loc respelled with other letter case or a .. is still pin-checked or rejected on a real file system — catches a pin bypass by spelling"
  )
  func respelledCheckoutRejected() async throws {
    let repo = try await EvidenceRepo()
    defer { repo.remove() }
    try repo.writeRealPackageResolved()
    try repo.write(Self.tcaCheckout, Self.tcaLine)
    let respellings = [
      (".BUILD/checkouts/swift-composable-architecture/Sources/Effect.swift", "pinVersionMismatch"),
      (".build/CHECKOUTS/swift-composable-architecture/Sources/Effect.swift", "pinVersionMismatch"),
      ("Sources/../\(Self.tcaCheckout)", "parentReference"),
      (
        "./.build/checkouts/../checkouts/swift-composable-architecture/Sources/Effect.swift",
        "parentReference"
      ),
    ]
    for (loc, failure) in respellings {
      try repo.writeClaims([
        Self.packageClaim("\(loc):L1", pin: "swift-composable-architecture@1.0.0")
      ])
      let outcome = await repo.check()
      #expect(
        try jsonLines(outcome) == [
          StrictLine(id: "ev-tca-effect-is-cancellable", status: .quoteFail, loc: nil)
        ], "\(loc)")
      #expect(EvidenceCheckRun.render(outcome, format: .human).contains(failure), "\(loc)")
      #expect(EvidenceCheckRun.exitCode(outcome) == 1, "\(loc)")
    }
  }

  @Test(
    "a loc through a symbolic link fails, whether the link hides a checkout or leaves the repo — catches unpinned or outside text read as codebase evidence"
  )
  func symlinkedLocRejected() async throws {
    let repo = try await EvidenceRepo()
    defer { repo.remove() }
    try repo.writeRealPackageResolved()
    try repo.write(Self.tcaCheckout, Self.tcaLine)
    try repo.write("outside/Outside.swift", Self.tcaLine)
    let manager = FileManager.default
    try manager.createDirectory(
      at: repo.root.appending(path: "Vendor"), withIntermediateDirectories: true)
    try manager.createSymbolicLink(
      atPath: repo.root.appending(path: "Vendor/tca").path,
      withDestinationPath: "../.build/checkouts/swift-composable-architecture")
    try manager.createDirectory(
      at: repo.root.appending(path: "Sources"), withIntermediateDirectories: true)
    try manager.createSymbolicLink(
      atPath: repo.root.appending(path: "Sources/Outside.swift").path,
      withDestinationPath: repo.root.appending(path: "outside/Outside.swift").path)

    for loc in ["Vendor/tca/Sources/Effect.swift:L1", "Sources/Outside.swift:L1"] {
      try repo.writeClaims([Self.packageClaim(loc, pin: "HEAD")])
      let outcome = await repo.check()
      #expect(
        try jsonLines(outcome) == [
          StrictLine(id: "ev-tca-effect-is-cancellable", status: .quoteFail, loc: nil)
        ], "\(loc)")
      #expect(EvidenceCheckRun.render(outcome, format: .human).contains("symlink"), "\(loc)")
    }
  }

  @Test(
    "a stored snapshot reached through a symbolic link fails, whether the file or its directory is the link — catches evidence-root text read from outside the design's record"
  )
  func symlinkedEvidenceFileRejected() async throws {
    let manager = FileManager.default
    let snapshots = EvidenceRepo.layout.snapshotsDirectory
    let claim = Claim(
      id: "ev-list-supports-swipe-actions", lane: "apple-docs", text: "List swipes.",
      citation: Citation(
        kind: .snapshot, loc: "snapshots/list.md", pin: "26.2", quote: "swipeActions"),
      status: .new)
    for linkDirectory in [false, true] {
      let repo = try await EvidenceRepo()
      defer { repo.remove() }
      try repo.write("outside/list.md", "List supports swipeActions.\n")
      try repo.writeClaims([claim])
      if linkDirectory {
        try manager.createDirectory(
          at: repo.root.appending(path: EvidenceRepo.layout.root), withIntermediateDirectories: true
        )
        try manager.createSymbolicLink(
          atPath: repo.root.appending(path: snapshots).path,
          withDestinationPath: repo.root.appending(path: "outside").path)
      } else {
        try manager.createDirectory(
          at: repo.root.appending(path: snapshots), withIntermediateDirectories: true)
        try manager.createSymbolicLink(
          atPath: repo.root.appending(path: "\(snapshots)/list.md").path,
          withDestinationPath: repo.root.appending(path: "outside/list.md").path)
      }
      let outcome = await repo.check(sdk: "26.2")
      #expect(
        try jsonLines(outcome) == [
          StrictLine(id: "ev-list-supports-swipe-actions", status: .quoteFail, loc: nil)
        ], "link directory: \(linkDirectory)")
      #expect(
        EvidenceCheckRun.render(outcome, format: .human).contains("symlink"),
        "link directory: \(linkDirectory)")
    }
  }

  @Test(
    "a checkout in a nested project resolves against that project's Package.resolved, at the working tree and at a ref — catches checkouts read only at the repo root"
  )
  func nestedProjectCheckout() async throws {
    let repo = try await EvidenceRepo()
    defer { repo.remove() }
    let project = "examples/App"
    let checkout = "\(project)/\(Self.tcaCheckout)"
    try repo.write(".gitignore", ".build/\n")
    try repo.write(
      "\(project)/Package.resolved",
      try Fixture.data("Doctor/Package.resolved-CounterFeature.json"))
    try repo.write(checkout, Self.tcaLine)
    try repo.writeClaims([
      Self.packageClaim("\(checkout):L1"),
      Self.packageClaim(
        "\(checkout):L1", pin: "swift-composable-architecture@1.0.0",
        id: "ev-tca-effect-cancellable-old"),
    ])
    try await repo.commitAll("nested project")

    // At a ref a pin that no longer matches is drift, not a forgery: stale rather than failed.
    let cases: [(String?, Claim.Status, String)] = [
      (nil, .quoteFail, "pinVersionMismatch"), ("HEAD", .stale, "pinChanged"),
    ]
    for (ref, oldStatus, detail) in cases {
      let outcome = await repo.check(at: ref)
      #expect(
        try jsonLines(outcome) == [
          StrictLine(id: "ev-tca-effect-is-cancellable", status: .quoteOk, loc: nil),
          StrictLine(id: "ev-tca-effect-cancellable-old", status: oldStatus, loc: nil),
        ], "\(ref ?? "working tree")")
      let human = EvidenceCheckRun.render(outcome, format: .human)
      #expect(human.contains(detail), "\(human)")
    }
  }

  @Test(
    "two claims.jsonl lines with one id both fail — catches a later supported line masking an earlier refuted one"
  )
  func duplicateClaimIDFails() async throws {
    let repo = try await EvidenceRepo()
    defer { repo.remove() }
    try repo.write(EvidenceRepo.source, EvidenceRepo.original)
    try repo.writeClaims([
      EvidenceRepo.fileClaim(quote: "public func dequeue()"), EvidenceRepo.fileClaim(),
    ])
    let outcome = await repo.check()
    #expect(
      try jsonLines(outcome) == [
        StrictLine(id: "ev-queue-enqueue-is-async", status: .quoteFail, loc: nil),
        StrictLine(id: "ev-queue-enqueue-is-async", status: .quoteFail, loc: nil),
      ])
    #expect(EvidenceCheckRun.render(outcome, format: .human).contains("duplicateClaimID"))
    #expect(EvidenceCheckRun.exitCode(outcome) == 1)
  }

  @Test(
    "a verdict from a real probe run passes, and fails once its snippet or wrapper is edited, deleted or its hashes stripped — catches a hand-written or reused probe verdict"
  )
  func realProbeVerdictIsBoundToItsSources() async throws {
    let repo = try await EvidenceRepo()
    defer { repo.remove() }
    let id = "ev-string-has-prefix-exists"
    let probes = EvidenceRepo.layout.probesDirectory
    let fixtures = Fixture.gateDirectory.appending(
      path: "Fixtures/probe", directoryHint: .isDirectory)
    try repo.write(
      "\(probes)/\(id).snippet.swift",
      try Data(contentsOf: fixtures.appending(path: "host-snippets/\(id).snippet.swift")))
    let report = await ProbeCommandRun.run(
      options: .init(
        design: EvidenceRepo.design, package: fixtures.appending(path: "HostTarget").path,
        target: "HostTarget", sdk: nil, cacheHome: repo.root.appending(path: "home")),
      root: repo.root, runner: LiveProcessRunner())
    #expect(report.verdict == .green, "\(report.message)")
    let sdk = try #require(report.sdk)

    let claim = Claim(
      id: id, lane: "apple-docs", text: "String has hasPrefix.",
      citation: Citation(kind: .probe, loc: "probes/" + ProbeIdentifier.fileName(forClaimID: id)),
      status: .new)
    try repo.writeClaims([claim])
    let verdictPath = EvidenceRepo.layout.root + "/" + ProbeVerdictRecord.path(forClaimID: id)
    let snippetPath = "\(probes)/\(id).snippet.swift"
    let wrapperPath = "\(probes)/\(ProbeIdentifier.fileName(forClaimID: id))"
    let pristine = try [verdictPath, snippetPath, wrapperPath].map {
      ($0, try Data(contentsOf: repo.root.appending(path: $0)))
    }
    func restore() throws { for (path, data) in pristine { try repo.write(path, data) } }

    let verdictKeys = try #require(
      try JSONSerialization.jsonObject(with: pristine[0].1) as? [String: Any]
    ).keys
    #expect(Set(verdictKeys).isSuperset(of: ["snippetSha256", "sourceSha256"]))
    let genuine = await repo.check(sdk: sdk)
    #expect(try jsonLines(genuine) == [StrictLine(id: id, status: .supported, loc: nil)])
    #expect(EvidenceCheckRun.exitCode(genuine) == 0)

    var stripped = try #require(
      try JSONSerialization.jsonObject(with: pristine[0].1) as? [String: Any])
    stripped["snippetSha256"] = nil
    stripped["sourceSha256"] = nil
    let tampers: [(String, () throws -> Void)] = [
      (
        "probeSourceMismatch",
        { try repo.write(snippetPath, "static func run() -> Bool { false }\n") }
      ),
      (
        "probeSourceMismatch",
        { try repo.write(wrapperPath, "enum Probe_ev_string_has_prefix_exists {}\n") }
      ),
      (
        "probeSourceMissing",
        { try FileManager.default.removeItem(at: repo.root.appending(path: snippetPath)) }
      ),
      (
        "probeSourceMissing",
        { try FileManager.default.removeItem(at: repo.root.appending(path: wrapperPath)) }
      ),
      (
        "probeVerdictUnbound",
        {
          try repo.write(verdictPath, try JSONSerialization.data(withJSONObject: stripped))
        }
      ),
    ]
    for (failure, tamper) in tampers {
      try restore()
      try tamper()
      let outcome = await repo.check(sdk: sdk)
      #expect(EvidenceCheckRun.exitCode(outcome) == 1, "\(failure)")
      #expect(EvidenceCheckRun.render(outcome, format: .human).contains(failure), "\(failure)")
    }
  }

  @Test("a missing claims.jsonl exits 2 naming the file — catches an empty check passing")
  func missingClaimsExits2() async throws {
    let repo = try await EvidenceRepo()
    defer { repo.remove() }
    let outcome = await repo.check()
    #expect(EvidenceCheckRun.exitCode(outcome) == 2)
    #expect(
      EvidenceCheckRun.render(outcome, format: .human).contains(EvidenceRepo.layout.claimsFile))
  }

  @Test(
    "a malformed claims line exits 2 naming the file and line — catches a bad claim skipped silently"
  )
  func malformedClaimLineExits2() async throws {
    let repo = try await EvidenceRepo()
    defer { repo.remove() }
    var data = try ClaimJSON.encodeLine(EvidenceRepo.fileClaim())
    data.append(Data("{\"id\": \"ev-torn-line-here\"\n".utf8))
    try repo.write(EvidenceRepo.layout.claimsFile, data)

    let outcome = await repo.check()
    #expect(EvidenceCheckRun.exitCode(outcome) == 2)
    #expect(
      EvidenceCheckRun.render(outcome, format: .human).contains(
        "\(EvidenceRepo.layout.claimsFile):2"))
  }

  @Test(
    "a ref naming no commit, a design with no evidence or a non-design path exits 2 — catches every claim reported stale against nothing"
  )
  func unusableInputsExit2() async throws {
    let repo = try await EvidenceRepo()
    defer { repo.remove() }
    try repo.write(EvidenceRepo.source, EvidenceRepo.original)
    try repo.writeClaims([EvidenceRepo.fileClaim()])
    try await repo.commitAll("add queue")

    #expect(EvidenceCheckRun.exitCode(await repo.check(at: "no-such-branch")) == 2)
    #expect(
      EvidenceCheckRun.exitCode(await repo.check(design: "docs/ordering/designs/absent.md")) == 2)
    #expect(EvidenceCheckRun.exitCode(await repo.check(design: "notes/queue.md")) == 2)
  }

  @Test(
    "evidence check without --design is a usage error naming the flag — catches a check that runs with no design to read"
  )
  func designIsRequiredAtParse() async throws {
    do {
      _ = try await SwiftGate.asyncParseAsRoot(["evidence", "check", "--at", "HEAD"])
      Issue.record("evidence check without --design parsed instead of failing")
    } catch {
      #expect(!(error is ExitCode), "parse failure should not be a bare ExitCode")
      #expect(SwiftGate.message(for: error).contains("--design"), "\(error)")
    }
  }
}
