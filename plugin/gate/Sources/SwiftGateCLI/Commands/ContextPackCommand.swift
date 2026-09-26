import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Every flag `context-pack` accepts, across all 8 roles. Which ones are actually required
/// depends on `--role` (checked in ``ContextPackRun``, not by ArgumentParser) — a single option
/// group keeps the command's argument surface in one place instead of duplicating it per role.
struct ContextPackOptions: ParsableArguments {
  @Option(help: "The agent role the pack is sliced for (spec §5.10).")
  var role: String

  @Option(help: "Distinguishes several packs of the same role, e.g. a worker's task id.")
  var key: String?

  // Research lane
  @Option(help: "A lane brief text. Repeatable.")
  var brief: [String] = []
  @Option(help: "The package/SDK pin a research lane's claim cache hits must match.")
  var pin: String?
  @Option(help: "The design's area (research lane).")
  var area: String?
  @Option(help: "The evidence reuse cache's home directory; defaults to $HOME.")
  var cacheHome: String?

  // Design-anchored roles (evidence auditor, standards reviewer, challenger, decomposer, worker)
  @Option(help: "Path to the design doc.")
  var design: String?
  @Option(help: "A design section anchor to include verbatim. Repeatable.")
  var docAnchor: [String] = []

  // Drafter
  @Option(help: "Path to the design template.")
  var template: String?
  @Option(help: "Path to the frame-answers transcript.")
  var frameAnswers: String?
  @Option(help: "Path to recorded probe verdicts.")
  var probeVerdicts: String?

  // Standards (drafter, standards reviewer, worker)
  @Option(help: "Path to docs/standards.md.")
  var standards: String?
  @Option(help: "Path to docs/testing-playbook.md, appended to --standards.")
  var playbook: String?
  @Option(help: "A module kind in scope, mapped to its standards anchors. Repeatable.")
  var moduleKind: [String] = []
  @Option(help: "A standards/playbook anchor to include verbatim (standards reviewer). Repeatable.")
  var standardsAnchor: [String] = []

  // Claims (research lane, claim checker, drafter, evidence auditor, worker)
  @Option(help: "Path to claims.jsonl.")
  var claims: String?
  @Option(help: "A claim id to include, with its cited excerpt. Repeatable.")
  var claimID: [String] = []

  // Challenger
  @Option(help: "Path to the challenger question set.")
  var questionSet: String?

  // Decomposer
  @Option(help: "Path to a module-graph dump.")
  var moduleGraph: String?
  @Option(help: "Path to the plan's task-sizing bounds.")
  var taskSizingBounds: String?

  // Worker
  @Option(help: "Path to ledger.json.")
  var ledger: String?
  @Option(help: "The ledger task id to pack.")
  var taskID: String?

  var gatherInputs: ContextPackGatherInputs {
    ContextPackGatherInputs(
      key: key, brief: brief, pin: pin, area: area, cacheHome: cacheHome, design: design,
      docAnchor: docAnchor, template: template,
      frameAnswers: frameAnswers, probeVerdicts: probeVerdicts, standards: standards,
      playbook: playbook, moduleKind: moduleKind, standardsAnchor: standardsAnchor, claims: claims,
      claimID: claimID, questionSet: questionSet, moduleGraph: moduleGraph,
      taskSizingBounds: taskSizingBounds, ledger: ledger, taskID: taskID)
  }
}

/// The same inputs as ``ContextPackOptions``, minus `role` (dispatched on separately) and the
/// ArgumentParser property wrappers, so ``ContextPackRun`` and its tests can construct a role's
/// inputs directly without going through argument parsing.
struct ContextPackGatherInputs: Sendable, Equatable {
  var key: String?
  var brief: [String] = []
  var pin: String?
  var area: String?
  var cacheHome: String?
  var design: String?
  var docAnchor: [String] = []
  var template: String?
  var frameAnswers: String?
  var probeVerdicts: String?
  var standards: String?
  var playbook: String?
  var moduleKind: [String] = []
  var standardsAnchor: [String] = []
  var claims: String?
  var claimID: [String] = []
  var questionSet: String?
  var moduleGraph: String?
  var taskSizingBounds: String?
  var ledger: String?
  var taskID: String?
}

/// The deterministic body of `context-pack`: gathers a role's inputs from disk, builds the pack
/// through the existing domain slicers, and writes it to
/// `.harness/context-pack/<role>[-<key>].md`. Factored out of the `ParsableCommand` so it's
/// testable without argument parsing or stdout (matches `DesignScopeRun`).
enum ContextPackRun {
  struct Written: Sendable, Equatable {
    let role: ContextPackRole
    let relativePath: String
    let tokens: Int
    let notes: [String]
  }

  enum Outcome: Sendable, Equatable {
    case written(Written)
    /// A gathering problem: a bad `--role`, a missing/unreadable required input, or an unknown
    /// value in a closed set. Exit 2 — the environment/invocation is wrong, not the pack's
    /// contents.
    case invalid(message: String)
    /// The domain refused to build the pack (missing anchor, unknown `covers` id, a citation
    /// that doesn't check out, …). Exit 1 — a real finding, never a silently thin pack.
    case violation(message: String)
  }

  /// One role's gathered inputs, its notes about absent optional inputs, and the output key
  /// (`nil` unless the role picks a default, as worker does from its task id).
  private typealias Gathered = (inputs: ContextPackRoleInputs, notes: [String], key: String?)

  /// A gathering-stage failure message (bad flag, unreadable path, unknown value). Wraps
  /// `String` only because `Result`'s failure type must conform to `Error`.
  private struct GatherFailure: Error, Sendable, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
  }

  static func run(
    role roleRaw: String, options: ContextPackGatherInputs, root: URL, swiftPM: any SwiftPM
  ) async -> Outcome {
    guard let role = ContextPackRole(rawValue: roleRaw) else {
      return .invalid(
        message:
          "unknown --role `\(roleRaw)`; expected one of "
          + ContextPackRole.allCases.map(\.rawValue).joined(separator: ", "))
    }

    let gathered: Result<Gathered, GatherFailure>
    switch role {
    case .researchLane: gathered = await gatherResearchLane(options, root, swiftPM)
    case .claimChecker: gathered = gatherClaimChecker(options, root)
    case .drafter: gathered = gatherDrafter(options, root)
    case .evidenceAuditor: gathered = gatherEvidenceAuditor(options, root)
    case .standardsReviewer: gathered = gatherStandardsReviewer(options, root)
    case .challenger: gathered = gatherChallenger(options, root)
    case .decomposer: gathered = gatherDecomposer(options, root)
    case .worker: gathered = gatherWorker(options, root)
    }

    let (inputs, notes, key): Gathered
    switch gathered {
    case .failure(let failure): return .invalid(message: failure.message)
    case .success(let value): (inputs, notes, key) = value
    }

    let pack: ContextPack
    do {
      pack = try ContextPack.build(role: role, inputs: inputs)
    } catch let error as ContextPackError {
      return .violation(message: describe(error))
    } catch {
      return .violation(message: "\(error)")
    }

    let relativePath = outputPath(role: role, key: key)
    do {
      try write(render(pack: pack, notes: notes), to: root.appending(path: relativePath))
    } catch {
      return .invalid(message: "can't write `\(relativePath)`: \(error.localizedDescription)")
    }
    return .written(
      Written(
        role: role, relativePath: relativePath, tokens: pack.estimatedTokens.value, notes: notes))
  }

  // MARK: - Per-role gathering

  private static func gatherResearchLane(
    _ o: ContextPackGatherInputs, _ root: URL, _ swiftPM: any SwiftPM
  ) async -> Result<Gathered, GatherFailure> {
    guard let frameAnswersPath = o.frameAnswers else {
      return .failure(GatherFailure("missing required option '--frame-answers <path>'"))
    }
    guard let area = o.area else {
      return .failure(GatherFailure("missing required option '--area <string>'"))
    }
    guard let moduleGraphPath = o.moduleGraph else {
      return .failure(GatherFailure("missing required option '--module-graph <path>'"))
    }
    guard !o.brief.isEmpty else {
      return .failure(GatherFailure("missing required option '--brief <path>' (at least one)"))
    }
    guard let pin = o.pin else {
      return .failure(GatherFailure("missing required option '--pin <string>'"))
    }

    let frameAnswers: ContextSource
    switch ContextPackFiles.read(label: frameAnswersPath, path: frameAnswersPath, root: root) {
    case .success(let s): frameAnswers = s
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    let moduleGraph: ContextSource
    switch ContextPackFiles.read(label: moduleGraphPath, path: moduleGraphPath, root: root) {
    case .success(let s): moduleGraph = s
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    var briefs: [ContextSource] = []
    for path in o.brief {
      switch ContextPackFiles.read(label: path, path: path, root: root) {
      case .success(let source): briefs.append(source)
      case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
      }
    }

    let touchedModules: [String]
    switch await resolvedTouchedModules(namedIn: frameAnswers, root: root, swiftPM: swiftPM) {
    case .failure(let message): return .failure(message)
    case .success(let names): touchedModules = names
    }

    var notes: [String] = []
    let claimsSource: ContextSource
    switch optionalClaims(o.claims, root: root, notes: &notes) {
    case .failure(let message): return .failure(message)
    case .success(let s): claimsSource = s
    }

    switch cacheHits(for: pin, options: o) {
    case .failure(let message): return .failure(message)
    case .success(let (hits, cacheNotes)):
      notes.append(contentsOf: cacheNotes)
      return .success(
        (
          .researchLane(
            ResearchLaneInputs(
              frameAnswers: frameAnswers, area: area, moduleGraph: moduleGraph,
              touchedModules: touchedModules, briefs: briefs, claims: claimsSource,
              cacheHits: hits, pin: pin)), notes, o.key
        ))
    }
  }

  /// The touched modules a research-lane pack slices its module graph to are the SAME
  /// `touchedModules` `design-scope` already decodes from this exact frame-answers file — never
  /// a second CLI input naming them independently, which could drift from what the frame answers
  /// actually say. Validated against the real module graph the same way `design-scope` validates
  /// them (`DesignScope.deriveFacts`): a name the graph doesn't have is a gathering failure, not
  /// a pack built against a module that doesn't exist.
  private static func resolvedTouchedModules(
    namedIn frameAnswers: ContextSource, root: URL, swiftPM: any SwiftPM
  ) async -> Result<[String], GatherFailure> {
    let answers: DesignScopeAnswers
    do {
      answers = try DesignScopeInputJSON.decode(Data(frameAnswers.rawText.utf8))
    } catch {
      return .failure(
        GatherFailure("`\(frameAnswers.label)` is not a valid frame-answers file: \(error)"))
    }

    let config: Config
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let loaded?): config = loaded
    case .success(nil):
      return .failure(
        GatherFailure("no \(ConfigLoader.fileName): context-pack needs the module graph"))
    case .failure(let failure):
      return .failure(GatherFailure(configFailureMessage(failure.outcome)))
    }
    let graph: ModuleGraph
    do {
      graph = try await ModuleGraphLoader(swiftPM: swiftPM, root: root).load(config: config)
    } catch {
      return .failure(GatherFailure("can't load the module graph: \(error)"))
    }

    do throws(DesignScopeValidationError) {
      _ = try DesignScope.deriveFacts(answers: answers, graph: graph)
    } catch {
      return .failure(GatherFailure("\(error)"))
    }
    return .success(answers.touchedModules)
  }

  private static func configFailureMessage(_ outcome: StaticCheckOutcome) -> String {
    switch outcome {
    case .blocked(let reason): reason
    case .invalid(let reason, _): reason
    case .checked: "\(ConfigLoader.fileName) could not be loaded"
    }
  }

  /// Reads live (non-tombstoned) claims for `pin` from the user-level evidence reuse cache
  /// (`--cache-home`, defaulting to `$HOME`; tests always pass an explicit temp `--cache-home` so
  /// they never touch the real one). A corrupt cache line is named as a note, never dropped
  /// silently; an empty cache is named as a note too, never a silently thinner pack.
  private static func cacheHits(for pin: String, options o: ContextPackGatherInputs) -> Result<
    (hits: [CachedClaim], notes: [String]), GatherFailure
  > {
    guard let cacheHome = o.cacheHome ?? ProcessInfo.processInfo.environment["HOME"] else {
      return .failure(
        GatherFailure("missing required option '--cache-home <path>' ($HOME is not set)"))
    }
    let bucket: EvidenceCacheBucket
    switch ResearchLanePin(pin) {
    case .commit:
      return .success(
        (hits: [], notes: ["\(pin) is a commit: the reuse cache holds no codebase claims"]))
    case .package: bucket = .package(pin: pin)
    case .sdk: bucket = .sdk(pin: pin)
    }
    let store = EvidenceCacheStore(home: URL(filePath: cacheHome, directoryHint: .isDirectory))
    let contents: EvidenceCacheContents
    do {
      contents = try store.contents(of: bucket)
    } catch {
      return .failure(GatherFailure("can't read the evidence cache for `\(pin)`: \(error)"))
    }
    var notes = contents.findings.map { "evidence cache: \($0.message)" }
    if contents.claims.isEmpty { notes.append("no cache hits for \(pin)") }
    return .success((hits: contents.claims, notes: notes))
  }

  private static func gatherClaimChecker(_ o: ContextPackGatherInputs, _ root: URL) -> Result<
    Gathered, GatherFailure
  > {
    guard let designPath = o.design else {
      return .failure(GatherFailure("missing required option '--design <path>'"))
    }
    guard let claimsPath = o.claims else {
      return .failure(GatherFailure("missing required option '--claims <path>'"))
    }
    switch ContextPackFiles.read(label: claimsPath, path: claimsPath, root: root) {
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    case .success(let claimsSource):
      let evidenceLayout = EvidenceLayout(designDocPath: designPath)
      switch gatherClaimEntries(
        claimIDs: o.claimID, claimsPath: claimsPath, claimsSource: claimsSource,
        evidenceLayout: evidenceLayout, root: root)
      {
      case .failure(let message): return .failure(message)
      case .success(let entries):
        return .success((.claimChecker(ClaimCheckerInputs(entries: entries)), [], nil))
      }
    }
  }

  private static func gatherDrafter(_ o: ContextPackGatherInputs, _ root: URL) -> Result<
    Gathered, GatherFailure
  > {
    guard let templatePath = o.template else {
      return .failure(GatherFailure("missing required option '--template <path>'"))
    }
    guard let frameAnswersPath = o.frameAnswers else {
      return .failure(GatherFailure("missing required option '--frame-answers <path>'"))
    }
    guard let standardsPath = o.standards else {
      return .failure(GatherFailure("missing required option '--standards <path>'"))
    }
    let template: ContextSource
    switch ContextPackFiles.read(label: templatePath, path: templatePath, root: root) {
    case .success(let s): template = s
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    let frameAnswers: ContextSource
    switch ContextPackFiles.read(label: frameAnswersPath, path: frameAnswersPath, root: root) {
    case .success(let s): frameAnswers = s
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    let standards: ContextSource
    switch readStandardsAndPlaybook(
      standardsPath: standardsPath, playbookPath: o.playbook, root: root)
    {
    case .success(let s): standards = s
    case .failure(let message): return .failure(message)
    }

    var notes: [String] = []
    let claims: ContextSource
    switch optionalClaims(o.claims, root: root, notes: &notes) {
    case .success(let s): claims = s
    case .failure(let message): return .failure(message)
    }
    let probeVerdicts: ContextSource
    if let probeVerdictsPath = o.probeVerdicts {
      switch ContextPackFiles.read(label: probeVerdictsPath, path: probeVerdictsPath, root: root) {
      case .success(let s): probeVerdicts = s
      case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
      }
    } else {
      notes.append("--probe-verdicts not given: pack has no probe-verdicts slice")
      probeVerdicts = ContextSource(label: "probe verdicts", rawText: "")
    }

    switch moduleKindAnchors(o.moduleKind) {
    case .failure(let message): return .failure(message)
    case .success(let anchors):
      return .success(
        (
          .drafter(
            DrafterInputs(
              template: template, frameAnswers: frameAnswers, claims: claims,
              probeVerdicts: probeVerdicts, standards: standards, moduleKindAnchors: anchors)),
          notes, nil
        ))
    }
  }

  private static func gatherEvidenceAuditor(_ o: ContextPackGatherInputs, _ root: URL) -> Result<
    Gathered, GatherFailure
  > {
    guard let designPath = o.design else {
      return .failure(GatherFailure("missing required option '--design <path>'"))
    }
    let design: ContextSource
    switch ContextPackFiles.read(label: designPath, path: designPath, root: root) {
    case .success(let s): design = s
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    guard !o.docAnchor.isEmpty else {
      return .failure(
        GatherFailure("missing required option '--doc-anchor <anchor>' (at least one)"))
    }

    var entries: [ClaimToJudge] = []
    if !o.claimID.isEmpty {
      guard let claimsPath = o.claims else {
        return .failure(
          GatherFailure("missing required option '--claims <path>' (--claim-id given)"))
      }
      switch ContextPackFiles.read(label: claimsPath, path: claimsPath, root: root) {
      case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
      case .success(let claimsSource):
        let evidenceLayout = EvidenceLayout(designDocPath: designPath)
        switch gatherClaimEntries(
          claimIDs: o.claimID, claimsPath: claimsPath, claimsSource: claimsSource,
          evidenceLayout: evidenceLayout, root: root)
        {
        case .failure(let message): return .failure(message)
        case .success(let gathered): entries = gathered
        }
      }
    }

    return .success(
      (
        .evidenceAuditor(
          EvidenceAuditorInputs(design: design, docAnchors: o.docAnchor, citedClaims: entries)),
        [], nil
      ))
  }

  private static func gatherStandardsReviewer(_ o: ContextPackGatherInputs, _ root: URL) -> Result<
    Gathered, GatherFailure
  > {
    guard let designPath = o.design else {
      return .failure(GatherFailure("missing required option '--design <path>'"))
    }
    guard let standardsPath = o.standards else {
      return .failure(GatherFailure("missing required option '--standards <path>'"))
    }
    let design: ContextSource
    switch ContextPackFiles.read(label: designPath, path: designPath, root: root) {
    case .success(let s): design = s
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    let standards: ContextSource
    switch readStandardsAndPlaybook(
      standardsPath: standardsPath, playbookPath: o.playbook, root: root)
    {
    case .success(let s): standards = s
    case .failure(let message): return .failure(message)
    }
    return .success(
      (
        .standardsReviewer(
          StandardsReviewerInputs(
            design: design, standardsAndPlaybook: standards, standardsAnchors: o.standardsAnchor)),
        [], nil
      ))
  }

  private static func gatherChallenger(_ o: ContextPackGatherInputs, _ root: URL) -> Result<
    Gathered, GatherFailure
  > {
    guard let designPath = o.design else {
      return .failure(GatherFailure("missing required option '--design <path>'"))
    }
    guard let questionSetPath = o.questionSet else {
      return .failure(GatherFailure("missing required option '--question-set <path>'"))
    }
    let design: ContextSource
    switch ContextPackFiles.read(label: designPath, path: designPath, root: root) {
    case .success(let s): design = s
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    let questionSet: ContextSource
    switch ContextPackFiles.read(label: questionSetPath, path: questionSetPath, root: root) {
    case .success(let s): questionSet = s
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    return .success(
      (
        .challenger(
          ChallengerInputs(design: design, docAnchors: o.docAnchor, questionSet: questionSet)), [],
        nil
      ))
  }

  private static func gatherDecomposer(_ o: ContextPackGatherInputs, _ root: URL) -> Result<
    Gathered, GatherFailure
  > {
    guard let designPath = o.design else {
      return .failure(GatherFailure("missing required option '--design <path>'"))
    }
    guard let moduleGraphPath = o.moduleGraph else {
      return .failure(GatherFailure("missing required option '--module-graph <path>'"))
    }
    guard let boundsPath = o.taskSizingBounds else {
      return .failure(GatherFailure("missing required option '--task-sizing-bounds <path>'"))
    }
    let design: ContextSource
    switch ContextPackFiles.read(label: designPath, path: designPath, root: root) {
    case .success(let s): design = s
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    let moduleGraph: ContextSource
    switch ContextPackFiles.read(label: moduleGraphPath, path: moduleGraphPath, root: root) {
    case .success(let s): moduleGraph = s
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    let bounds: ContextSource
    switch ContextPackFiles.read(label: boundsPath, path: boundsPath, root: root) {
    case .success(let s): bounds = s
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    return .success(
      (
        .decomposer(
          DecomposerInputs(design: design, moduleGraph: moduleGraph, taskSizingBounds: bounds)), [],
        nil
      ))
  }

  private static func gatherWorker(_ o: ContextPackGatherInputs, _ root: URL) -> Result<
    Gathered, GatherFailure
  > {
    guard let designPath = o.design else {
      return .failure(GatherFailure("missing required option '--design <path>'"))
    }
    guard let ledgerPath = o.ledger else {
      return .failure(GatherFailure("missing required option '--ledger <path>'"))
    }
    guard let taskID = o.taskID else {
      return .failure(GatherFailure("missing required option '--task-id <id>'"))
    }
    let designSource: ContextSource
    switch ContextPackFiles.read(label: designPath, path: designPath, root: root) {
    case .success(let s): designSource = s
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    let design = DesignDocument(markdown: .parse(designSource.rawText))

    let task: LedgerTask
    switch ContextPackLedger.task(id: taskID, ledgerPath: ledgerPath, root: root) {
    case .success(let t): task = t
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    case .failure(.malformed(let p)): return .failure(GatherFailure("`\(p)` is not a valid ledger"))
    case .failure(.taskNotFound(let id, let p)):
      return .failure(GatherFailure("task `\(id)` not found in `\(p)`"))
    }

    var notes: [String] = []
    let claims: ContextSource
    switch optionalClaims(o.claims, root: root, notes: &notes) {
    case .success(let s): claims = s
    case .failure(let message): return .failure(message)
    }

    switch moduleKindAnchors(o.moduleKind) {
    case .failure(let message): return .failure(message)
    case .success(let anchors):
      let standards: ContextSource
      if anchors.isEmpty {
        standards = ContextSource(label: "standards", rawText: "")
      } else {
        guard let standardsPath = o.standards else {
          return .failure(
            GatherFailure("missing required option '--standards <path>' (--module-kind given)"))
        }
        switch readStandardsAndPlaybook(
          standardsPath: standardsPath, playbookPath: o.playbook, root: root)
        {
        case .success(let s): standards = s
        case .failure(let message): return .failure(message)
        }
      }

      return .success(
        (
          .worker(
            WorkerInputs(
              task: task, design: design, designSource: designSource, claims: claims,
              citedClaimIDs: o.claimID, standards: standards, moduleKindAnchors: anchors)),
          notes, o.key ?? taskID
        ))
    }
  }

  // MARK: - Shared gathering helpers

  private static func optionalClaims(
    _ path: String?, root: URL, notes: inout [String]
  ) -> Result<ContextSource, GatherFailure> {
    guard let path else {
      notes.append("--claims not given: pack has no claims slice")
      return .success(ContextSource(label: "claims.jsonl", rawText: ""))
    }
    switch ContextPackFiles.read(label: path, path: path, root: root) {
    case .success(let source): return .success(source)
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
  }

  private static func readStandardsAndPlaybook(
    standardsPath: String, playbookPath: String?, root: URL
  ) -> Result<ContextSource, GatherFailure> {
    let standardsText: String
    switch ContextPackFiles.read(label: standardsPath, path: standardsPath, root: root) {
    case .success(let s): standardsText = s.rawText
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    guard let playbookPath else {
      return .success(ContextSource(label: standardsPath, rawText: standardsText))
    }
    switch ContextPackFiles.read(label: playbookPath, path: playbookPath, root: root) {
    case .success(let playbook):
      return .success(
        ContextSource(
          label: "\(standardsPath) + \(playbookPath)",
          rawText: standardsText + "\n" + playbook.rawText))
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
  }

  private static func moduleKindAnchors(_ raw: [String]) -> Result<[String], GatherFailure> {
    var kinds: [ModuleKind] = []
    for value in raw {
      guard let kind = ModuleKind(rawValue: value) else {
        return .failure(GatherFailure("unknown --module-kind `\(value)`"))
      }
      kinds.append(kind)
    }
    return .success(ContextPackModuleKindAnchors.anchors(for: kinds))
  }

  private static func gatherClaimEntries(
    claimIDs: [String], claimsPath: String, claimsSource: ContextSource,
    evidenceLayout: EvidenceLayout, root: URL
  ) -> Result<[ClaimToJudge], GatherFailure> {
    var entries: [ClaimToJudge] = []
    let decoder = JSONDecoder()
    for id in claimIDs {
      guard let rawLine = ContextPackClaims.rawLine(forID: id, in: claimsSource.rawText) else {
        return .failure(GatherFailure("claim `\(id)` not found in `\(claimsPath)`"))
      }
      guard let data = rawLine.data(using: .utf8),
        let claim = try? decoder.decode(Claim.self, from: data)
      else {
        return .failure(GatherFailure("claim `\(id)` in `\(claimsPath)` is not valid JSON"))
      }
      switch ContextPackCitationSource.resolve(
        claim.citation, evidenceLayout: evidenceLayout, repoRoot: root)
      {
      case .success(let resolved):
        var verdict: ContextSource?
        if claim.citation.kind == .probe {
          let relative = ProbeVerdictRecord.path(forClaimID: claim.id)
          let path = "\(evidenceLayout.root)/\(relative)"
          switch ContextPackFiles.read(label: relative, path: path, root: root) {
          case .success(let source): verdict = source
          case .failure(.unreadable(let p)):
            return .failure(
              GatherFailure(
                "no probe verdict `\(p)` for claim `\(id)`: run `swiftgate probe` first"))
          }
        }
        entries.append(
          ClaimToJudge(
            claimRawLine: rawLine, claimsSourceLabel: claimsPath,
            citationSourceLabel: resolved.label, citationRawText: resolved.rawText,
            probeVerdict: verdict))
      case .failure(.unreadable(let p)):
        return .failure(GatherFailure("can't read `\(p)` (cited by claim `\(id)`)"))
      }
    }
    return .success(entries)
  }

  // MARK: - Output

  private static func outputPath(role: ContextPackRole, key: String?) -> String {
    let suffix = key.map { "-\($0)" } ?? ""
    return ".harness/context-pack/\(role.rawValue)\(suffix).md"
  }

  private static func render(pack: ContextPack, notes: [String]) -> String {
    var lines = ["# context-pack: \(pack.role.rawValue)", ""]
    if !notes.isEmpty {
      lines.append("Notes:")
      lines.append(contentsOf: notes.map { "- \($0)" })
      lines.append("")
    }
    for slice in pack.slices {
      lines.append(
        slice.anchor.map { "## \(slice.sourceLabel) § \($0)" } ?? "## \(slice.sourceLabel)")
      lines.append("")
      // A slice already containing a fence (a design doc's own ```mermaid blocks) needs a longer
      // one wrapped around it, or the pack's own markdown would be corrupted.
      let fence = slice.lines.contains(where: { $0.contains("```") }) ? "````" : "```"
      lines.append(fence)
      lines.append(contentsOf: slice.lines)
      lines.append(fence)
      lines.append("")
    }
    lines.append(
      "Estimated tokens (UTF-8 bytes / 4 — an estimate, not a real tokenizer count): "
        + "\(pack.estimatedTokens.value)")
    return lines.joined(separator: "\n") + "\n"
  }

  private static func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private static func describe(_ error: ContextPackError) -> String {
    switch error {
    case .missingAnchor(let anchor, let source):
      return "missing anchor `\(anchor)` in `\(source)`"
    case .duplicateAnchor(let anchor, let source):
      return "anchor `\(anchor)` appears more than once in `\(source)`"
    case .unknownCoversID(let id):
      return "`\(id)` is not a requirement or test-plan id in the design"
    case .invalidCitationRange(let loc):
      return "citation `\(loc)` has neither a line range nor a quote"
    case .citationRangeOutOfBounds(let loc, let source):
      return "citation `\(loc)` falls outside `\(source)`"
    case .citationQuoteNotFound(let quote, let source):
      return "quote `\(quote)` not found in `\(source)`"
    case .roleMismatch(let expected, let actual):
      return "role mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
    }
  }

  // MARK: - Rendering the written outcome for the CLI

  private struct WrittenReport: Encodable {
    let command = "context-pack"
    let role: String
    let path: String
    let tokens: Int
    let notes: [String]
  }

  static func render(_ written: Written, format: OutputFormat) -> String {
    switch format {
    case .json:
      let report = WrittenReport(
        role: written.role.rawValue, path: written.relativePath, tokens: written.tokens,
        notes: written.notes)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
    case .human:
      var text = "context-pack: wrote \(written.relativePath) (~\(written.tokens) tokens, estimate)"
      for note in written.notes { text += "\n  note: \(note)" }
      return text
    }
  }
}

struct ContextPackCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "context-pack",
    abstract:
      "Slice verbatim, anchor-selected inputs for one agent role (spec §5.10). Never summarises.",
    discussion:
      "Gathers one role's inputs from disk (paths are repo-relative) and writes "
      + ".harness/context-pack/<role>[-<key>].md, printing the token estimate (UTF-8 bytes / 4). "
      + "Exit 0 once the pack is written. Exit 2 for a bad --role, a missing or unreadable "
      + "required input, or an unknown --module-kind. Exit 1 when the domain refuses to build "
      + "the pack (a missing anchor, an unknown `covers` id, a citation that doesn't check out) "
      + "— never a silently thin pack. --role selects which of: --brief/--pin (research lane), "
      + "--design/--claims/--claim-id (claim checker), --template/--frame-answers/--claims/"
      + "--probe-verdicts/--standards/--module-kind (drafter), --design/--doc-anchor/--claims/"
      + "--claim-id (evidence auditor), --design/--standards/--playbook/--standards-anchor "
      + "(standards reviewer), --design/--doc-anchor/--question-set (challenger), --design/"
      + "--module-graph/--task-sizing-bounds (decomposer), --design/--ledger/--task-id/--claims/"
      + "--module-kind/--standards (worker) apply.")

  @OptionGroup var packOptions: ContextPackOptions
  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let outcome = await ContextPackRun.run(
      role: packOptions.role, options: packOptions.gatherInputs, root: root,
      swiftPM: ScopeResolution.liveSwiftPM(root: root))
    switch outcome {
    case .written(let written):
      Console.write(ContextPackRun.render(written, format: output.format))
    case .invalid(let message):
      FileHandle.standardError.write(Data("swiftgate context-pack: \(message)\n".utf8))
      throw ExitCode(Verdict.blocked.exitCode)
    case .violation(let message):
      FileHandle.standardError.write(Data("swiftgate context-pack: \(message)\n".utf8))
      throw ExitCode(Verdict.red.exitCode)
    }
  }
}

/// What a research lane's `--pin` names, which decides the reuse-cache bucket it reads. The
/// codebase lane pins a commit, `packages` and `prior-decisions` pin `<pkg>@<version>`, and
/// `apple-docs` pins an SDK version.
enum ResearchLanePin: Equatable {
  case commit
  case package
  case sdk

  init(_ pin: String) {
    if pin.contains("@") {
      self = .package
    } else if [40, 64].contains(pin.count), pin.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
      self = .commit
    } else {
      self = .sdk
    }
  }
}
