import Foundation
import SwiftGateDomain
import Testing

@Suite("Context packs (spec §5.10)")
struct ContextPackTests {
  // MARK: - Fixtures

  private static let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/design", directoryHint: .isDirectory)

  /// The repo's real, spec-compliant design doc (`gate/Fixtures/design/valid.md`), read from disk
  /// per test (matching `MarkdownDocumentTests`) so the verbatim test runs against the actual
  /// fixture other design-doc-model tests use, not a hand-copied string that could drift from it.
  private let designRawText: String
  private let design: DesignDocument

  init() throws {
    designRawText = try String(
      contentsOf: Self.fixturesRoot.appending(path: "valid.md"), encoding: .utf8)
    design = DesignDocument(markdown: .parse(designRawText))
  }

  private static let designLabel = "docs/checkout/designs/offline-order-queue.md"
  private var designSource: ContextSource {
    ContextSource(label: Self.designLabel, rawText: designRawText)
  }

  private static let sampleTask = LedgerTask(
    id: "offline-queue-core-reducer",
    deps: [],
    writeSet: [
      "Packages/OrderQueue/Sources/OrderQueueCore/",
      "Packages/OrderQueue/Tests/OrderQueueCoreTests/",
    ],
    gate: .push,
    tests: ["test-queued-orders-replay-in-submit-order"],
    covers: [
      "req-offline-queue-drains-on-reconnect", "test-queued-orders-replay-in-submit-order",
    ],
    estLines: 180,
    status: .pending,
    worktree: "../myapp-2026-09-25-offline-order-queue-offline-queue-core-reducer"
  )

  private static let standardsRawText = """
    ## core

    Core modules import no UI framework and touch no live IO directly.

    ## feature

    Feature modules own one screen's reducer and view.
    """
  private static let standardsLabel = "docs/standards.md"
  private static let standardsSource = ContextSource(
    label: standardsLabel, rawText: standardsRawText)

  private static func claimLine(
    id: String, lane: String = "packages", text: String = "some claim text",
    kind: Citation.Kind = .file, loc: String, pin: String?, quote: String? = nil,
    status: Claim.Status = .supported
  ) throws -> String {
    let claim = Claim(
      id: id, lane: lane, text: text,
      citation: Citation(kind: kind, loc: loc, pin: pin, quote: quote), status: status)
    let data = try JSONEncoder().encode(claim)
    return String(decoding: data, as: UTF8.self)
  }

  /// Builds a minimal worker pack's inputs for a given task, with a stubbed standards/claims
  /// corpus so tests that don't care about those two rows don't have to restate them.
  private func workerInputs(
    task: LedgerTask, citedClaimIDs: [String] = [], claimsRawText: String = "",
    moduleKindAnchors: [String] = ["core"]
  ) -> WorkerInputs {
    WorkerInputs(
      task: task, design: design, designSource: designSource,
      claims: ContextSource(label: "claims.jsonl", rawText: claimsRawText),
      citedClaimIDs: citedClaimIDs, standards: Self.standardsSource,
      moduleKindAnchors: moduleKindAnchors)
  }

  // MARK: - Verbatim property, all 8 roles, real fixtures

  /// Asserts every non-empty line of every slice is a literal substring of the raw text its
  /// `sourceLabel` names — the core promise of §5.10 ("verbatim … it never summarises"). Building
  /// this from parsed/reconstructed fields (joined table cells, reflowed prose) would fail this
  /// test the moment spacing didn't match; only copying real source lines survives it.
  private func assertVerbatim(_ pack: ContextPack, sources: [String: String]) {
    for slice in pack.slices {
      guard let source = sources[slice.sourceLabel] else {
        Issue.record("no known source for label \(slice.sourceLabel)")
        continue
      }
      for line in slice.lines where !line.isEmpty {
        #expect(
          source.contains(line),
          "role \(pack.role): line \"\(line)\" from \(slice.sourceLabel) is not verbatim in its source"
        )
      }
    }
  }

  @Test(
    "every pack line is a verbatim substring of its source, for all 8 roles — catches summarising")
  func verbatimAcrossAllRoles() throws {
    let claimsRawLine = try Self.claimLine(
      id: "ev-tca-effect-run-supports-cancellation",
      loc:
        ".build/checkouts/swift-composable-architecture/Sources/ComposableArchitecture/Effects/Cancellation.swift:L4-L4",
      pin: "swift-composable-architecture@1.26.2",
      quote:
        "public func cancellable<ID: Hashable & Sendable>(id: ID, cancelInFlight: Bool = false) -> Self"
    )
    let citationRawText = """
      // Cancellation.swift
      import Foundation

      public func cancellable<ID: Hashable & Sendable>(id: ID, cancelInFlight: Bool = false) -> Self {
        fatalError("stub")
      }
      """
    let citationLabel = ".build/checkouts/swift-composable-architecture/…/Cancellation.swift"
    let claimToJudge = ClaimToJudge(
      claimRawLine: claimsRawLine, claimsSourceLabel: "claims.jsonl",
      citationSourceLabel: citationLabel, citationRawText: citationRawText)

    var sources: [String: String] = [
      Self.designLabel: designRawText,
      Self.standardsLabel: Self.standardsRawText,
      "claims.jsonl": claimsRawLine,
      citationLabel: citationRawText,
    ]

    func track(_ source: ContextSource) -> ContextSource {
      sources[source.label] = source.rawText
      return source
    }

    let frameAnswers = track(
      ContextSource(
        label: "frame answers", rawText: "Q: which module owns retry?\nA: OrderQueueCore."))

    // Built separately (not inline via `.build`) so its self-describing ledger-entry slice can be
    // registered as its own source below, the same way every other source is.
    let workerPack = try ContextPack.build(
      role: .worker,
      inputs: .worker(
        workerInputs(
          task: Self.sampleTask, citedClaimIDs: ["ev-tca-effect-run-supports-cancellation"],
          claimsRawText: claimsRawLine, moduleKindAnchors: ["core"])))
    for slice in workerPack.slices where slice.anchor == nil && slice.sourceLabel != "claims.jsonl"
    {
      sources[slice.sourceLabel] = slice.text
    }

    let packs: [ContextPack] = try [
      .build(
        role: .researchLane,
        inputs: .researchLane(
          ResearchLaneInputs(
            briefs: [frameAnswers, track(ContextSource(label: "area", rawText: "checkout"))],
            claims: ContextSource(label: "claims.jsonl", rawText: claimsRawLine),
            pin: "swift-composable-architecture@1.26.2"))),
      .build(
        role: .claimChecker,
        inputs: .claimChecker(ClaimCheckerInputs(entries: [claimToJudge]))),
      .build(
        role: .drafter,
        inputs: .drafter(
          DrafterInputs(
            template: track(
              ContextSource(label: "template", rawText: "## Problem\n\n## Requirements\n")),
            frameAnswers: frameAnswers,
            claims: ContextSource(label: "claims.jsonl", rawText: claimsRawLine),
            probeVerdicts: track(
              ContextSource(label: "probe verdicts", rawText: "Probe_ev_tca_effect_run: pass")),
            standards: Self.standardsSource, moduleKindAnchors: ["core"]))),
      .build(
        role: .evidenceAuditor,
        inputs: .evidenceAuditor(
          EvidenceAuditorInputs(
            design: designSource, docAnchors: ["evidence", "decision"],
            citedClaims: [claimToJudge]))),
      .build(
        role: .standardsReviewer,
        inputs: .standardsReviewer(
          StandardsReviewerInputs(
            design: designSource, standardsAndPlaybook: Self.standardsSource,
            standardsAnchors: ["feature"]))),
      .build(
        role: .challenger,
        inputs: .challenger(
          ChallengerInputs(
            design: designSource, docAnchors: ["options"],
            questionSet: track(
              ContextSource(
                label: "challenger question set",
                rawText: "Does the decision follow from the evidence?\nWhat would falsify it?"))))
      ),
      .build(
        role: .decomposer,
        inputs: .decomposer(
          DecomposerInputs(
            design: designSource,
            moduleGraph: track(
              ContextSource(label: "module graph", rawText: "OrderQueueFeature -> OrderQueueCore")
            ),
            taskSizingBounds: track(
              ContextSource(
                label: "task-sizing bounds", rawText: "estLines 40-400; max 2 modules per task"))
          ))),
      workerPack,
    ]

    #expect(Set(packs.map(\.role)) == Set(ContextPackRole.allCases))
    for pack in packs {
      assertVerbatim(pack, sources: sources)
    }
  }

  // MARK: - Worker: spec §5.10 contents

  @Test("worker pack holds only design sections covering its `covers` ids")
  func workerPackHoldsOnlyCoveredSections() throws {
    let pack = try ContextPack.workerPack(
      workerInputs(task: Self.sampleTask, moduleKindAnchors: []))

    let anchors = Set(pack.slices.compactMap(\.anchor))
    #expect(anchors == ["requirements", "test-plan-by-tier"])

    // "Client-side queue" only appears in the Decision section, which this task doesn't cover.
    #expect(
      !pack.slices.contains { $0.lines.contains(where: { $0.contains("Client-side queue") }) })
  }

  @Test("a worker pack carries its cited claims, its standards anchors, and its gate tier")
  func workerPackCarriesCitedClaimsStandardsAndGateTier() throws {
    let hit = try Self.claimLine(id: "ev-cited", loc: "Sources/Hit.swift:L1-L1", pin: "p")
    let miss = try Self.claimLine(id: "ev-not-cited", loc: "Sources/Miss.swift:L1-L1", pin: "p")

    let pack = try ContextPack.workerPack(
      workerInputs(
        task: Self.sampleTask, citedClaimIDs: ["ev-cited"], claimsRawText: "\(hit)\n\(miss)",
        moduleKindAnchors: ["core", "feature"]))

    let claimsSlice = try #require(pack.slices.first { $0.sourceLabel == "claims.jsonl" })
    #expect(claimsSlice.lines == [hit])
    #expect(!claimsSlice.lines.contains(miss))

    let standardsAnchors = pack.slices.filter { $0.sourceLabel == Self.standardsLabel }
      .compactMap(\.anchor)
    #expect(Set(standardsAnchors) == ["core", "feature"])

    let ledgerEntry = try #require(
      pack.slices.first { $0.sourceLabel.hasPrefix("ledger task entry") })
    #expect(ledgerEntry.lines.contains { $0.contains("\"gate\" : \"push\"") })
  }

  @Test("an unknown `covers` id fails loudly instead of producing a silently incomplete pack")
  func unknownCoversIDFailsLoudly() throws {
    let task = LedgerTask(
      id: Self.sampleTask.id, deps: [], writeSet: Self.sampleTask.writeSet, gate: .push,
      tests: [], covers: ["req-does-not-exist-anywhere"], estLines: 10, status: .pending,
      worktree: Self.sampleTask.worktree)

    #expect(throws: ContextPackError.unknownCoversID("req-does-not-exist-anywhere")) {
      try ContextPack.workerPack(workerInputs(task: task))
    }
  }

  @Test("duplicate ids in `covers` naming the same section produce one slice, not two")
  func duplicateCoversIDsDedupe() throws {
    let task = LedgerTask(
      id: Self.sampleTask.id, deps: [], writeSet: Self.sampleTask.writeSet, gate: .push,
      tests: [],
      covers: [
        "req-offline-queue-drains-on-reconnect", "req-offline-queue-drains-on-reconnect",
      ],
      estLines: 10, status: .pending, worktree: Self.sampleTask.worktree)

    let pack = try ContextPack.workerPack(workerInputs(task: task))

    #expect(pack.slices.filter { $0.anchor == "requirements" }.count == 1)
  }

  @Test("an empty `covers` list is not an error — the pack just has no covering design sections")
  func emptyCoversIsNotAnError() throws {
    let task = LedgerTask(
      id: Self.sampleTask.id, deps: [], writeSet: Self.sampleTask.writeSet, gate: .push,
      tests: [], covers: [], estLines: 10, status: .pending, worktree: Self.sampleTask.worktree)

    let pack = try ContextPack.workerPack(workerInputs(task: task, moduleKindAnchors: []))

    #expect(pack.slices.count == 1)  // the ledger task entry only
    #expect(pack.slices[0].anchor == nil)
  }

  @Test("an unknown module-kind anchor for a worker fails loudly")
  func workerUnknownModuleKindAnchorFailsLoudly() throws {
    #expect(
      throws: ContextPackError.missingAnchor(anchor: "not-a-real-kind", source: Self.standardsLabel)
    ) {
      try ContextPack.workerPack(
        workerInputs(task: Self.sampleTask, moduleKindAnchors: ["not-a-real-kind"]))
    }
  }

  // MARK: - Anchor selection: missing / duplicate

  @Test("a missing anchor fails loudly rather than returning an empty slice")
  func missingAnchorFailsLoudly() {
    #expect(
      throws: ContextPackError.missingAnchor(anchor: "does-not-exist", source: Self.designLabel)
    ) {
      try MarkdownAnchorSlicer.slice(
        anchor: "does-not-exist", of: design.markdown, rawText: designRawText,
        sourceLabel: Self.designLabel)
    }
  }

  @Test("a section anchor that appears twice fails loudly — which occurrence is ambiguous")
  func duplicateAnchorFailsLoudly() {
    let rawText = """
      ## Foo

      first body

      ## Foo

      second body
      """
    let document = MarkdownDocument.parse(rawText)

    #expect(throws: ContextPackError.duplicateAnchor(anchor: "foo", source: "dup.md")) {
      try MarkdownAnchorSlicer.slice(
        anchor: "foo", of: document, rawText: rawText, sourceLabel: "dup.md")
    }
  }

  // MARK: - Claim checker: cited ranges only

  @Test("claim-checker pack holds only cited ranges, not the whole cited file")
  func claimCheckerPackHoldsOnlyCitedRanges() throws {
    let citationRawText = """
      line 1 — never cited
      line 2 — never cited
      line 3 — cited start
      line 4 — cited middle
      line 5 — cited end
      line 6 — never cited
      """
    let claimRawLine = try Self.claimLine(
      id: "ev-example", loc: "Sources/Example.swift:L3-L5", pin: "abc123")

    let pack = try ContextPack.claimCheckerPack(
      ClaimCheckerInputs(entries: [
        ClaimToJudge(
          claimRawLine: claimRawLine, claimsSourceLabel: "claims.jsonl",
          citationSourceLabel: "Sources/Example.swift", citationRawText: citationRawText)
      ]))

    let citationSlice = try #require(
      pack.slices.first { $0.sourceLabel == "Sources/Example.swift" })
    #expect(
      citationSlice.lines == [
        "line 3 — cited start", "line 4 — cited middle", "line 5 — cited end",
      ])
    #expect(!citationSlice.lines.contains { $0.contains("never cited") })
  }

  @Test("a snapshot/capture citation with no line range excerpts the line containing its quote")
  func quoteBasedExcerpt() throws {
    let snapshotRawText = """
      # Apple docs snapshot
      Some unrelated preamble.
      URLSession.shared is a singleton you should avoid touching directly from Core.
      Trailing text.
      """
    let claimRawLine = try Self.claimLine(
      id: "ev-url-session-singleton", kind: .snapshot, loc: "snapshots/urlsession.txt",
      pin: "iOS 18", quote: "URLSession.shared is a singleton")

    let pack = try ContextPack.claimCheckerPack(
      ClaimCheckerInputs(entries: [
        ClaimToJudge(
          claimRawLine: claimRawLine, claimsSourceLabel: "claims.jsonl",
          citationSourceLabel: "snapshots/urlsession.txt", citationRawText: snapshotRawText)
      ]))

    let excerpt = try #require(pack.slices.first { $0.sourceLabel == "snapshots/urlsession.txt" })
    #expect(
      excerpt.lines == [
        "URLSession.shared is a singleton you should avoid touching directly from Core."
      ])
  }

  @Test("a single-line citation loc (`L<n>`, no dash) excerpts exactly that one line")
  func singleLineCitationLoc() throws {
    let citationRawText = "one\ntwo\nthree\n"
    let claimRawLine = try Self.claimLine(id: "ev-single", loc: "Sources/X.swift:L2", pin: "p")

    let pack = try ContextPack.claimCheckerPack(
      ClaimCheckerInputs(entries: [
        ClaimToJudge(
          claimRawLine: claimRawLine, claimsSourceLabel: "claims.jsonl",
          citationSourceLabel: "Sources/X.swift", citationRawText: citationRawText)
      ]))

    let excerpt = try #require(pack.slices.first { $0.sourceLabel == "Sources/X.swift" })
    #expect(excerpt.lines == ["two"])
  }

  @Test("a citation line range past the end of its source fails loudly")
  func citationRangeOutOfBoundsFailsLoudly() throws {
    let citationRawText = "one\ntwo\nthree\n"
    let claimRawLine = try Self.claimLine(
      id: "ev-oob", loc: "Sources/X.swift:L10-L12", pin: "p")

    #expect(
      throws: ContextPackError.citationRangeOutOfBounds(
        "Sources/X.swift:L10-L12", source: "Sources/X.swift")
    ) {
      try ContextPack.claimCheckerPack(
        ClaimCheckerInputs(entries: [
          ClaimToJudge(
            claimRawLine: claimRawLine, claimsSourceLabel: "claims.jsonl",
            citationSourceLabel: "Sources/X.swift", citationRawText: citationRawText)
        ]))
    }
  }

  @Test("a citation with neither a line range nor a quote fails loudly, not with an empty excerpt")
  func citationWithNoRangeOrQuoteFailsLoudly() throws {
    let claimRawLine = try Self.claimLine(
      id: "ev-bare", kind: .snapshot, loc: "snapshots/bare.txt", pin: "p", quote: nil)

    #expect(throws: ContextPackError.invalidCitationRange("snapshots/bare.txt")) {
      try ContextPack.claimCheckerPack(
        ClaimCheckerInputs(entries: [
          ClaimToJudge(
            claimRawLine: claimRawLine, claimsSourceLabel: "claims.jsonl",
            citationSourceLabel: "snapshots/bare.txt", citationRawText: "irrelevant content")
        ]))
    }
  }

  @Test("a quote absent from its cited source fails loudly rather than returning no excerpt")
  func citationQuoteNotFoundFailsLoudly() throws {
    let claimRawLine = try Self.claimLine(
      id: "ev-missing-quote", kind: .snapshot, loc: "snapshots/miss.txt", pin: "p",
      quote: "this text is not in the source")

    #expect(
      throws: ContextPackError.citationQuoteNotFound(
        "this text is not in the source", source: "snapshots/miss.txt")
    ) {
      try ContextPack.claimCheckerPack(
        ClaimCheckerInputs(entries: [
          ClaimToJudge(
            claimRawLine: claimRawLine, claimsSourceLabel: "claims.jsonl",
            citationSourceLabel: "snapshots/miss.txt", citationRawText: "nothing matches here")
        ]))
    }
  }

  @Test("a torn (non-JSON) claim line fails loudly instead of being silently skipped")
  func malformedClaimLineFailsLoudly() {
    let torn = "{\"id\": \"ev-tor"  // truncated mid-write, as a crash could leave it

    #expect(throws: ContextPackError.invalidCitationRange(torn)) {
      try ContextPack.claimCheckerPack(
        ClaimCheckerInputs(entries: [
          ClaimToJudge(
            claimRawLine: torn, claimsSourceLabel: "claims.jsonl",
            citationSourceLabel: "Sources/X.swift", citationRawText: "irrelevant")
        ]))
    }
  }

  // MARK: - Research lane: same-pin cache hits

  @Test("research pack includes same-pin cache hits and excludes other pins")
  func researchPackIncludesSamePinCacheHits() throws {
    let matchingPin = "swift-composable-architecture@1.26.2"
    let hit = try Self.claimLine(
      id: "ev-hit", loc: "Sources/Hit.swift:L1-L1", pin: matchingPin)
    let miss = try Self.claimLine(
      id: "ev-miss", loc: "Sources/Miss.swift:L1-L1", pin: "some-other-package@2.0.0")

    let pack = ContextPack.researchLanePack(
      ResearchLaneInputs(
        briefs: [ContextSource(label: "frame answers", rawText: "Q: …\nA: …")],
        claims: ContextSource(label: "claims.jsonl", rawText: "\(hit)\n\(miss)"), pin: matchingPin)
    )

    let claimsSlice = try #require(pack.slices.first { $0.sourceLabel == "claims.jsonl" })
    #expect(claimsSlice.lines == [hit])
    #expect(!claimsSlice.lines.contains(miss))
  }

  @Test("no cache hits for the pin means no claims slice, not an empty one")
  func researchPackOmitsClaimsSliceWhenNoHits() {
    let pack = ContextPack.researchLanePack(
      ResearchLaneInputs(
        briefs: [ContextSource(label: "frame answers", rawText: "Q: …\nA: …")],
        claims: ContextSource(label: "claims.jsonl", rawText: ""), pin: "whatever@1.0.0"))

    #expect(!pack.slices.contains { $0.sourceLabel == "claims.jsonl" })
  }

  // MARK: - Drafter: only `supported` claims

  @Test("a drafter pack's claims slice holds only `supported` claims")
  func drafterPackHoldsOnlySupportedClaims() throws {
    let supported = try Self.claimLine(
      id: "ev-supported", loc: "Sources/A.swift:L1-L1", pin: "p", status: .supported)
    let notYetChecked = try Self.claimLine(
      id: "ev-new", loc: "Sources/B.swift:L1-L1", pin: "p", status: .new)

    let pack = try ContextPack.drafterPack(
      DrafterInputs(
        template: ContextSource(label: "template", rawText: "## Problem\n"),
        frameAnswers: ContextSource(label: "frame answers", rawText: "Q/A"),
        claims: ContextSource(
          label: "claims.jsonl", rawText: "\(supported)\n\(notYetChecked)"),
        probeVerdicts: ContextSource(label: "probe verdicts", rawText: "pass"),
        standards: Self.standardsSource, moduleKindAnchors: ["core"]))

    let claimsSlice = try #require(pack.slices.first { $0.sourceLabel == "claims.jsonl" })
    #expect(claimsSlice.lines == [supported])
    #expect(!claimsSlice.lines.contains(notYetChecked))
  }

  @Test("an unknown module-kind anchor for a drafter fails loudly")
  func drafterUnknownModuleKindAnchorFailsLoudly() {
    #expect(
      throws: ContextPackError.missingAnchor(anchor: "not-a-real-kind", source: Self.standardsLabel)
    ) {
      try ContextPack.drafterPack(
        DrafterInputs(
          template: ContextSource(label: "template", rawText: "## Problem\n"),
          frameAnswers: ContextSource(label: "frame answers", rawText: "Q/A"),
          claims: ContextSource(label: "claims.jsonl", rawText: ""),
          probeVerdicts: ContextSource(label: "probe verdicts", rawText: "pass"),
          standards: Self.standardsSource, moduleKindAnchors: ["not-a-real-kind"]))
    }
  }

  // MARK: - Evidence auditor: only its named sections

  @Test("an evidence-auditor pack holds only the given design sections and their cited claims")
  func evidenceAuditorPackHoldsOnlyGivenSections() throws {
    let pack = try ContextPack.evidenceAuditorPack(
      EvidenceAuditorInputs(
        design: designSource, docAnchors: ["evidence", "decision"], citedClaims: []))

    let anchors = Set(pack.slices.compactMap(\.anchor))
    #expect(anchors == ["evidence", "decision"])
    #expect(!anchors.contains("problem"))
    #expect(
      !pack.slices.contains {
        $0.lines.contains(where: { $0.contains("Guests on flaky Wi-Fi") })
      })
  }

  @Test("a missing doc anchor for an evidence auditor fails loudly")
  func evidenceAuditorMissingAnchorFailsLoudly() {
    #expect(
      throws: ContextPackError.missingAnchor(anchor: "not-a-real-section", source: Self.designLabel)
    ) {
      try ContextPack.evidenceAuditorPack(
        EvidenceAuditorInputs(
          design: designSource, docAnchors: ["not-a-real-section"], citedClaims: []))
    }
  }

  // MARK: - Standards reviewer: Module kinds, Decision, Test plan — not Problem

  @Test("a standards-reviewer pack holds Module kinds, Decision and Test plan, and not Problem")
  func standardsReviewerPackHoldsOnlyItsSections() throws {
    let pack = try ContextPack.standardsReviewerPack(
      StandardsReviewerInputs(
        design: designSource, standardsAndPlaybook: Self.standardsSource,
        standardsAnchors: ["feature"]))

    let designAnchors = Set(
      pack.slices.filter { $0.sourceLabel == Self.designLabel }.compactMap(\.anchor))
    #expect(designAnchors == ["module-kinds", "decision", "test-plan-by-tier"])
    #expect(!designAnchors.contains("problem"))
    #expect(
      !pack.slices.contains {
        $0.lines.contains(where: { $0.contains("Guests on flaky Wi-Fi") })
      })

    let standardsAnchors = Set(
      pack.slices.filter { $0.sourceLabel == Self.standardsLabel }.compactMap(\.anchor))
    #expect(standardsAnchors == ["feature"])
  }

  @Test("an unknown standards anchor for a standards reviewer fails loudly")
  func standardsReviewerUnknownAnchorFailsLoudly() {
    #expect(
      throws: ContextPackError.missingAnchor(anchor: "not-a-real-kind", source: Self.standardsLabel)
    ) {
      try ContextPack.standardsReviewerPack(
        StandardsReviewerInputs(
          design: designSource, standardsAndPlaybook: Self.standardsSource,
          standardsAnchors: ["not-a-real-kind"]))
    }
  }

  // MARK: - Challenger: only the given doc sections, plus the question set

  @Test("a challenger pack holds only the given doc sections, not the whole document")
  func challengerPackHoldsOnlyGivenSections() throws {
    let pack = try ContextPack.challengerPack(
      ChallengerInputs(
        design: designSource, docAnchors: ["options"],
        questionSet: ContextSource(label: "challenger question set", rawText: "What breaks it?"))
    )

    let anchors = Set(pack.slices.compactMap(\.anchor))
    #expect(anchors == ["options"])
    #expect(
      !pack.slices.contains {
        $0.lines.contains(where: { $0.contains("Guests on flaky Wi-Fi") })
      })
    #expect(pack.slices.contains { $0.sourceLabel == "challenger question set" })
  }

  @Test("a missing doc anchor for a challenger fails loudly")
  func challengerMissingAnchorFailsLoudly() {
    #expect(
      throws: ContextPackError.missingAnchor(anchor: "not-a-real-section", source: Self.designLabel)
    ) {
      try ContextPack.challengerPack(
        ChallengerInputs(
          design: designSource, docAnchors: ["not-a-real-section"],
          questionSet: ContextSource(label: "challenger question set", rawText: "What breaks it?"))
      )
    }
  }

  // MARK: - Decomposer: Requirements, Module kinds, Test plan — not Decision

  @Test(
    "a decomposer pack holds Requirements, Module kinds and Test plan, plus the module graph and bounds"
  )
  func decomposerPackHoldsOnlyItsSections() throws {
    let pack = try ContextPack.decomposerPack(
      DecomposerInputs(
        design: designSource,
        moduleGraph: ContextSource(
          label: "module graph", rawText: "OrderQueueFeature -> OrderQueueCore"),
        taskSizingBounds: ContextSource(label: "task-sizing bounds", rawText: "estLines 40-400"))
    )

    let designAnchors = Set(
      pack.slices.filter { $0.sourceLabel == Self.designLabel }.compactMap(\.anchor))
    #expect(designAnchors == ["requirements", "module-kinds", "test-plan-by-tier"])
    #expect(!designAnchors.contains("decision"))
    #expect(pack.slices.contains { $0.sourceLabel == "module graph" })
    #expect(pack.slices.contains { $0.sourceLabel == "task-sizing bounds" })
  }

  // The design fixture always has Requirements, Module kinds and Test plan sections, so a
  // decomposer's design-side anchors can't go missing from real input — its failure surface is
  // its two flat `ContextSource` inputs instead, already proven correct by the pass-through
  // `ContextPackSlice(_:)` initializer and the verbatim test above.

  // MARK: - Dispatch: `ContextPack.build(role:inputs:)`

  @Test("build dispatches every role to its own builder — catches a role silently falling through")
  func buildDispatchesEveryRole() throws {
    for role in ContextPackRole.allCases {
      let inputs: ContextPackRoleInputs
      switch role {
      case .researchLane:
        inputs = .researchLane(
          ResearchLaneInputs(
            briefs: [], claims: ContextSource(label: "claims.jsonl", rawText: ""), pin: "p"))
      case .claimChecker:
        inputs = .claimChecker(ClaimCheckerInputs(entries: []))
      case .drafter:
        inputs = .drafter(
          DrafterInputs(
            template: ContextSource(label: "template", rawText: ""),
            frameAnswers: ContextSource(label: "frame answers", rawText: ""),
            claims: ContextSource(label: "claims.jsonl", rawText: ""),
            probeVerdicts: ContextSource(label: "probe verdicts", rawText: ""),
            standards: Self.standardsSource, moduleKindAnchors: []))
      case .evidenceAuditor:
        inputs = .evidenceAuditor(
          EvidenceAuditorInputs(design: designSource, docAnchors: [], citedClaims: []))
      case .standardsReviewer:
        inputs = .standardsReviewer(
          StandardsReviewerInputs(
            design: designSource, standardsAndPlaybook: Self.standardsSource,
            standardsAnchors: []))
      case .challenger:
        inputs = .challenger(
          ChallengerInputs(
            design: designSource, docAnchors: [],
            questionSet: ContextSource(label: "challenger question set", rawText: "")))
      case .decomposer:
        inputs = .decomposer(
          DecomposerInputs(
            design: designSource,
            moduleGraph: ContextSource(label: "module graph", rawText: ""),
            taskSizingBounds: ContextSource(label: "task-sizing bounds", rawText: "")))
      case .worker:
        inputs = .worker(workerInputs(task: Self.sampleTask, moduleKindAnchors: []))
      }

      let pack = try ContextPack.build(role: role, inputs: inputs)
      #expect(pack.role == role)
    }
  }

  @Test("build fails loudly when `role` doesn't match the inputs it was given")
  func buildRoleMismatchFailsLoudly() {
    let inputs = ContextPackRoleInputs.drafter(
      DrafterInputs(
        template: ContextSource(label: "template", rawText: ""),
        frameAnswers: ContextSource(label: "frame answers", rawText: ""),
        claims: ContextSource(label: "claims.jsonl", rawText: ""),
        probeVerdicts: ContextSource(label: "probe verdicts", rawText: ""),
        standards: Self.standardsSource, moduleKindAnchors: []))

    #expect(
      throws: ContextPackError.roleMismatch(expected: .worker, actual: .drafter)
    ) {
      try ContextPack.build(role: .worker, inputs: inputs)
    }
  }

  // MARK: - Budget

  @Test("an over-budget worker pack is flagged; a small one is not")
  func overBudgetWorkerPackFlagged() throws {
    let pack = try ContextPack.workerPack(workerInputs(task: Self.sampleTask))

    #expect(pack.isOverBudget(tokens: 5))
    #expect(!pack.isOverBudget(tokens: 1_000_000))
  }

  // MARK: - Token estimate: UTF-8 bytes, not characters

  @Test("the token estimate is UTF-8 byte count / 4, not character count / 4 — non-ASCII text")
  func tokenEstimateUsesUTF8Bytes() {
    // Each 🎉 is 1 Swift Character but 4 UTF-8 bytes; a character-based estimate would be wrong.
    let text = String(repeating: "🎉", count: 10)
    #expect(text.count == 10)
    #expect(text.utf8.count == 40)

    let pack = ContextPack(
      role: .challenger,
      slices: [ContextPackSlice(sourceLabel: "emoji", anchor: nil, lines: [text])])

    #expect(pack.estimatedTokens.value == 10)  // 40 bytes / 4
    #expect(pack.estimatedTokens.value != text.count / 4)  // would be 2 if character-based
  }

  @Test("a mixed-script line's estimate matches its own UTF-8 byte count")
  func nonASCIIMixedScriptEstimate() {
    let text = "café — 咖啡 — קפה"
    let expected = text.utf8.count / 4
    let pack = ContextPack(
      role: .challenger,
      slices: [ContextPackSlice(sourceLabel: "mixed", anchor: nil, lines: [text])])
    #expect(pack.estimatedTokens.value == expected)
    #expect(expected != text.count / 4)
  }
}
