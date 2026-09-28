import Foundation

/// spec §5.10: the fixed set of agents `context-pack` can build for. Closed on purpose — an
/// unrecognized role must fail to parse rather than silently produce an empty or wrong-shaped
/// pack (worker-brief pitfall: close types at trust boundaries).
public enum ContextPackRole: String, Sendable, Equatable, CaseIterable, Codable {
  case researchLane = "research-lane"
  case claimChecker = "claim-checker"
  case drafter
  case evidenceAuditor = "evidence-auditor"
  case standardsReviewer = "standards-reviewer"
  case challenger
  case decomposer
  case worker
}

/// One excerpt of a pack: `lines` are copied unchanged from the source named by `sourceLabel` —
/// never reformatted, re-joined with different spacing, or paraphrased. `anchor` is set when the
/// slice was selected by section anchor; `nil` for a range- or filter-selected slice.
public struct ContextPackSlice: Sendable, Equatable {
  public let sourceLabel: String
  public let anchor: String?
  public let lines: [String]

  public init(sourceLabel: String, anchor: String? = nil, lines: [String]) {
    self.sourceLabel = sourceLabel
    self.anchor = anchor
    self.lines = lines
  }

  /// A pass-through slice of an entire ``ContextSource`` — every line of it, unfiltered. Used for
  /// pack inputs that are already scoped to what a role needs (frame answers, a lane brief, a
  /// module-graph dump) rather than something to select a subsection of.
  public init(_ source: ContextSource) {
    self.init(sourceLabel: source.label, anchor: nil, lines: source.lines)
  }

  public var text: String { lines.joined(separator: "\n") }
}

/// A token count derived from UTF-8 byte length, never a real tokenizer (plan decision:
/// "Context-pack token count = UTF-8 bytes / 4, labelled an estimate"). The type name carries the
/// caveat so nothing downstream mistakes `value` for an exact count.
public struct TokenCountEstimate: Sendable, Equatable, Comparable {
  public let value: Int

  public init(utf8ByteCount: Int) {
    self.value = utf8ByteCount / 4
  }

  public static func < (lhs: TokenCountEstimate, rhs: TokenCountEstimate) -> Bool {
    lhs.value < rhs.value
  }
}

/// A verbatim, anchor-selected context pack for one agent role (spec §5.10). `ContextPack` never
/// summarises: every slice's lines are exact substrings of the source they were cut from.
public struct ContextPack: Sendable, Equatable {
  public let role: ContextPackRole
  public let slices: [ContextPackSlice]
  public let estimatedTokens: TokenCountEstimate

  public init(role: ContextPackRole, slices: [ContextPackSlice]) {
    self.role = role
    self.slices = slices
    let totalBytes = slices.reduce(into: 0) { $0 += $1.text.utf8.count }
    self.estimatedTokens = TokenCountEstimate(utf8ByteCount: totalBytes)
  }

  /// Worker packs default to ~15k tokens (spec §5.10); over budget is a `plan-lint` error, not
  /// something this type enforces — it only reports the fact so a caller can act on it.
  public func isOverBudget(tokens budget: Int) -> Bool {
    estimatedTokens.value > budget
  }
}

/// Every failure mode a pack builder can hit. All are loud, typed failures — an unknown id, a
/// missing/duplicate anchor, or a role/inputs mismatch never falls through to a silently empty or
/// wrong-shaped pack (worker-brief pitfall: no silent fallbacks).
public enum ContextPackError: Error, Sendable, Equatable {
  /// `anchor` names no section of `source`.
  case missingAnchor(anchor: String, source: String)
  /// `anchor` names more than one section of `source` — which one to slice is ambiguous.
  case duplicateAnchor(anchor: String, source: String)
  /// A ledger task's `covers` named an id that isn't a requirement or test-plan id in the design.
  case unknownCoversID(String)
  /// A citation has neither a parseable `L<a>-L<b>` line range nor a quote to search for.
  case invalidCitationRange(String)
  /// A citation's line range falls outside `source`'s line count.
  case citationRangeOutOfBounds(String, source: String)
  /// A citation's quote could not be found in `source`.
  case citationQuoteNotFound(String, source: String)
  /// `ContextPack.build(role:inputs:)` was called with a `role` that doesn't match the role its
  /// `inputs` case carries.
  case roleMismatch(expected: ContextPackRole, actual: ContextPackRole)
  /// A worker pack's dependency-notes section (spec §5.3) needs `task`'s task return, but it
  /// couldn't be read or decoded under the given build run — never rendered as a thin pack that
  /// silently drops one dependency's notes.
  case missingDependencyReturn(task: String)
  /// A worker's write-set entry lies in a module the graph gives no kind, so the standards that go
  /// with it can't be known. `nil` when the module graph itself couldn't be built because the
  /// repository's config names a module kind outside ``ModuleKind``.
  case unknownModuleKind(writeSetEntry: String?)
  /// A ledger task's `covers` named an id that isn't a slice id of the spec page at `page`.
  case unknownSliceID(String, page: String)
}

/// A labelled raw text a pack can slice from — a frame-answers transcript, a lane brief, a
/// module-graph dump, or any other input that isn't itself a design doc with sections.
public struct ContextSource: Sendable, Equatable {
  public let label: String
  public let rawText: String

  public init(label: String, rawText: String) {
    self.label = label
    self.rawText = rawText
  }

  var lines: [String] { MarkdownAnchorSlicer.rawLines(rawText) }
}

/// Slices a markdown document's raw text by section anchor, returning the exact source lines for
/// that section (its heading through its last nested line). `MarkdownDocument.Section` doesn't
/// keep the raw line range it was parsed from, so this re-derives it from the same heading/fence
/// rules the parser uses — the only way to guarantee every emitted line is byte-identical to the
/// source rather than a reconstruction of parsed fields (which would risk losing exact spacing in
/// tables and fences).
public enum MarkdownAnchorSlicer {
  public static func slice(
    anchor: String, of document: MarkdownDocument, rawText: String, sourceLabel: String
  ) throws -> ContextPackSlice {
    let matches = allSections(document.sections).filter { $0.anchor == anchor }
    guard !matches.isEmpty else {
      throw ContextPackError.missingAnchor(anchor: anchor, source: sourceLabel)
    }
    guard matches.count == 1 else {
      throw ContextPackError.duplicateAnchor(anchor: anchor, source: sourceLabel)
    }
    let lines = rawLines(rawText)
    guard let range = headingRange(for: matches[0], in: lines) else {
      throw ContextPackError.missingAnchor(anchor: anchor, source: sourceLabel)
    }
    return ContextPackSlice(sourceLabel: sourceLabel, anchor: anchor, lines: Array(lines[range]))
  }

  /// Slices several anchors out of one source, parsing it once. The order of `anchors` is the
  /// order of the returned slices.
  public static func slice(anchors: [String], from source: ContextSource) throws
    -> [ContextPackSlice]
  {
    let document = MarkdownDocument.parse(source.rawText)
    return try anchors.map {
      try slice(anchor: $0, of: document, rawText: source.rawText, sourceLabel: source.label)
    }
  }

  static func rawLines(_ text: String) -> [String] {
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  private static func allSections(_ sections: [MarkdownDocument.Section])
    -> [MarkdownDocument.Section]
  {
    sections.flatMap { [$0] + allSections($0.subsections) }
  }

  private struct HeadingMark {
    let level: Int
    let text: String
    let lineIndex: Int
  }

  private static func headingMarks(in lines: [String]) -> [HeadingMark] {
    var marks: [HeadingMark] = []
    var fenceMarker: String?
    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let marker = fenceMarker {
        if trimmed.hasPrefix(marker) { fenceMarker = nil }
        continue
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fenceMarker = String(trimmed.prefix(3))
        continue
      }
      if let mark = headingComponents(of: line) {
        marks.append(HeadingMark(level: mark.level, text: mark.text, lineIndex: index))
      }
    }
    return marks
  }

  private static func headingComponents(of line: String) -> (level: Int, text: String)? {
    guard line.hasPrefix("#") else { return nil }
    var index = line.startIndex
    var level = 0
    while index < line.endIndex, line[index] == "#" {
      level += 1
      index = line.index(after: index)
    }
    guard level <= 6, index < line.endIndex, line[index] == " " else { return nil }
    var text = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
    while text.hasSuffix("#") { text.removeLast() }
    return (level, text.trimmingCharacters(in: .whitespaces))
  }

  private static func headingRange(for section: MarkdownDocument.Section, in lines: [String])
    -> Range<Int>?
  {
    let marks = headingMarks(in: lines)
    guard
      let matchIndex = marks.firstIndex(where: {
        $0.level == section.level && $0.text == section.heading
      })
    else { return nil }
    var end = lines.count
    for mark in marks[(matchIndex + 1)...] where mark.level <= section.level {
      end = mark.lineIndex
      break
    }
    return marks[matchIndex].lineIndex..<end
  }
}

/// Slices a citation's cited excerpt only — the line range for a `file` citation
/// (`path:L<a>-L<b>`), or the line containing `quote` for a citation that carries no line range.
/// Never the whole cited file (spec §5.10: claim checker gets "cited line ranges and snapshot
/// excerpts only"), with one exception: a probe snippet without a range is the evidence itself,
/// a few lines that compile or don't, so it goes in whole.
public enum CitationExcerptSlicer {
  public static func slice(for citation: Citation, rawText: String, sourceLabel: String) throws
    -> ContextPackSlice
  {
    let lines = MarkdownAnchorSlicer.rawLines(rawText)
    if let range = lineRange(fromLoc: citation.loc) {
      guard range.start >= 1, range.end >= range.start, range.end <= lines.count else {
        throw ContextPackError.citationRangeOutOfBounds(citation.loc, source: sourceLabel)
      }
      return ContextPackSlice(
        sourceLabel: sourceLabel, anchor: nil, lines: Array(lines[(range.start - 1)..<range.end]))
    }
    if citation.kind == .probe {
      return ContextPackSlice(sourceLabel: sourceLabel, anchor: nil, lines: lines)
    }
    guard let quote = citation.quote, !quote.isEmpty else {
      throw ContextPackError.invalidCitationRange(citation.loc)
    }
    let spellings = [quote] + jsonEscaped(quote)
    guard
      let matchIndex = lines.firstIndex(where: { line in
        spellings.contains { line.contains($0) }
      })
    else {
      throw ContextPackError.citationQuoteNotFound(quote, source: sourceLabel)
    }
    return ContextPackSlice(sourceLabel: sourceLabel, anchor: nil, lines: [lines[matchIndex]])
  }

  /// A quote cited from a JSONL source such as `answers.jsonl` appears there JSON-escaped, so a
  /// `"` in the quote is `\"` in the line. Both slash spellings, since writers differ on `\/`.
  private static func jsonEscaped(_ quote: String) -> [String] {
    var spellings: [String] = []
    for formatting: JSONEncoder.OutputFormatting in [.withoutEscapingSlashes, []] {
      let encoder = JSONEncoder()
      encoder.outputFormatting = formatting
      guard let data = try? encoder.encode(quote) else { continue }
      let encoded = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
      if encoded != quote { spellings.append(String(encoded)) }
    }
    return spellings
  }

  private static func lineRange(fromLoc loc: String) -> (start: Int, end: Int)? {
    guard let marker = loc.range(of: ":L") else { return nil }
    let rest = loc[marker.upperBound...]
    let parts = rest.components(separatedBy: "-L")
    guard let first = parts.first, let start = Int(first) else { return nil }
    if parts.count > 1, let end = Int(parts[1]) { return (start, end) }
    return (start, start)
  }
}

/// One claim a checker (claim checker or evidence auditor) must judge, together with the raw text
/// of whatever its citation points at.
public struct ClaimToJudge: Sendable, Equatable {
  /// The exact `claims.jsonl` line for this claim, unmodified.
  public let claimRawLine: String
  public let claimsSourceLabel: String
  public let citationSourceLabel: String
  public let citationRawText: String
  /// A probe claim's `Probe_<id>.verdict.json`, label and raw text; nil for every other kind.
  public let probeVerdict: ContextSource?

  public init(
    claimRawLine: String, claimsSourceLabel: String, citationSourceLabel: String,
    citationRawText: String, probeVerdict: ContextSource? = nil
  ) {
    self.claimRawLine = claimRawLine
    self.claimsSourceLabel = claimsSourceLabel
    self.citationSourceLabel = citationSourceLabel
    self.citationRawText = citationRawText
    self.probeVerdict = probeVerdict
  }
}

/// Filters raw `claims.jsonl` lines by a predicate on the decoded claim, keeping the untouched raw
/// line for every match — the filtering criterion is domain logic, but the emitted text is always
/// the original line, never a re-serialization of it.
enum ClaimLineFilter {
  static func lines(in jsonlLines: [String], where predicate: (Claim) -> Bool) -> [String] {
    let decoder = JSONDecoder()
    return jsonlLines.filter { line in
      guard !line.isEmpty, let data = line.data(using: .utf8),
        let claim = try? decoder.decode(Claim.self, from: data)
      else { return false }
      return predicate(claim)
    }
  }
}

/// Filters a module-graph dump's raw lines to those naming at least one touched module — the
/// research lane needs only the neighbourhood of the modules it's investigating, never the whole
/// graph. No structural `ModuleGraph` renderer exists (or is needed) here: whatever text a caller
/// hands in as the module-graph source, this only keeps the lines that mention a touched module,
/// the same verbatim-line-filter shape `ClaimLineFilter` already uses.
enum ModuleGraphLineFilter {
  static func lines(in graphLines: [String], touching touchedModules: [String]) -> [String] {
    guard !touchedModules.isEmpty else { return [] }
    return graphLines.filter { line in touchedModules.contains { line.contains($0) } }
  }
}

// MARK: - Per-role inputs

/// spec §5.10 research lane row: frame answers, area, a module-graph slice for the touched
/// modules named in the frame answers, and a lane brief (opaque text, passed through), plus
/// existing claims pinned to the same version — both the repo's own and the user-level evidence
/// reuse cache's — since a cache hit is a claim already proven for this exact pin, so the lane
/// doesn't re-derive it. The pack also names the pin, the design doc and the evidence already
/// stored beside it, since a lane can pin a claim or cite a snapshot only if it knows them.
public struct ResearchLaneInputs: Sendable {
  public let frameAnswers: ContextSource
  public let area: String
  public let moduleGraph: ContextSource
  public let touchedModules: [String]
  public let briefs: [ContextSource]
  public let claims: ContextSource
  /// Live (non-tombstoned) claims for `pin` from the user-level evidence reuse cache
  /// (`EvidenceCacheStore.contents(of: .package(pin:))`); the caller resolves the cache, this
  /// type only renders what it found.
  public let cacheHits: [CachedClaim]
  public let pin: ResearchLanePin
  /// The design doc's repo-relative path. Research runs before the draft, so the file may not
  /// exist yet.
  public let designDocPath: String
  /// Snapshot and capture locs already stored under the doc's evidence directory, relative to it
  /// (`snapshots/<name>`, `captures/<hex>.txt`).
  public let storedEvidence: [String]

  public init(
    frameAnswers: ContextSource, area: String, moduleGraph: ContextSource,
    touchedModules: [String], briefs: [ContextSource], claims: ContextSource,
    cacheHits: [CachedClaim], pin: ResearchLanePin, designDocPath: String,
    storedEvidence: [String]
  ) {
    self.frameAnswers = frameAnswers
    self.area = area
    self.moduleGraph = moduleGraph
    self.touchedModules = touchedModules
    self.briefs = briefs
    self.claims = claims
    self.cacheHits = cacheHits
    self.pin = pin
    self.designDocPath = designDocPath
    self.storedEvidence = storedEvidence
  }
}

/// spec §5.10 claim checker row: the claim records to judge, and only their cited ranges.
public struct ClaimCheckerInputs: Sendable {
  public let entries: [ClaimToJudge]

  public init(entries: [ClaimToJudge]) {
    self.entries = entries
  }
}

/// spec §5.10 drafter row: template; frame answers; `supported` claims (at `sketch`, also the
/// user's `quote-ok` answer claims); probe verdicts; standards anchors for the module kinds in
/// scope; the `design-lint` word budgets.
public struct DrafterInputs: Sendable {
  public let template: ContextSource
  public let frameAnswers: ContextSource
  public let claims: ContextSource
  public let probeVerdicts: ContextSource
  public let standards: ContextSource
  public let moduleKindAnchors: [String]
  /// The tier the design is claimed at; `nil` when the caller didn't say, which reads as "not
  /// sketch".
  public let tier: DesignTier?
  /// ``wordBudgetSource(_:)`` for the repo's budgets; `nil` leaves the pack without a budget slice.
  public let wordBudgets: ContextSource?

  public init(
    template: ContextSource, frameAnswers: ContextSource, claims: ContextSource,
    probeVerdicts: ContextSource, standards: ContextSource, moduleKindAnchors: [String],
    tier: DesignTier? = nil, wordBudgets: ContextSource? = nil
  ) {
    self.template = template
    self.frameAnswers = frameAnswers
    self.claims = claims
    self.probeVerdicts = probeVerdicts
    self.standards = standards
    self.moduleKindAnchors = moduleKindAnchors
    self.tier = tier
    self.wordBudgets = wordBudgets
  }

  /// The budgets `design-lint` holds a design doc to, as the text the drafter reads.
  public static func wordBudgetSource(_ budgets: DocsBudgets) -> ContextSource {
    let sectionLines = budgets.sections.sorted { $0.key < $1.key }.map {
      "- \($0.key): \($0.value)"
    }
    let lines =
      [
        "Tables, diagrams and code don't count. The whole doc: \(budgets.design) prose words.",
        "Per section, by anchor:",
      ] + sectionLines
    return ContextSource(label: "design-lint word budgets", rawText: lines.joined(separator: "\n"))
  }
}

/// spec §5.10 evidence auditor row: the doc (as the given section anchors); every cited claim with
/// its citation excerpt.
public struct EvidenceAuditorInputs: Sendable {
  public let design: ContextSource
  public let docAnchors: [String]
  public let citedClaims: [ClaimToJudge]

  public init(design: ContextSource, docAnchors: [String], citedClaims: [ClaimToJudge]) {
    self.design = design
    self.docAnchors = docAnchors
    self.citedClaims = citedClaims
  }
}

/// spec §5.10 standards reviewer row: the doc's Module kinds, Decision and Test plan sections
/// (fixed by the spec, not caller-chosen); standards and playbook sections by anchor.
public struct StandardsReviewerInputs: Sendable {
  public let design: ContextSource
  public let standardsAndPlaybook: ContextSource
  public let standardsAnchors: [String]

  public init(
    design: ContextSource, standardsAndPlaybook: ContextSource, standardsAnchors: [String]
  ) {
    self.design = design
    self.standardsAndPlaybook = standardsAndPlaybook
    self.standardsAnchors = standardsAnchors
  }
}

/// spec §5.10 challenger row: the doc (as the given section anchors); the challenger question set.
public struct ChallengerInputs: Sendable {
  public let design: ContextSource
  public let docAnchors: [String]
  public let questionSet: ContextSource

  public init(design: ContextSource, docAnchors: [String], questionSet: ContextSource) {
    self.design = design
    self.docAnchors = docAnchors
    self.questionSet = questionSet
  }
}

/// spec §5.10 decomposer row: Requirements, Module kinds and Test plan sections (fixed by the
/// spec); the module graph; the plan's task-sizing bounds (spec §9.3 / `[plan]` config).
public struct DecomposerInputs: Sendable {
  public let design: ContextSource
  public let moduleGraph: ContextSource
  public let taskSizingBounds: ContextSource

  public init(design: ContextSource, moduleGraph: ContextSource, taskSizingBounds: ContextSource) {
    self.design = design
    self.moduleGraph = moduleGraph
    self.taskSizingBounds = taskSizingBounds
  }
}

/// A spec page a pack reads from: the parsed page, and its raw text labelled with its path, which
/// every excerpt is cut from byte for byte.
public struct SpecPageSource: Sendable, Equatable {
  public let page: SpecPage
  public let source: ContextSource

  public init(page: SpecPage, source: ContextSource) {
    self.page = page
    self.source = source
  }
}

/// The decomposer's inputs when a spec page is the plan's source (fast modes §5.2): the page's
/// Modules, Surface and Slices sections, the module graph and the task-sizing bounds.
public struct SpecPageDecomposerInputs: Sendable {
  public let specPage: SpecPageSource
  public let moduleGraph: ContextSource
  public let taskSizingBounds: ContextSource

  public init(
    specPage: SpecPageSource, moduleGraph: ContextSource, taskSizingBounds: ContextSource
  ) {
    self.specPage = specPage
    self.moduleGraph = moduleGraph
    self.taskSizingBounds = taskSizingBounds
  }
}

/// A worker's inputs when a spec page is the plan's source: as ``WorkerInputs``, with the page in
/// place of the design, and the modules the task's write set touches, whose Modules rows it gets.
public struct SpecPageWorkerInputs: Sendable {
  public let task: LedgerTask
  public let specPage: SpecPageSource
  public let claims: ContextSource
  public let citedClaimIDs: [String]
  public let standards: ContextSource
  public let moduleKindAnchors: [String]
  /// The modules the task's write set touches, as ``SpecPageWriteSet/resolve(_:graph:page:packageDirectories:)``
  /// counts them.
  public let touchedModules: Set<String>
  public let dependencyNotes: [DependencyReturnNotes]

  public init(
    task: LedgerTask, specPage: SpecPageSource, claims: ContextSource, citedClaimIDs: [String],
    standards: ContextSource, moduleKindAnchors: [String], touchedModules: Set<String>,
    dependencyNotes: [DependencyReturnNotes] = []
  ) {
    self.task = task
    self.specPage = specPage
    self.claims = claims
    self.citedClaimIDs = citedClaimIDs
    self.standards = standards
    self.moduleKindAnchors = moduleKindAnchors
    self.touchedModules = touchedModules
    self.dependencyNotes = dependencyNotes
  }
}

/// One dependency's task-return notes for a worker pack's dependency-notes section (spec §5.3), or
/// its absence. `notes` is `nil` only when the caller couldn't read or decode that dependency's
/// task return — never an empty string standing in for "not available" (worker-brief pitfall 2).
public struct DependencyReturnNotes: Sendable, Equatable {
  public let taskID: String
  public let notes: String?

  public init(taskID: String, notes: String?) {
    self.taskID = taskID
    self.notes = notes
  }
}

/// spec §5.10 worker row: its ledger task entry; design sections covering its `covers` ids, and
/// the Decision and Architecture sections, verbatim by anchor; cited claims; standards anchors for its modules' kinds; gate tier (carried
/// inside the encoded ledger entry — every `LedgerTask` has one); spec §5.3: the task-return notes
/// of every task this one depends on, already in the ledger's dependency order.
public struct WorkerInputs: Sendable {
  public let task: LedgerTask
  public let design: DesignDocument
  public let designSource: ContextSource
  public let claims: ContextSource
  public let citedClaimIDs: [String]
  public let standards: ContextSource
  public let moduleKindAnchors: [String]
  /// Empty when the pack was built without `--build-run`, or the task has no `deps` — the pack
  /// then carries no dependency-notes section, byte-identical to before this field existed.
  public let dependencyNotes: [DependencyReturnNotes]

  public init(
    task: LedgerTask, design: DesignDocument, designSource: ContextSource, claims: ContextSource,
    citedClaimIDs: [String], standards: ContextSource, moduleKindAnchors: [String],
    dependencyNotes: [DependencyReturnNotes] = []
  ) {
    self.task = task
    self.design = design
    self.designSource = designSource
    self.claims = claims
    self.citedClaimIDs = citedClaimIDs
    self.standards = standards
    self.moduleKindAnchors = moduleKindAnchors
    self.dependencyNotes = dependencyNotes
  }
}

/// The closed set of per-role inputs `ContextPack.build(role:inputs:)` dispatches on. One case per
/// ``ContextPackRole`` — a role the enum has no case for can't be built, and a `build` call can't
/// silently drop one, because the switch that consumes this is exhaustive with no `default`.
public enum ContextPackRoleInputs: Sendable {
  case researchLane(ResearchLaneInputs)
  case claimChecker(ClaimCheckerInputs)
  case drafter(DrafterInputs)
  case evidenceAuditor(EvidenceAuditorInputs)
  case standardsReviewer(StandardsReviewerInputs)
  case challenger(ChallengerInputs)
  case decomposer(DecomposerInputs)
  case worker(WorkerInputs)

  public var role: ContextPackRole {
    switch self {
    case .researchLane: return .researchLane
    case .claimChecker: return .claimChecker
    case .drafter: return .drafter
    case .evidenceAuditor: return .evidenceAuditor
    case .standardsReviewer: return .standardsReviewer
    case .challenger: return .challenger
    case .decomposer: return .decomposer
    case .worker: return .worker
    }
  }
}

extension ContextPack {
  /// The one dispatch point from a role and its inputs to a built pack. `role` and `inputs.role`
  /// must agree — a caller that mismatches them (e.g. passing `.worker` with `.drafter` inputs)
  /// gets a loud, typed error instead of a pack built for the wrong role.
  public static func build(role: ContextPackRole, inputs: ContextPackRoleInputs) throws
    -> ContextPack
  {
    guard role == inputs.role else {
      throw ContextPackError.roleMismatch(expected: role, actual: inputs.role)
    }
    switch inputs {
    case .researchLane(let i): return researchLanePack(i)
    case .claimChecker(let i): return try claimCheckerPack(i)
    case .drafter(let i): return try drafterPack(i)
    case .evidenceAuditor(let i): return try evidenceAuditorPack(i)
    case .standardsReviewer(let i): return try standardsReviewerPack(i)
    case .challenger(let i): return try challengerPack(i)
    case .decomposer(let i): return try decomposerPack(i)
    case .worker(let i): return try workerPack(i)
    }
  }

  /// spec §5.10 worker row: the task's own ledger entry, plus only the design sections that cover
  /// its `covers` ids, selected verbatim by anchor. An id that names neither a requirement nor a
  /// test-plan id in `design` fails loudly — a worker pack silently missing coverage it was
  /// supposed to carry is worse than no pack at all.
  public static func workerPack(_ inputs: WorkerInputs) throws -> ContextPack {
    let taskEntryText = try encodeTaskEntry(inputs.task)
    var slices: [ContextPackSlice] = [
      ContextPackSlice(
        sourceLabel: "ledger task entry: \(inputs.task.id)", anchor: nil,
        lines: MarkdownAnchorSlicer.rawLines(taskEntryText))
    ]

    // Duplicate `covers` ids naming the same section aren't corruption — they're just a task
    // legitimately citing the same requirement twice — so the section is included once, not once
    // per mention.
    var includedAnchors: Set<String> = []
    for id in inputs.task.covers {
      let anchor: String
      if inputs.design.requirements.contains(where: { $0.id == id }) {
        anchor = "requirements"
      } else if inputs.design.testPlan.contains(where: { $0.id == id }) {
        anchor = "test-plan-by-tier"
      } else {
        throw ContextPackError.unknownCoversID(id)
      }
      guard includedAnchors.insert(anchor).inserted else { continue }
      slices.append(
        try MarkdownAnchorSlicer.slice(
          anchor: anchor, of: inputs.design.markdown, rawText: inputs.designSource.rawText,
          sourceLabel: inputs.designSource.label))
    }
    // Every worker gets the shape the design chose, so parallel workers don't each invent one.
    // `design-lint` requires both sections, so an approved design always has them.
    for anchor in ["decision", "architecture"]
    where inputs.design.markdown.section(anchor: anchor) != nil {
      slices.append(
        try MarkdownAnchorSlicer.slice(
          anchor: anchor, of: inputs.design.markdown, rawText: inputs.designSource.rawText,
          sourceLabel: inputs.designSource.label))
    }

    let cited = ClaimLineFilter.lines(
      in: MarkdownAnchorSlicer.rawLines(inputs.claims.rawText)
    ) { inputs.citedClaimIDs.contains($0.id) }
    if !cited.isEmpty {
      slices.append(ContextPackSlice(sourceLabel: inputs.claims.label, anchor: nil, lines: cited))
    }

    slices.append(
      contentsOf: try MarkdownAnchorSlicer.slice(
        anchors: inputs.moduleKindAnchors, from: inputs.standards))

    if !inputs.dependencyNotes.isEmpty {
      var noteLines: [String] = []
      for dependency in inputs.dependencyNotes {
        guard let notes = dependency.notes else {
          throw ContextPackError.missingDependencyReturn(task: dependency.taskID)
        }
        noteLines.append(dependency.taskID)
        noteLines.append(contentsOf: MarkdownAnchorSlicer.rawLines(notes))
      }
      slices.append(
        ContextPackSlice(
          sourceLabel: "Notes from the tasks this one depends on", anchor: nil, lines: noteLines))
    }

    return ContextPack(role: .worker, slices: slices)
  }

  /// The order a worker pack's dependency-notes section lists a task's `deps` in (spec §5.3): the
  /// same order `ledger`'s own wave schedule (``Ledger/waves``) already puts them in, since that's
  /// the ledger's canonical dependency order — earlier wave first, id-ascending within a wave. A
  /// dependency `ledger.waves` doesn't name (an unscheduled or stale ledger) sorts after every
  /// named one, then by id, so the ordering stays total and deterministic either way.
  public static func dependencyOrder(of deps: [String], in ledger: Ledger) -> [String] {
    var position: [String: Int] = [:]
    for id in ledger.waves.flatMap({ $0 }) where position[id] == nil {
      position[id] = position.count
    }
    return deps.sorted { lhs, rhs in
      let (left, right) = (position[lhs] ?? Int.max, position[rhs] ?? Int.max)
      return left != right ? left < right : lhs < rhs
    }
  }

  private static func encodeTaskEntry(_ task: LedgerTask) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    let data = try encoder.encode(task)
    return String(decoding: data, as: UTF8.self)
  }

  /// spec §5.10 claim checker row: the claim records to judge, and only their cited ranges — never
  /// the files or snapshots they're cited from in full.
  public static func claimCheckerPack(_ inputs: ClaimCheckerInputs) throws -> ContextPack {
    ContextPack(role: .claimChecker, slices: try claimExcerptSlices(for: inputs.entries))
  }

  /// spec §5.10 evidence auditor row: the doc, plus every cited claim with its citation excerpt —
  /// the same "cited excerpt only" mechanism the claim checker uses.
  public static func evidenceAuditorPack(_ inputs: EvidenceAuditorInputs) throws -> ContextPack {
    var slices = try MarkdownAnchorSlicer.slice(anchors: inputs.docAnchors, from: inputs.design)
    slices.append(contentsOf: try claimExcerptSlices(for: inputs.citedClaims))
    return ContextPack(role: .evidenceAuditor, slices: slices)
  }

  /// Interleaves each claim's raw `claims.jsonl` line with its citation's excerpt — shared by the
  /// claim checker and evidence auditor, which cite claims the same way.
  private static func claimExcerptSlices(for entries: [ClaimToJudge]) throws -> [ContextPackSlice] {
    var slices: [ContextPackSlice] = []
    let decoder = JSONDecoder()
    for entry in entries {
      slices.append(
        ContextPackSlice(
          sourceLabel: entry.claimsSourceLabel, anchor: nil, lines: [entry.claimRawLine]))
      guard let data = entry.claimRawLine.data(using: .utf8),
        let claim = try? decoder.decode(Claim.self, from: data)
      else {
        throw ContextPackError.invalidCitationRange(entry.claimRawLine)
      }
      slices.append(
        try CitationExcerptSlicer.slice(
          for: claim.citation, rawText: entry.citationRawText,
          sourceLabel: entry.citationSourceLabel))
      if let verdict = entry.probeVerdict { slices.append(ContextPackSlice(verdict)) }
    }
    return slices
  }

  /// spec §5.10 research lane row.
  public static func researchLanePack(_ inputs: ResearchLaneInputs) -> ContextPack {
    var slices: [ContextPackSlice] = [
      ContextPackSlice(
        sourceLabel: "research pin", anchor: nil,
        lines: [
          "pin: \(inputs.pin.rawValue) (\(inputs.pin.kind.rawValue))",
          "citation.pin: \(inputs.pin.claimPin)",
        ]),
      ContextPackSlice(
        sourceLabel: "design", anchor: nil,
        lines: [
          "design doc: \(inputs.designDocPath)",
          "evidence directory: \(EvidenceLayout(designDocPath: inputs.designDocPath).root)",
        ]),
    ]
    if !inputs.storedEvidence.isEmpty {
      slices.append(
        ContextPackSlice(
          sourceLabel: "stored evidence", anchor: nil, lines: inputs.storedEvidence))
    }
    slices.append(ContextPackSlice(inputs.frameAnswers))
    slices.append(ContextPackSlice(sourceLabel: "area", anchor: nil, lines: [inputs.area]))

    let graphLines = ModuleGraphLineFilter.lines(
      in: MarkdownAnchorSlicer.rawLines(inputs.moduleGraph.rawText),
      touching: inputs.touchedModules)
    if !graphLines.isEmpty {
      slices.append(
        ContextPackSlice(sourceLabel: inputs.moduleGraph.label, anchor: nil, lines: graphLines))
    }

    slices.append(contentsOf: inputs.briefs.map { ContextPackSlice($0) })

    let repoCacheHits = ClaimLineFilter.lines(
      in: MarkdownAnchorSlicer.rawLines(inputs.claims.rawText)
    ) { $0.citation.pin == inputs.pin.claimPin }
    if !repoCacheHits.isEmpty {
      slices.append(
        ContextPackSlice(sourceLabel: inputs.claims.label, anchor: nil, lines: repoCacheHits))
    }

    if !inputs.cacheHits.isEmpty {
      let lines = inputs.cacheHits.compactMap { cached -> String? in
        guard let data = try? ClaimJSON.encodeLine(cached.claim.claim) else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
      }
      if !lines.isEmpty {
        slices.append(
          ContextPackSlice(
            sourceLabel: "evidence cache: \(inputs.pin.claimPin)", anchor: nil, lines: lines))
      }
    }

    return ContextPack(role: .researchLane, slices: slices)
  }

  /// spec §5.10 drafter row.
  public static func drafterPack(_ inputs: DrafterInputs) throws -> ContextPack {
    var slices = [ContextPackSlice(inputs.template), ContextPackSlice(inputs.frameAnswers)]
    // At sketch no claim checker runs, so the user's own frame answers never reach `supported`;
    // `design-lint` accepts a `quote-ok` answer there, and the drafter has to see it to cite it.
    let acceptsCheckedAnswers = inputs.tier == .sketch
    let supported = ClaimLineFilter.lines(
      in: MarkdownAnchorSlicer.rawLines(inputs.claims.rawText)
    ) { claim in
      claim.status == .supported
        || (acceptsCheckedAnswers && claim.citation.kind == .answer && claim.status == .quoteOk)
    }
    if !supported.isEmpty {
      slices.append(
        ContextPackSlice(sourceLabel: inputs.claims.label, anchor: nil, lines: supported))
    }
    slices.append(ContextPackSlice(inputs.probeVerdicts))
    if let wordBudgets = inputs.wordBudgets { slices.append(ContextPackSlice(wordBudgets)) }
    slices.append(
      contentsOf: try MarkdownAnchorSlicer.slice(
        anchors: inputs.moduleKindAnchors, from: inputs.standards))
    return ContextPack(role: .drafter, slices: slices)
  }

  /// spec §5.10 standards reviewer row.
  public static func standardsReviewerPack(_ inputs: StandardsReviewerInputs) throws
    -> ContextPack
  {
    var slices = try MarkdownAnchorSlicer.slice(
      anchors: ["module-kinds", "decision", "test-plan-by-tier"], from: inputs.design)
    slices.append(
      contentsOf: try MarkdownAnchorSlicer.slice(
        anchors: inputs.standardsAnchors, from: inputs.standardsAndPlaybook))
    return ContextPack(role: .standardsReviewer, slices: slices)
  }

  /// spec §5.10 challenger row.
  public static func challengerPack(_ inputs: ChallengerInputs) throws -> ContextPack {
    var slices = try MarkdownAnchorSlicer.slice(anchors: inputs.docAnchors, from: inputs.design)
    slices.append(ContextPackSlice(inputs.questionSet))
    return ContextPack(role: .challenger, slices: slices)
  }

  /// spec §5.10 decomposer row.
  public static func decomposerPack(_ inputs: DecomposerInputs) throws -> ContextPack {
    var slices = try MarkdownAnchorSlicer.slice(
      anchors: [
        "requirements", "decision", "architecture", "module-kinds", "test-plan-by-tier", "risks",
      ], from: inputs.design)
    slices.append(ContextPackSlice(inputs.moduleGraph))
    slices.append(ContextPackSlice(inputs.taskSizingBounds))
    return ContextPack(role: .decomposer, slices: slices)
  }
}

extension ContextPack {
  /// The decomposer's pack for a spec page.
  public static func specPageDecomposerPack(_ inputs: SpecPageDecomposerInputs) throws
    -> ContextPack
  {
    ContextPack(role: .decomposer, slices: [])
  }

  /// A worker's pack for a spec page.
  public static func specPageWorkerPack(_ inputs: SpecPageWorkerInputs) throws -> ContextPack {
    ContextPack(role: .worker, slices: [])
  }
}

/// Resolves a worker's write set when a spec page is the plan's source.
public enum SpecPageWriteSet {
  public static func resolve(
    _ writeSet: [String], graph: ModuleGraph, page: SpecPage, packageDirectories: [String]
  ) -> WriteSetResolution {
    PlanLintGraph.resolveWriteSet(
      writeSet, graph: graph, design: nil, packageDirectories: packageDirectories)
  }
}

/// The module kinds a worker's write set touches, read from the repository's module graph so a
/// worker never chooses the standards it is held to.
public enum WorkerModuleKinds {
  /// Each entry is a file or, with a trailing `/`, a directory. A test target counts as the module
  /// it tests, as `plan-lint` counts it, so an engine's tests get the engine standards. An entry
  /// outside every module (a doc, a manifest, a fixture) adds no kind, so the result is empty for
  /// a write set with no module entries.
  public static func kinds(writeSet: [String], graph: ModuleGraph) throws(ContextPackError)
    -> [ModuleKind]
  {
    var kinds = Set<ModuleKind>()
    for entry in writeSet {
      let path = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
      var modules: [Module] = graph.module(containingFile: path).map { [$0] } ?? []
      if modules.isEmpty, entry.hasSuffix("/") {
        modules = graph.modules.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
      }
      for module in modules {
        guard let counted = graph.module(named: PlanLintGraph.countedModule(module, graph: graph))
        else { throw .unknownModuleKind(writeSetEntry: entry) }
        kinds.insert(counted.kind)
      }
    }
    return ModuleKind.allCases.filter(kinds.contains)
  }
}
