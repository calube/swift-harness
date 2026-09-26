import Foundation
import SwiftGateDomain
import Testing

@Suite("Evidence check — per-kind mechanical rules")
struct EvidenceCheckTests {
  static let tcaPath =
    ".build/checkouts/swift-composable-architecture/Sources/ComposableArchitecture/Effects/Cancellation.swift"

  static let tcaSource = """
    import Foundation

    extension Effect {
      public func cancellable<ID: Hashable & Sendable>(id: ID, cancelInFlight: Bool = false) -> Self {
        self
      }
    }
    """

  static let tcaQuote =
    "public func cancellable<ID: Hashable & Sendable>(id: ID, cancelInFlight: Bool = false) -> Self"

  static func resolved(_ pins: [String: String]) -> Data {
    let entries = pins.keys.sorted().map { identity in
      """
      {"identity":"\(identity)","kind":"remoteSourceControl","location":"https://example.com/\(identity)","state":{"revision":"0000000000000000000000000000000000000000","version":"\(pins[identity] ?? "")"}}
      """
    }
    return Data(#"{"originHash":"x","pins":[\#(entries.joined(separator: ","))],"version":3}"#.utf8)
  }

  static func claim(
    _ kind: Citation.Kind, loc: String, pin: String? = nil, quote: String? = nil,
    id: String = "ev-some-cited-fact"
  ) -> Claim {
    Claim(
      id: id, lane: "packages", text: "a fact",
      citation: Citation(kind: kind, loc: loc, pin: pin, quote: quote), status: .new)
  }

  static func outcome(
    _ claim: Claim, _ sources: InMemoryEvidenceSources, mode: EvidenceCheckMode = .workingTree
  ) -> EvidenceCheckResult.Outcome {
    let results = EvidenceCheck.check([claim], sources: sources, mode: mode)
    #expect(results.count == 1)
    return results[0].outcome
  }

  /// The failure a new rule reports, by raw value or by case name from its description, so this
  /// file compiles against a source tree that lacks the case and fails there on an assertion.
  static func locPath(_ rawValue: String) -> EvidenceCheckResult.Outcome? {
    LocPathProblem(rawValue: rawValue).map { .failed(.locPath($0)) }
  }

  static func failure(_ outcome: EvidenceCheckResult.Outcome) -> String? {
    guard case .failed(let failure) = outcome else { return nil }
    return String(describing: failure)
  }

  static let tcaSources = InMemoryEvidenceSources(
    repoFiles: [tcaPath: tcaSource],
    packageResolved: resolved(["swift-composable-architecture": "1.26.2"]))

  static func tcaClaim(
    lines: String = "L4", pin: String? = "swift-composable-architecture@1.26.2",
    quote: String? = tcaQuote
  ) -> Claim {
    claim(.file, loc: "\(tcaPath):\(lines)", pin: pin, quote: quote)
  }

  // MARK: - file

  @Test(
    "a quote present in the cited lines passes as quote-ok — catches a check that fails everything")
  func genuineQuotePasses() {
    let results = EvidenceCheck.check(
      [Self.tcaClaim(lines: "L3-L6")], sources: Self.tcaSources, mode: .workingTree)
    #expect(results.map(\.outcome) == [.passed])
    #expect(results.first?.claimStatus == .quoteOk)
    #expect(results.first?.isFailing == false)
  }

  @Test("a forged quote is quote-fail — catches a claim whose quote the source never said")
  func forgedQuoteFails() {
    let forged = Self.tcaClaim(
      quote: "public func cancellable(id: some Hashable, after: Duration) -> Self")
    let results = EvidenceCheck.check([forged], sources: Self.tcaSources, mode: .workingTree)
    #expect(results.map(\.outcome) == [.failed(.quoteNotFound)])
    #expect(results.first?.claimStatus == .quoteFail)
    #expect(results.first?.isFailing == true)
  }

  @Test(
    "a quote elsewhere in the file but outside the cited lines fails — catches whole-file matching")
  func quoteOutsideCitedLinesFails() {
    #expect(Self.outcome(Self.tcaClaim(lines: "L1-L2"), Self.tcaSources) == .failed(.quoteNotFound))
  }

  @Test(
    "a range one line past a newline-terminated file fails as context-pack does — catches the final newline counted as a line"
  )
  func rangePastFinalNewlineFails() {
    let path = "Sources/A.swift"
    let text = "first\nsecond\n"
    let sources = InMemoryEvidenceSources(repoFiles: [path: text])
    for (range, lineCount) in [("L1-L3", 2), ("L3", 2)] {
      let citation = Citation(kind: .file, loc: "\(path):\(range)", pin: "abc", quote: "first")
      let claim = Claim(
        id: "ev-some-cited-fact", lane: "codebase", text: "t", citation: citation, status: .new)
      #expect(
        Self.outcome(claim, sources) == .failed(.lineRangeOutOfBounds(lineCount: lineCount)),
        "\(range)")
      #expect(throws: ContextPackError.self, "\(range)") {
        try CitationExcerptSlicer.slice(for: citation, rawText: text, sourceLabel: path)
      }
    }
    let inBounds = Self.claim(.file, loc: "\(path):L1-L2", pin: "abc", quote: "second")
    #expect(Self.outcome(inBounds, sources) == .passed)
  }

  @Test("a line range past the end of the file fails — catches an out-of-bounds slice")
  func lineRangePastEndFails() {
    #expect(
      Self.outcome(Self.tcaClaim(lines: "L90-L95"), Self.tcaSources)
        == .failed(.lineRangeOutOfBounds(lineCount: 7)))
  }

  @Test("a file loc without a line range is malformed — catches a citation nobody can re-slice")
  func fileLocWithoutRangeFails() {
    let claim = Self.claim(.file, loc: Self.tcaPath, pin: "x@1", quote: Self.tcaQuote)
    #expect(
      Self.outcome(claim, Self.tcaSources) == .failed(.locMalformed(expected: .fileLineRange)))
  }

  @Test("a missing cited file fails the working-tree check — catches a citation of nothing")
  func missingCitedFileFails() {
    let claim = Self.claim(.file, loc: "Sources/Gone.swift:L1", pin: "abc", quote: "x")
    #expect(Self.outcome(claim, Self.tcaSources) == .failed(.citedFileMissing))
  }

  @Test("a CRLF file's lines match an LF quote — catches line endings breaking the slice")
  func crlfLinesMatch() {
    let sources = InMemoryEvidenceSources(
      repoFiles: ["Sources/A.swift": "let a = 1\r\nlet b = 2\r\n"])
    let claim = Self.claim(.file, loc: "Sources/A.swift:L2", pin: "abc", quote: "let b = 2")
    #expect(Self.outcome(claim, sources) == .passed)
  }

  // MARK: - package pins

  @Test("a pin that differs from Package.resolved fails — catches citing another version")
  func pinVersionMismatchFails() {
    let claim = Self.tcaClaim(pin: "swift-composable-architecture@1.19.0")
    #expect(
      Self.outcome(claim, Self.tcaSources)
        == .failed(.pinVersionMismatch(pinned: "1.19.0", resolved: "1.26.2")))
  }

  @Test("a pin naming another package fails — catches a checkout cited under a borrowed pin")
  func pinForOtherPackageFails() {
    let sources = InMemoryEvidenceSources(
      repoFiles: [Self.tcaPath: Self.tcaSource],
      packageResolved: Self.resolved([
        "swift-composable-architecture": "1.26.2", "swift-dependencies": "1.26.2",
      ]))
    let claim = Self.tcaClaim(pin: "swift-dependencies@1.26.2")
    #expect(
      Self.outcome(claim, sources)
        == .failed(
          .pinPackageMismatch(pinned: "swift-dependencies", cited: "swift-composable-architecture"))
    )
  }

  @Test(
    "a checkout citation fails without a pin or Package.resolved — catches an unpinned package fact"
  )
  func checkoutWithoutPinOrResolvedFails() {
    #expect(Self.outcome(Self.tcaClaim(pin: nil), Self.tcaSources) == .failed(.pinMissing))
    #expect(Self.outcome(Self.tcaClaim(pin: "1.26.2"), Self.tcaSources) == .failed(.pinMalformed))
    let noResolved = InMemoryEvidenceSources(repoFiles: [Self.tcaPath: Self.tcaSource])
    #expect(Self.outcome(Self.tcaClaim(), noResolved) == .failed(.packageResolvedMissing))
    let badResolved = InMemoryEvidenceSources(
      repoFiles: [Self.tcaPath: Self.tcaSource], packageResolved: Data("{".utf8))
    #expect(Self.outcome(Self.tcaClaim(), badResolved) == .failed(.packageResolvedMalformed))
    let otherResolved = InMemoryEvidenceSources(
      repoFiles: [Self.tcaPath: Self.tcaSource],
      packageResolved: Self.resolved(["swift-dependencies": "1.0.0"]))
    #expect(
      Self.outcome(Self.tcaClaim(), otherResolved)
        == .failed(.packageNotResolved(identity: "swift-composable-architecture")))
  }

  @Test(
    "a loc outside its kind's shape fails — catches a stored citation read from the wrong place",
    arguments: [
      (Citation.Kind.snapshot, "notes/list.md", LocForm.snapshot),
      (.snapshot, "snapshots/", .snapshot),
      (.capture, "logs/run.txt", .capture),
      (.file, "Sources/A.swift:L0", .fileLineRange),
      (.file, "Sources/A.swift:L5-L2", .fileLineRange),
    ])
  func locOutsideKindShapeFails(kind: Citation.Kind, loc: String, form: LocForm) {
    let claim = Self.claim(kind, loc: loc, pin: "p", quote: "q")
    #expect(Self.outcome(claim, .init()) == .failed(.locMalformed(expected: form)))
  }

  @Test("a capture whose stored output is missing fails — catches a citation to a deleted capture")
  func missingCaptureFails() {
    let hash = CaptureDigest.sha256Hex(Self.captureBytes)
    #expect(Self.outcome(Self.captureClaim(hash: hash), .init()) == .failed(.storedFileMissing))
  }

  // MARK: - loc paths

  @Test(
    "an absolute, home-relative or root-escaping loc fails — catches evidence that only resolves on one machine",
    arguments: [
      ("/Users/someone/app/Sources/A.swift:L1", LocPathProblem.absolute),
      ("~/app/Sources/A.swift:L1", .homeRelative),
      ("$HOME/app/Sources/A.swift:L1", .homeVariable),
      ("${HOME}/app/Sources/A.swift:L1", .homeVariable),
      ("../other-repo/Sources/A.swift:L1", .escapesRepoRoot),
      ("Sources/../../other-repo/A.swift:L1", .escapesRepoRoot),
    ])
  func machineSpecificLocFails(loc: String, problem: LocPathProblem) {
    let claim = Self.claim(.file, loc: loc, pin: "abc", quote: "x")
    let sources = InMemoryEvidenceSources(repoFiles: [
      loc.components(separatedBy: ":L")[0]: "x"
    ])
    #expect(Self.outcome(claim, sources) == .failed(.locPath(problem)))
  }

  @Test(
    "a machine-specific loc fails for every stored kind too — catches the path rule living only in file",
    arguments: [
      (Citation.Kind.snapshot, "/tmp/snapshots/list.md"),
      (.capture, "~/captures/x.txt"),
      (.probe, "../probes/Probe_ev_x.swift"),
      (.answer, "/Users/someone/answers.jsonl#run/1"),
    ])
  func machineSpecificStoredLocFails(kind: Citation.Kind, loc: String) {
    guard case .failed(.locPath) = Self.outcome(Self.claim(kind, loc: loc), .init()) else {
      Issue.record("expected a locPath failure for \(kind) \(loc)")
      return
    }
  }

  @Test(
    "a repo-relative path passes even when a component is named Users or home — catches substring matching",
    arguments: [
      ".build/checkouts/swift-composable-architecture/Sources/A.swift",
      "Sources/Users/UserList.swift",
      "home/HomeFeature.swift",
      "Features/home/Users/View.swift",
      "./Sources/A.swift",
      "docs/$HOMEPAGE.md",
    ])
  func repoRelativePathPasses(path: String) {
    #expect(RepoRelativePath.problem(path) == nil)
  }

  @Test(
    "any loc with a parent-directory component fails, in every kind — catches a spelling that dodges the checkout rule",
    arguments: [
      (
        Citation.Kind.file,
        "Sources/../.build/checkouts/swift-composable-architecture/Sources/A.swift:L1"
      ),
      (.file, "Sources/../Sources/A.swift:L1"),
      (.file, ".build/checkouts/swift-composable-architecture/../../Sources/A.swift:L1"),
      (.snapshot, "snapshots/../claims.jsonl"),
      (.capture, "captures/../captures/x.txt"),
      (.probe, "probes/../probes/Probe_ev_some_cited_fact.swift"),
      (.answer, "snapshots/../answers.jsonl#run-a/1"),
    ])
  func parentReferenceFails(kind: Citation.Kind, loc: String) {
    let path = loc.components(separatedBy: ":L")[0]
    let sources = InMemoryEvidenceSources(
      repoFiles: [path: "x"], evidenceFiles: [path: Data("x".utf8)],
      packageResolved: Self.resolved(["swift-composable-architecture": "1.26.2"]))
    let claim = Self.claim(kind, loc: loc, pin: "swift-composable-architecture@1.26.2", quote: "x")
    #expect(Self.outcome(claim, sources) == Self.locPath("parent-reference"))
  }

  @Test(
    "a checkout spelled with other letter case, extra dots or slashes is pin-checked — catches a pin bypass by respelling .build/checkouts",
    arguments: [
      ".BUILD/checkouts/swift-composable-architecture/Sources/A.swift",
      ".build/Checkouts/swift-composable-architecture/Sources/A.swift",
      "./.Build//CHECKOUTS/swift-composable-architecture/Sources/A.swift",
      ".build/checkouts/Swift-Composable-Architecture/Sources/A.swift",
    ])
  func respelledCheckoutIsPinChecked(path: String) {
    let sources = InMemoryEvidenceSources(
      repoFiles: [path: "x"],
      packageResolved: Self.resolved(["swift-composable-architecture": "1.26.2"]))
    let claim = Self.claim(
      .file, loc: "\(path):L1", pin: "swift-composable-architecture@1.0.0", quote: "x")
    #expect(
      Self.outcome(claim, sources)
        == .failed(.pinVersionMismatch(pinned: "1.0.0", resolved: "1.26.2")))
  }

  @Test(
    "a .build path that isn't a package checkout fails — catches citing a package's bare clone or a build product at any version",
    arguments: [
      ".build/repositories/swift-composable-architecture-1234/Sources/A.swift",
      ".build/debug/ComposableArchitecture.swiftmodule/A.swift",
      ".build/checkouts/swift-composable-architecture",
      "App/.BUILD/artifacts/x/A.swift",
    ])
  func buildOutputFails(path: String) {
    let sources = InMemoryEvidenceSources(repoFiles: [path: "x"])
    let claim = Self.claim(
      .file, loc: "\(path):L1", pin: "swift-composable-architecture@1.26.2", quote: "x")
    #expect(Self.outcome(claim, sources) == Self.locPath("build-output"))
  }

  @Test(
    "a nested project's checkout is pin-checked against that project's Package.resolved — catches a nested checkout skipping the pin or borrowing the root's"
  )
  func nestedCheckoutUsesItsOwnResolved() {
    let path = "examples/App/.build/checkouts/swift-composable-architecture/Sources/A.swift"
    let sources = InMemoryEvidenceSources(
      repoFiles: [
        path: "x\n",
        "examples/App/Package.resolved": String(
          decoding: Self.resolved(["swift-composable-architecture": "1.26.2"]), as: UTF8.self),
      ],
      packageResolved: Self.resolved(["swift-composable-architecture": "1.0.0"]))
    let pinned = { (version: String) in
      Self.claim(
        .file, loc: "\(path):L1", pin: "swift-composable-architecture@\(version)", quote: "x")
    }
    #expect(Self.outcome(pinned("1.26.2"), sources) == .passed)
    #expect(
      Self.outcome(pinned("1.0.0"), sources)
        == .failed(.pinVersionMismatch(pinned: "1.0.0", resolved: "1.26.2")))
    let noResolved = InMemoryEvidenceSources(
      repoFiles: [path: "x\n"],
      packageResolved: Self.resolved(["swift-composable-architecture": "1.26.2"]))
    #expect(Self.outcome(pinned("1.26.2"), noResolved) == .failed(.packageResolvedMissing))
  }

  @Test(
    "a loc that passes through a symbolic link fails, in the repo and in the evidence root — catches a link hiding a checkout or a file outside the repo"
  )
  func symlinkedLocFails() {
    let file = Self.claim(.file, loc: "Vendor/tca/Sources/A.swift:L1", pin: "a", quote: "x")
    let snapshot = Self.claim(.snapshot, loc: "snapshots/list.md", pin: "26.0", quote: "x")
    let base = InMemoryEvidenceSources(
      repoFiles: ["Vendor/tca/Sources/A.swift": "x"],
      evidenceFiles: ["snapshots/list.md": Data("x".utf8)], sdkVersion: "26.0")
    let cases: [(LinkedSources, Claim, EvidenceCheckResult.Outcome?)] = [
      (LinkedSources(base: base, repoLinks: ["Vendor/tca"]), file, Self.locPath("symlink")),
      (
        LinkedSources(base: base, evidenceLinks: ["snapshots/list.md"]), snapshot,
        Self.locPath("symlink")
      ),
      (LinkedSources(base: base, repoLinks: ["Vendor/tcb"]), file, .passed),
      (LinkedSources(base: base, repoLinks: ["snapshots/list.md"]), snapshot, .passed),
    ]
    for (sources, claim, expected) in cases {
      let outcome = EvidenceCheck.check([claim], sources: sources, mode: .workingTree).first?
        .outcome
      #expect(
        outcome == expected, "\(sources.repoLinks) \(sources.evidenceLinks) \(claim.citation.loc)")
    }
  }

  @Test(
    "every claim sharing an id fails, whatever each would say alone — catches a later line masking a refuted one"
  )
  func duplicateClaimIDsFail() {
    let good = Self.tcaClaim()
    let forged = Self.claim(
      .file, loc: "\(Self.tcaPath):L4", pin: "swift-composable-architecture@1.26.2",
      quote: "not in the file")
    let other = Self.claim(
      .file, loc: "\(Self.tcaPath):L1", pin: "swift-composable-architecture@1.26.2",
      quote: "import Foundation", id: "ev-another-cited-fact")
    let results = EvidenceCheck.check(
      [forged, other, good], sources: Self.tcaSources, mode: .workingTree)
    #expect(results.map(\.claimID) == [good.id, other.id, good.id])
    #expect(
      results.map { Self.failure($0.outcome) } == ["duplicateClaimID", nil, "duplicateClaimID"])
    #expect(results.allSatisfy { $0.claimID == other.id || $0.claimStatus == .quoteFail })
  }

  @Test(
    "a relative file loc under Users passes end to end — catches the path rule rejecting real files"
  )
  func relativeUsersPathChecks() {
    let path = "Sources/Users/UserList.swift"
    let sources = InMemoryEvidenceSources(repoFiles: [path: "struct UserList {}\n"])
    let claim = Self.claim(.file, loc: "\(path):L1", pin: "abc", quote: "struct UserList")
    #expect(Self.outcome(claim, sources) == .passed)
  }

  // MARK: - --at re-check

  static let movedSource = """
    import Foundation

    // A new header comment pushed everything down.
    // Another line.

    extension Effect {
      public func cancellable<ID: Hashable & Sendable>(id: ID, cancelInFlight: Bool = false) -> Self {
        self
      }
    }
    """

  @Test(
    "a quote that moved within the file is relocated at a ref — catches drift reported as a failure"
  )
  func movedQuoteRelocated() {
    let sources = InMemoryEvidenceSources(
      repoFiles: [Self.tcaPath: Self.movedSource],
      packageResolved: Self.resolved(["swift-composable-architecture": "1.26.2"]))
    #expect(
      Self.outcome(Self.tcaClaim(lines: "L4"), sources, mode: .atRef)
        == .relocated(loc: "\(Self.tcaPath):L7"))
    let results = EvidenceCheck.check([Self.tcaClaim()], sources: sources, mode: .atRef)
    #expect(results.first?.claimStatus == .quoteOk)
    #expect(results.first?.isFailing == false)
  }

  @Test("a quote still at its lines at a ref passes unrelocated — catches a spurious loc rewrite")
  func unmovedQuoteAtRefPasses() {
    #expect(Self.outcome(Self.tcaClaim(), Self.tcaSources, mode: .atRef) == .passed)
  }

  @Test(
    "relocation picks the occurrence nearest the old lines — catches jumping to the first match")
  func relocationPicksNearestOccurrence() {
    let text = (["target"] + Array(repeating: "filler", count: 20) + ["target", "filler"])
      .joined(separator: "\n")
    let sources = InMemoryEvidenceSources(repoFiles: ["Sources/A.swift": text])
    let claim = Self.claim(.file, loc: "Sources/A.swift:L20", pin: "abc", quote: "target")
    #expect(Self.outcome(claim, sources, mode: .atRef) == .relocated(loc: "Sources/A.swift:L22"))
  }

  @Test("a multi-line quote relocates to a line range — catches a single-line loc for a span")
  func multiLineQuoteRelocatesToRange() {
    let sources = InMemoryEvidenceSources(repoFiles: ["Sources/A.swift": "x\ny\nfirst\nsecond\n"])
    let claim = Self.claim(.file, loc: "Sources/A.swift:L1-L2", pin: "abc", quote: "first\nsecond")
    #expect(Self.outcome(claim, sources, mode: .atRef) == .relocated(loc: "Sources/A.swift:L3-L4"))
  }

  @Test("a quote gone at a ref is stale — catches a removed API still counted as evidence")
  func quoteGoneAtRefIsStale() {
    let sources = InMemoryEvidenceSources(
      repoFiles: [Self.tcaPath: "extension Effect {}\n"],
      packageResolved: Self.resolved(["swift-composable-architecture": "1.26.2"]))
    let results = EvidenceCheck.check([Self.tcaClaim()], sources: sources, mode: .atRef)
    #expect(results.map(\.outcome) == [.stale(.quoteGone)])
    #expect(results.first?.claimStatus == .stale)
    #expect(results.first?.isFailing == true)
  }

  @Test("a cited file gone at a ref is stale — catches a deleted file failing as a forgery")
  func fileGoneAtRefIsStale() {
    let sources = InMemoryEvidenceSources(
      packageResolved: Self.resolved(["swift-composable-architecture": "1.26.2"]))
    #expect(Self.outcome(Self.tcaClaim(), sources, mode: .atRef) == .stale(.citedFileGone))
  }

  @Test("a pin changed at a ref is stale — catches a package upgrade silently keeping old evidence")
  func pinChangedAtRefIsStale() {
    let sources = InMemoryEvidenceSources(
      repoFiles: [Self.tcaPath: Self.tcaSource],
      packageResolved: Self.resolved(["swift-composable-architecture": "1.27.0"]))
    #expect(
      Self.outcome(Self.tcaClaim(), sources, mode: .atRef)
        == .stale(.pinChanged(pinned: "1.26.2", resolved: "1.27.0")))
  }

  // MARK: - snapshot

  static func snapshotSources(sdk: String? = "iphonesimulator26.0") -> InMemoryEvidenceSources {
    InMemoryEvidenceSources(
      evidenceFiles: ["snapshots/list.md": Data("List supports swipe actions.\n".utf8)],
      sdkVersion: sdk)
  }

  @Test(
    "a snapshot claim passes only when the snapshot holds the quote — catches an invented doc quote"
  )
  func snapshotQuoteChecked() {
    let good = Self.claim(
      .snapshot, loc: "snapshots/list.md", pin: "iphonesimulator26.0", quote: "swipe actions")
    let forged = Self.claim(
      .snapshot, loc: "snapshots/list.md", pin: "iphonesimulator26.0", quote: "drag to reorder")
    let missing = Self.claim(
      .snapshot, loc: "snapshots/gone.md", pin: "iphonesimulator26.0", quote: "swipe")
    #expect(Self.outcome(good, Self.snapshotSources()) == .passed)
    #expect(Self.outcome(forged, Self.snapshotSources()) == .failed(.quoteNotFound))
    #expect(Self.outcome(missing, Self.snapshotSources()) == .failed(.storedFileMissing))
  }

  @Test("an SDK change at a ref makes a snapshot stale — catches doc semantics kept across SDKs")
  func snapshotSDKChangeIsStale() {
    let claim = Self.claim(
      .snapshot, loc: "snapshots/list.md", pin: "iphonesimulator26.0", quote: "swipe actions")
    #expect(
      Self.outcome(claim, Self.snapshotSources(sdk: "iphonesimulator27.0"), mode: .atRef)
        == .stale(.sdkChanged(pinned: "iphonesimulator26.0", current: "iphonesimulator27.0")))
    #expect(
      Self.outcome(claim, Self.snapshotSources(sdk: nil), mode: .atRef)
        == .failed(.sdkVersionUnavailable))
  }

  // MARK: - capture

  static let captureBytes = Data("$ swift --version\nSwift version 6.2\nexit 0\n".utf8)

  static func captureClaim(hash: String, quote: String? = nil) -> Claim {
    claim(.capture, loc: "captures/\(hash).txt", pin: "sha256:\(hash)", quote: quote)
  }

  @Test("an intact capture passes — catches a hash computed over something other than the bytes")
  func intactCapturePasses() {
    let hash = CaptureDigest.sha256Hex(Self.captureBytes)
    let sources = InMemoryEvidenceSources(evidenceFiles: ["captures/\(hash).txt": Self.captureBytes]
    )
    #expect(
      Self.outcome(Self.captureClaim(hash: hash, quote: "Swift version 6.2"), sources) == .passed)
    #expect(
      Self.outcome(Self.captureClaim(hash: hash, quote: "Swift version 5.9"), sources)
        == .failed(.quoteNotFound))
  }

  @Test("a tampered capture fails though its name and pin agree — catches trusting the file name")
  func tamperedCaptureFails() {
    let hash = CaptureDigest.sha256Hex(Self.captureBytes)
    let tampered = Data("$ swift --version\nSwift version 7.0\nexit 0\n".utf8)
    let sources = InMemoryEvidenceSources(evidenceFiles: ["captures/\(hash).txt": tampered])
    #expect(
      Self.outcome(Self.captureClaim(hash: hash), sources)
        == .failed(
          .captureHashMismatch(
            pinned: "sha256:\(hash)", actual: "sha256:\(CaptureDigest.sha256Hex(tampered))")))
  }

  @Test(
    "a capture whose pin differs from its file name fails — catches a pin copied from another capture"
  )
  func captureNameMismatchFails() {
    let hash = CaptureDigest.sha256Hex(Self.captureBytes)
    let other = CaptureDigest.sha256Hex(Data("other".utf8))
    let claim = Self.claim(.capture, loc: "captures/\(hash).txt", pin: "sha256:\(other)")
    let sources = InMemoryEvidenceSources(evidenceFiles: ["captures/\(hash).txt": Self.captureBytes]
    )
    #expect(Self.outcome(claim, sources) == .failed(.captureNameMismatch))
    #expect(
      Self.outcome(Self.claim(.capture, loc: "captures/abc.txt", pin: "abc"), sources)
        == .failed(.locMalformed(expected: .capture)))
  }

  @Test(
    "a capture pin must be sha256: plus lowercase hex — catches a pin format drifting from what capture writes",
    arguments: ["", "SHA256:", "sha256:upper", "sha256:long", "sha1:"])
  func capturePinFormat(form: String) {
    let hash = CaptureDigest.sha256Hex(Self.captureBytes)
    let pin: String
    switch form {
    case "sha256:upper": pin = "sha256:" + hash.uppercased()
    case "sha256:long": pin = "sha256:" + hash + "0"
    default: pin = form + hash
    }
    let sources = InMemoryEvidenceSources(evidenceFiles: ["captures/\(hash).txt": Self.captureBytes]
    )
    let claim = Self.claim(.capture, loc: "captures/\(hash).txt", pin: pin)
    #expect(Self.outcome(claim, sources) == .failed(.pinMalformed))
    #expect(Self.outcome(Self.captureClaim(hash: hash), sources) == .passed)
  }

  @Test(
    "the capture digest is SHA-256 in lowercase hex — catches a digest format drifting from the pin"
  )
  func captureDigestIsKnownSHA256() {
    #expect(
      CaptureDigest.sha256Hex(Data("abc".utf8))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  // MARK: - probe

  static let probeID = "ev-list-supports-swipe-actions"
  static let probeLoc = "probes/Probe_ev_list_supports_swipe_actions.swift"

  static let probeSnippetPath = "probes/ev-list-supports-swipe-actions.snippet.swift"
  static let probeSnippet = Data("import SwiftUI\n\nstatic func run() {}\n".utf8)
  static let probeWrapper = Data(
    "import SwiftUI\n\nenum Probe_ev_list_supports_swipe_actions {\n  static func run() {}\n}\n"
      .utf8)

  /// A verdict bound to `probeSnippet` and `probeWrapper`; `hashes: nil` leaves both hash keys out,
  /// the way a hand-written verdict would.
  static func probeSources(
    verdict: String = "pass", claimId: String = probeID,
    pins: String = #"{"swift-case-paths":"1.5.0"}"#,
    sdk: String = "iphonesimulator26.0", currentSDK: String? = "iphonesimulator26.0",
    hashes: (snippet: String, source: String)? = (
      CaptureDigest.sha256Hex(probeSnippet), CaptureDigest.sha256Hex(probeWrapper)
    ),
    snippet: Data? = probeSnippet, wrapper: Data? = probeWrapper
  ) -> InMemoryEvidenceSources {
    let bound =
      hashes.map { #","snippetSha256":"\#($0.snippet)","sourceSha256":"\#($0.source)""# } ?? ""
    let json = """
      {"claimId":"\(claimId)","verdict":"\(verdict)","diagnostics":[],"pins":\(pins),"sdk":"\(sdk)"\(bound)}
      """
    var files = ["probes/Probe_ev_list_supports_swipe_actions.verdict.json": Data(json.utf8)]
    files[probeSnippetPath] = snippet
    files[probeLoc] = wrapper
    return InMemoryEvidenceSources(
      evidenceFiles: files, packageResolved: resolved(["swift-case-paths": "1.5.0"]),
      sdkVersion: currentSDK)
  }

  static let probeClaim = claim(.probe, loc: probeLoc, id: probeID)

  @Test("a probe claim takes its verdict — catches a failed build reported as supported")
  func probeTakesVerdict() {
    let pass = EvidenceCheck.check(
      [Self.probeClaim], sources: Self.probeSources(), mode: .workingTree)
    #expect(pass.map(\.outcome) == [.passed])
    #expect(pass.first?.claimStatus == .supported)
    let fail = EvidenceCheck.check(
      [Self.probeClaim], sources: Self.probeSources(verdict: "fail"), mode: .workingTree)
    #expect(fail.map(\.outcome) == [.failed(.probeFailed)])
    #expect(fail.first?.claimStatus == .refuted)
  }

  @Test("an unknown probe verdict value fails and names itself — catches a catch-all verdict")
  func unknownProbeVerdictFails() {
    let results = EvidenceCheck.check(
      [Self.probeClaim], sources: Self.probeSources(verdict: "maybe"), mode: .workingTree)
    guard case .failed(.probeVerdictMalformed(let detail)) = results.first?.outcome else {
      Issue.record("expected a malformed-verdict failure, got \(results)")
      return
    }
    #expect(detail.contains("maybe"))
    #expect(results.first?.claimStatus == nil)
  }

  @Test(
    "a probe verdict for other pins or another SDK is stale — catches a probe result reused across versions"
  )
  func probeVerdictOtherVersionIsStale() {
    #expect(
      Self.outcome(Self.probeClaim, Self.probeSources(pins: #"{"swift-case-paths":"1.4.0"}"#))
        == .stale(
          .probePinChanged(identity: "swift-case-paths", pinned: "1.4.0", resolved: "1.5.0")))
    #expect(
      Self.outcome(Self.probeClaim, Self.probeSources(sdk: "iphonesimulator25.0"))
        == .stale(.sdkChanged(pinned: "iphonesimulator25.0", current: "iphonesimulator26.0")))
    #expect(
      Self.outcome(Self.probeClaim, Self.probeSources(currentSDK: nil))
        == .failed(.sdkVersionUnavailable))
  }

  @Test("a probe claim without its own verdict fails — catches borrowing another claim's verdict")
  func probeVerdictMustBelongToClaim() {
    #expect(
      Self.outcome(Self.probeClaim, InMemoryEvidenceSources(sdkVersion: "iphonesimulator26.0"))
        == .failed(.probeVerdictMissing))
    #expect(
      Self.outcome(Self.probeClaim, Self.probeSources(claimId: "ev-another-probed-claim"))
        == .failed(.probeVerdictForOtherClaim(claimId: "ev-another-probed-claim")))
    let wrongLoc = Self.claim(
      .probe, loc: "probes/Probe_ev_another_probed_claim.swift", id: Self.probeID)
    #expect(Self.outcome(wrongLoc, Self.probeSources()) == .failed(.locMalformed(expected: .probe)))
  }

  @Test(
    "the probe verdict record round-trips through its file path and counts only with its hashes — catches probe and check disagreeing"
  )
  func probeVerdictRecordRoundTrips() throws {
    let record = ProbeVerdictRecord(
      claimId: Self.probeID, verdict: .fail,
      diagnostics: [
        .init(
          file: "Probe_ev_list_supports_swipe_actions.swift", line: 3, column: 5, level: .error,
          message: "cannot find 'swipe' in scope")
      ],
      pins: ["swift-case-paths": "1.5.0"], sdk: "iphonesimulator26.0")
    let path = ProbeVerdictRecord.path(forClaimID: Self.probeID)
    #expect(path == "probes/Probe_ev_list_supports_swipe_actions.verdict.json")
    var bound = try #require(
      try JSONSerialization.jsonObject(with: try ProbeVerdictRecord.encode(record))
        as? [String: Any])
    bound["snippetSha256"] = CaptureDigest.sha256Hex(Self.probeSnippet)
    bound["sourceSha256"] = CaptureDigest.sha256Hex(Self.probeWrapper)
    let sources = InMemoryEvidenceSources(
      evidenceFiles: [
        path: try JSONSerialization.data(withJSONObject: bound),
        Self.probeSnippetPath: Self.probeSnippet, Self.probeLoc: Self.probeWrapper,
      ],
      packageResolved: Self.resolved(["swift-case-paths": "1.5.0"]),
      sdkVersion: "iphonesimulator26.0")
    #expect(Self.outcome(Self.probeClaim, sources) == .failed(.probeFailed))
    var encodedAlone = sources
    encodedAlone.evidenceFiles[path] = try ProbeVerdictRecord.encode(record)
    #expect(Self.failure(Self.outcome(Self.probeClaim, encodedAlone)) == "probeVerdictUnbound")
  }

  @Test(
    "a verdict with no snippet and source hashes fails unbound — catches a hand-written verdict accepted with no probe behind it"
  )
  func unboundProbeVerdictFails() {
    let results = EvidenceCheck.check(
      [Self.probeClaim], sources: Self.probeSources(hashes: nil), mode: .workingTree)
    #expect(results.map { Self.failure($0.outcome) } == ["probeVerdictUnbound"])
    #expect(results.first?.claimStatus == nil)
  }

  @Test(
    "an edited snippet or wrapper fails against the verdict's hashes — catches a verdict reused for code it never built"
  )
  func tamperedProbeSourceFails() {
    let edited = Data("import SwiftUI\n\nstatic func run() { List {}.teleport() }\n".utf8)
    #expect(
      Self.failure(Self.outcome(Self.probeClaim, Self.probeSources(snippet: edited)))
        == "probeSourceMismatch(path: \"\(Self.probeSnippetPath)\")")
    #expect(
      Self.failure(Self.outcome(Self.probeClaim, Self.probeSources(wrapper: edited)))
        == "probeSourceMismatch(path: \"\(Self.probeLoc)\")")
    #expect(
      Self.failure(
        Self.outcome(Self.probeClaim, Self.probeSources(verdict: "fail", snippet: edited)))
        == "probeSourceMismatch(path: \"\(Self.probeSnippetPath)\")")
  }

  @Test(
    "a verdict whose snippet or wrapper is gone fails naming the file — catches a verdict with no probe source on disk"
  )
  func missingProbeSourceFails() {
    #expect(
      Self.failure(Self.outcome(Self.probeClaim, Self.probeSources(snippet: nil)))
        == "probeSourceMissing(path: \"\(Self.probeSnippetPath)\")")
    #expect(
      Self.failure(Self.outcome(Self.probeClaim, Self.probeSources(wrapper: nil)))
        == "probeSourceMissing(path: \"\(Self.probeLoc)\")")
  }

  // MARK: - answer

  static let answeredAt = Date(timeIntervalSince1970: 1_790_000_000)

  static func answers(_ records: [(String, String)]) throws -> Data {
    var data = Data()
    for (runId, question) in records {
      data.append(
        try AnswerRecordJSON.encodeLine(
          AnswerRecord(
            runId: runId, question: question, options: ["yes", "no"], answer: "yes",
            at: answeredAt)))
    }
    return data
  }

  static func answerSources() throws -> InMemoryEvidenceSources {
    InMemoryEvidenceSources(evidenceFiles: [
      "answers.jsonl": try answers([
        ("run-a", "Keep the offline queue?"),
        ("run-b", "Ship behind a flag?"),
        ("run-a", "Drop iOS 17 support?"),
      ])
    ])
  }

  static func answerClaim(_ loc: String, quote: String? = nil) -> Claim {
    claim(.answer, loc: loc, quote: quote)
  }

  @Test(
    "an answer claim passes when its run's ordinal record exists — catches ordinals counted across runs"
  )
  func answerRecordFound() throws {
    let sources = try Self.answerSources()
    #expect(
      Self.outcome(Self.answerClaim("answers.jsonl#run-a/2", quote: "Drop iOS 17"), sources)
        == .passed)
    #expect(Self.outcome(Self.answerClaim("answers.jsonl#run-b/1"), sources) == .passed)
  }

  @Test("an answer loc with no matching record fails — catches an invented user decision")
  func answerWithoutRecordFails() throws {
    let sources = try Self.answerSources()
    #expect(
      Self.outcome(Self.answerClaim("answers.jsonl#run-a/3"), sources)
        == .failed(.answerNotFound(runId: "run-a", ordinal: 3)))
    #expect(
      Self.outcome(Self.answerClaim("answers.jsonl#run-z/1"), sources)
        == .failed(.answerNotFound(runId: "run-z", ordinal: 1)))
    #expect(
      Self.outcome(Self.answerClaim("answers.jsonl#run-a/1"), InMemoryEvidenceSources())
        == .failed(.answersFileMissing))
  }

  @Test(
    "an answer at the right run but a different question fails — catches citing the wrong answer")
  func answerWithDifferentQuestionFails() throws {
    #expect(
      Self.outcome(
        Self.answerClaim("answers.jsonl#run-a/1", quote: "Drop iOS 17 support?"),
        try Self.answerSources()) == .failed(.answerQuestionMismatch))
  }

  @Test(
    "a malformed answer loc fails — catches ordinal 0 or a bare run id resolving to something",
    arguments: [
      "answers.jsonl#run-a/0", "answers.jsonl#run-a/-1", "answers.jsonl#run-a", "answers.jsonl#/1",
      "answers.jsonl", "claims.jsonl#run-a/1", "answers.jsonl#run-a/one",
    ])
  func malformedAnswerLocFails(loc: String) throws {
    #expect(
      Self.outcome(Self.answerClaim(loc), try Self.answerSources())
        == .failed(.locMalformed(expected: .answer)))
  }

  @Test("a torn answers file fails loudly — catches a bad line shifting every later ordinal")
  func tornAnswersFileFails() throws {
    var data = try Self.answers([("run-a", "Keep the offline queue?")])
    data.append(Data("{\"runId\":\"run-a\"\n".utf8))
    data.append(try Self.answers([("run-a", "Drop iOS 17 support?")]))
    let sources = InMemoryEvidenceSources(evidenceFiles: ["answers.jsonl": data])
    #expect(
      Self.outcome(Self.answerClaim("answers.jsonl#run-a/2"), sources)
        == .failed(.answersFileMalformed(line: 2)))
  }

  @Test(
    "the answers file sits in the evidence root — catches answers written where check never looks")
  func answersFileLayout() {
    #expect(
      EvidenceLayout(designDocPath: "docs/ordering/designs/offline-order-queue.md").answersFile
        == "docs/ordering/designs/offline-order-queue.evidence/answers.jsonl")
  }

  // MARK: - closed kinds

  @Test(
    "a claim with an unknown citation kind fails decoding and names it — catches a catch-all kind")
  func unknownCitationKindFailsDecoding() {
    let line =
      #"{"id":"ev-a-b-c","lane":"x","text":"t","citation":{"kind":"web","loc":"x"},"status":"new"}"#
    do {
      _ = try JSONDecoder().decode(Claim.self, from: Data(line.utf8))
      Issue.record("an unknown kind decoded")
    } catch {
      #expect(String(describing: error).contains("web"))
    }
  }

  @Test("results keep claim order across mixed kinds — catches results misattributed to claims")
  func resultsFollowClaimOrder() throws {
    let claims = [
      Self.claim(.answer, loc: "answers.jsonl#run-b/1", id: "ev-first-cited-fact"),
      Self.claim(.file, loc: "/abs/A.swift:L1", pin: "a", quote: "x", id: "ev-second-cited-fact"),
    ]
    let results = EvidenceCheck.check(claims, sources: try Self.answerSources(), mode: .workingTree)
    #expect(results.map(\.claimID) == ["ev-first-cited-fact", "ev-second-cited-fact"])
    #expect(results.map(\.outcome) == [.passed, .failed(.locPath(.absolute))])
  }
}

/// Sources with symbolic links at chosen prefixes. It states every requirement itself, so this
/// file compiles against a protocol that lacks the link lookups as well as one that has them.
private struct LinkedSources: EvidenceSources {
  var base: InMemoryEvidenceSources
  var repoLinks: Set<String> = []
  var evidenceLinks: Set<String> = []

  func repoFile(_ path: String) -> String? { base.repoFile(path) }
  func evidenceFile(_ path: String) -> Data? { base.evidenceFile(path) }
  var packageResolved: Data? { base.packageResolved }
  var sdkVersion: String? { base.sdkVersion }
  func repoSymlink(_ path: String) -> String? {
    Self.prefixes(path).first(where: repoLinks.contains)
  }
  func evidenceSymlink(_ path: String) -> String? {
    Self.prefixes(path).first(where: evidenceLinks.contains)
  }

  private static func prefixes(_ path: String) -> [String] {
    let components = path.split(separator: "/").map(String.init)
    return components.indices.map { components[...$0].joined(separator: "/") }
  }
}
