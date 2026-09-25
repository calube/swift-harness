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
    let standardsRawText = """
      ## core

      Core modules import no UI framework and touch no live IO directly.

      ## feature

      Feature modules own one screen's reducer and view.
      """
    let standards = MarkdownDocument.parse(standardsRawText)
    let standardsLabel = "docs/standards.md"

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

    var sources: [String: String] = [
      Self.designLabel: designRawText,
      standardsLabel: standardsRawText,
      "claims.jsonl": claimsRawLine,
      citationLabel: citationRawText,
    ]

    func track(_ source: ContextSource) -> ContextSource {
      sources[source.label] = source.rawText
      return source
    }

    // research lane
    let researchPack = ContextPack.researchLanePack(
      briefs: [
        track(
          ContextSource(
            label: "frame answers", rawText: "Q: which module owns retry?\nA: OrderQueueCore.")),
        track(ContextSource(label: "area", rawText: "checkout")),
      ],
      claimsJSONLLines: [claimsRawLine], claimsSourceLabel: "claims.jsonl",
      pin: "swift-composable-architecture@1.26.2")

    // claim checker
    let claimCheckerPack = try ContextPack.claimCheckerPack(entries: [
      ClaimToJudge(
        claimRawLine: claimsRawLine, claimsSourceLabel: "claims.jsonl",
        citationSourceLabel: citationLabel, citationRawText: citationRawText)
    ])

    // worker
    let workerPack = try ContextPack.workerPack(
      task: Self.sampleTask, design: design, designRawText: designRawText,
      designSourceLabel: Self.designLabel)
    // The ledger-entry slice's source is the encoded task itself — there's no separate file to
    // compare it against, so register it under its own label the same way every other source is.
    for slice in workerPack.slices where slice.anchor == nil {
      sources[slice.sourceLabel] = slice.text
    }

    // drafter: template + frame answers + supported claims + probe verdicts + standards anchors
    let drafterPack = ContextPack(
      role: .drafter,
      slices: [
        ContextPackSlice(
          track(ContextSource(label: "template", rawText: "## Problem\n\n## Requirements\n"))),
        ContextPackSlice(
          track(
            ContextSource(
              label: "frame answers", rawText: "Q: which module owns retry?\nA: OrderQueueCore."))),
        ContextPackSlice(sourceLabel: "claims.jsonl", anchor: nil, lines: [claimsRawLine]),
        ContextPackSlice(
          track(ContextSource(label: "probe verdicts", rawText: "Probe_ev_tca_effect_run: pass"))),
        try MarkdownAnchorSlicer.slice(
          anchor: "core", of: standards, rawText: standardsRawText, sourceLabel: standardsLabel),
      ])

    // evidence auditor: the doc + every cited claim with its citation excerpt
    let evidenceAuditorPack = try ContextPack(
      role: .evidenceAuditor,
      slices: [
        MarkdownAnchorSlicer.slice(
          anchor: "evidence", of: design.markdown, rawText: designRawText,
          sourceLabel: Self.designLabel),
        MarkdownAnchorSlicer.slice(
          anchor: "decision", of: design.markdown, rawText: designRawText,
          sourceLabel: Self.designLabel),
        ContextPackSlice(sourceLabel: "claims.jsonl", anchor: nil, lines: [claimsRawLine]),
        CitationExcerptSlicer.slice(
          for: Claim(
            id: "x", lane: "x", text: "x",
            citation: Citation(
              kind: .file,
              loc:
                ".build/checkouts/swift-composable-architecture/Sources/ComposableArchitecture/Effects/Cancellation.swift:L4-L4",
              pin: "x",
              quote:
                "public func cancellable<ID: Hashable & Sendable>(id: ID, cancelInFlight: Bool = false) -> Self"
            ), status: .supported
          ).citation, rawText: citationRawText, sourceLabel: citationLabel),
      ])

    // standards reviewer: Module kinds, Decision, Test plan sections; standards anchors
    let standardsReviewerPack = try ContextPack(
      role: .standardsReviewer,
      slices: [
        MarkdownAnchorSlicer.slice(
          anchor: "module-kinds", of: design.markdown, rawText: designRawText,
          sourceLabel: Self.designLabel),
        MarkdownAnchorSlicer.slice(
          anchor: "decision", of: design.markdown, rawText: designRawText,
          sourceLabel: Self.designLabel),
        MarkdownAnchorSlicer.slice(
          anchor: "test-plan-by-tier", of: design.markdown, rawText: designRawText,
          sourceLabel: Self.designLabel),
        MarkdownAnchorSlicer.slice(
          anchor: "feature", of: standards, rawText: standardsRawText, sourceLabel: standardsLabel),
      ])

    // challenger: the doc + challenger question set
    let challengerPack = ContextPack(
      role: .challenger,
      slices: [
        try MarkdownAnchorSlicer.slice(
          anchor: "options", of: design.markdown, rawText: designRawText,
          sourceLabel: Self.designLabel),
        ContextPackSlice(
          track(
            ContextSource(
              label: "challenger question set",
              rawText: "Does the decision follow from the evidence?\nWhat would falsify it?"))),
      ])

    // decomposer: Requirements, Module kinds, Test plan sections + module graph + D16 bounds
    let decomposerPack = ContextPack(
      role: .decomposer,
      slices: [
        try MarkdownAnchorSlicer.slice(
          anchor: "requirements", of: design.markdown, rawText: designRawText,
          sourceLabel: Self.designLabel),
        try MarkdownAnchorSlicer.slice(
          anchor: "module-kinds", of: design.markdown, rawText: designRawText,
          sourceLabel: Self.designLabel),
        try MarkdownAnchorSlicer.slice(
          anchor: "test-plan-by-tier", of: design.markdown, rawText: designRawText,
          sourceLabel: Self.designLabel),
        ContextPackSlice(
          track(
            ContextSource(label: "module graph", rawText: "OrderQueueFeature -> OrderQueueCore"))),
      ])

    let packs: [ContextPack] = [
      researchPack, claimCheckerPack, drafterPack, evidenceAuditorPack, standardsReviewerPack,
      challengerPack, decomposerPack, workerPack,
    ]
    #expect(Set(packs.map(\.role)) == Set(ContextPackRole.allCases))
    for pack in packs {
      assertVerbatim(pack, sources: sources)
    }
  }

  // MARK: - Worker: only sections covering `covers`

  @Test("worker pack holds only sections covering its `covers` ids")
  func workerPackHoldsOnlyCoveredSections() throws {
    let pack = try ContextPack.workerPack(
      task: Self.sampleTask, design: design, designRawText: designRawText,
      designSourceLabel: Self.designLabel)

    let anchors = Set(pack.slices.compactMap(\.anchor))
    #expect(anchors == ["requirements", "test-plan-by-tier"])

    // "Client-side queue" only appears in the Decision section, which this task doesn't cover.
    #expect(
      !pack.slices.contains { $0.lines.contains(where: { $0.contains("Client-side queue") }) })
  }

  @Test("an unknown `covers` id fails loudly instead of producing a silently incomplete pack")
  func unknownCoversIDFailsLoudly() throws {
    let task = LedgerTask(
      id: Self.sampleTask.id, deps: [], writeSet: Self.sampleTask.writeSet, gate: .push,
      tests: [], covers: ["req-does-not-exist-anywhere"], estLines: 10, status: .pending,
      worktree: Self.sampleTask.worktree)

    #expect(throws: ContextPackError.unknownCoversID("req-does-not-exist-anywhere")) {
      try ContextPack.workerPack(
        task: task, design: design, designRawText: designRawText,
        designSourceLabel: Self.designLabel)
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

    let pack = try ContextPack.workerPack(
      task: task, design: design, designRawText: designRawText,
      designSourceLabel: Self.designLabel)

    #expect(pack.slices.filter { $0.anchor == "requirements" }.count == 1)
  }

  @Test("an empty `covers` list is not an error — the pack just has no design sections")
  func emptyCoversIsNotAnError() throws {
    let task = LedgerTask(
      id: Self.sampleTask.id, deps: [], writeSet: Self.sampleTask.writeSet, gate: .push,
      tests: [], covers: [], estLines: 10, status: .pending, worktree: Self.sampleTask.worktree)

    let pack = try ContextPack.workerPack(
      task: task, design: design, designRawText: designRawText,
      designSourceLabel: Self.designLabel)

    #expect(pack.slices.count == 1)  // the ledger task entry only
    #expect(pack.slices[0].anchor == nil)
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

    let pack = try ContextPack.claimCheckerPack(entries: [
      ClaimToJudge(
        claimRawLine: claimRawLine, claimsSourceLabel: "claims.jsonl",
        citationSourceLabel: "Sources/Example.swift", citationRawText: citationRawText)
    ])

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

    let pack = try ContextPack.claimCheckerPack(entries: [
      ClaimToJudge(
        claimRawLine: claimRawLine, claimsSourceLabel: "claims.jsonl",
        citationSourceLabel: "snapshots/urlsession.txt", citationRawText: snapshotRawText)
    ])

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

    let pack = try ContextPack.claimCheckerPack(entries: [
      ClaimToJudge(
        claimRawLine: claimRawLine, claimsSourceLabel: "claims.jsonl",
        citationSourceLabel: "Sources/X.swift", citationRawText: citationRawText)
    ])

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
      try ContextPack.claimCheckerPack(entries: [
        ClaimToJudge(
          claimRawLine: claimRawLine, claimsSourceLabel: "claims.jsonl",
          citationSourceLabel: "Sources/X.swift", citationRawText: citationRawText)
      ])
    }
  }

  @Test("a citation with neither a line range nor a quote fails loudly, not with an empty excerpt")
  func citationWithNoRangeOrQuoteFailsLoudly() throws {
    let claimRawLine = try Self.claimLine(
      id: "ev-bare", kind: .snapshot, loc: "snapshots/bare.txt", pin: "p", quote: nil)

    #expect(throws: ContextPackError.invalidCitationRange("snapshots/bare.txt")) {
      try ContextPack.claimCheckerPack(entries: [
        ClaimToJudge(
          claimRawLine: claimRawLine, claimsSourceLabel: "claims.jsonl",
          citationSourceLabel: "snapshots/bare.txt", citationRawText: "irrelevant content")
      ])
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
      try ContextPack.claimCheckerPack(entries: [
        ClaimToJudge(
          claimRawLine: claimRawLine, claimsSourceLabel: "claims.jsonl",
          citationSourceLabel: "snapshots/miss.txt", citationRawText: "nothing matches here")
      ])
    }
  }

  @Test("a torn (non-JSON) claim line fails loudly instead of being silently skipped")
  func malformedClaimLineFailsLoudly() {
    let torn = "{\"id\": \"ev-tor"  // truncated mid-write, as a crash could leave it

    #expect(throws: ContextPackError.invalidCitationRange(torn)) {
      try ContextPack.claimCheckerPack(entries: [
        ClaimToJudge(
          claimRawLine: torn, claimsSourceLabel: "claims.jsonl",
          citationSourceLabel: "Sources/X.swift", citationRawText: "irrelevant")
      ])
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
      briefs: [ContextSource(label: "frame answers", rawText: "Q: …\nA: …")],
      claimsJSONLLines: [hit, miss], claimsSourceLabel: "claims.jsonl", pin: matchingPin)

    let claimsSlice = try #require(pack.slices.first { $0.sourceLabel == "claims.jsonl" })
    #expect(claimsSlice.lines == [hit])
    #expect(!claimsSlice.lines.contains(miss))
  }

  @Test("no cache hits for the pin means no claims slice, not an empty one")
  func researchPackOmitsClaimsSliceWhenNoHits() {
    let pack = ContextPack.researchLanePack(
      briefs: [ContextSource(label: "frame answers", rawText: "Q: …\nA: …")],
      claimsJSONLLines: [], claimsSourceLabel: "claims.jsonl", pin: "whatever@1.0.0")

    #expect(!pack.slices.contains { $0.sourceLabel == "claims.jsonl" })
  }

  // MARK: - Budget

  @Test("an over-budget worker pack is flagged; a small one is not")
  func overBudgetWorkerPackFlagged() throws {
    let pack = try ContextPack.workerPack(
      task: Self.sampleTask, design: design, designRawText: designRawText,
      designSourceLabel: Self.designLabel)

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
