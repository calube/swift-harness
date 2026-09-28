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

  @Option(
    help:
      "Distinguishes several packs of the same role: one file-name component, e.g. a worker's task id. A research lane's key is its lane name."
  )
  var key: String?

  // Research lane
  @Option(help: "A lane brief text. Repeatable.")
  var brief: [String] = []
  @Option(
    help:
      "The pin a research lane researches at: a commit sha (codebase), <package>@<version> (packages, prior-decisions) or iphonesimulator<version> / iphoneos<version> (apple-docs)."
  )
  var pin: String?
  @Option(help: "The design's area (research lane).")
  var area: String?
  @Option(help: "The evidence reuse cache's home directory; defaults to $HOME.")
  var cacheHome: String?

  // Design-anchored roles (research lane, claim checker, evidence auditor, standards reviewer,
  // challenger, decomposer, worker)
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
  @Option(
    help:
      "The design's tier (drafter). At sketch the pack also carries the user's quote-ok answer claims."
  )
  var tier: String?

  // Standards (drafter, standards reviewer, worker)
  @Option(help: "Path to docs/standards.md.")
  var standards: String?
  @Option(help: "Path to docs/testing-playbook.md, appended to --standards.")
  var playbook: String?
  @Option(
    help:
      "A module kind in scope, mapped to its standards anchors (drafter). Repeatable. A worker pack derives its kinds from the write set."
  )
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
  @Option(
    help:
      "A build run id (worker): includes a dependency-notes section with each dep's task-return notes, verbatim (spec §5.3)."
  )
  var buildRun: String?

  var gatherInputs: ContextPackGatherInputs {
    ContextPackGatherInputs(
      key: key, brief: brief, pin: pin, area: area, cacheHome: cacheHome, design: design,
      docAnchor: docAnchor, template: template,
      frameAnswers: frameAnswers, probeVerdicts: probeVerdicts, tier: tier, standards: standards,
      playbook: playbook, moduleKind: moduleKind, standardsAnchor: standardsAnchor, claims: claims,
      claimID: claimID, questionSet: questionSet, moduleGraph: moduleGraph,
      taskSizingBounds: taskSizingBounds, ledger: ledger, taskID: taskID, buildRun: buildRun)
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
  var tier: String?
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
  var buildRun: String?
  /// The harness plugin directory whose `docs/standards.md` a worker pack falls back to when the
  /// repository has none. Set from the environment by the command, never a flag.
  var harnessRoot: URL?
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
    /// The domain refused the inputs (exit 1), rather than an input being bad or unreadable.
    let isViolation: Bool
    init(_ message: String) {
      self.message = message
      self.isViolation = false
    }
    init(violation error: ContextPackError) {
      self.message = ContextPackRun.describe(error)
      self.isViolation = true
    }
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
    case .worker: gathered = await gatherWorker(options, root, swiftPM)
    }

    let (inputs, notes, roleKey): Gathered
    switch gathered {
    case .failure(let failure) where failure.isViolation:
      return .violation(message: failure.message)
    case .failure(let failure): return .invalid(message: failure.message)
    case .success(let value): (inputs, notes, roleKey) = value
    }

    var key: ContextPackKey?
    if let raw = roleKey ?? options.key {
      do {
        key = try ContextPackKey(parsing: raw)
      } catch {
        return .invalid(message: error.message)
      }
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
    guard let rawKey = o.key else {
      return .failure(
        GatherFailure("missing required option '--key <lane>' (the research lane's name)"))
    }
    guard let lane = ResearchLane(rawValue: rawKey) else {
      return .failure(
        GatherFailure(
          "unknown research lane --key `\(rawKey)`; expected one of "
            + ResearchLane.allCases.map(\.rawValue).joined(separator: ", ")))
    }
    guard let designPath = o.design else {
      return .failure(GatherFailure("missing required option '--design <path>'"))
    }
    guard let rawPin = o.pin else {
      return .failure(GatherFailure("missing required option '--pin <string>'"))
    }
    let pin: ResearchLanePin
    do {
      pin = try ResearchLanePin(parsing: rawPin)
    } catch {
      return .failure(GatherFailure(error.message))
    }
    let expectedKind = ResearchLanePin.Kind.expected(for: lane)
    guard pin.kind == expectedKind else {
      return .failure(
        GatherFailure(
          "--pin `\(rawPin)` is a \(pin.kind.rawValue) pin, but the \(lane.rawValue) lane "
            + "researches at a \(expectedKind.rawValue) pin"))
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

    let evidenceLayout = EvidenceLayout(designDocPath: designPath)
    let storedEvidence = storedEvidenceLocs(evidenceLayout, root: root)
    if storedEvidence.isEmpty {
      notes.append("no snapshots or captures stored under `\(evidenceLayout.root)`")
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
              cacheHits: hits, pin: pin, designDocPath: designPath,
              storedEvidence: storedEvidence)), notes, lane.rawValue
        ))
    }
  }

  /// The regular files directly under the evidence directory's `snapshots/` and `captures/`, as
  /// the locs a citation would use. A directory that doesn't exist yet lists nothing.
  private static func storedEvidenceLocs(_ layout: EvidenceLayout, root: URL) -> [String] {
    var locs: [String] = []
    for directory in [layout.snapshotsDirectory, layout.capturesDirectory] {
      let url = root.appending(path: directory, directoryHint: .isDirectory)
      let names =
        (try? FileManager.default.contentsOfDirectory(
          at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))
        ?? []
      let prefix = String(directory.dropFirst(layout.root.count + 1))
      locs.append(
        contentsOf: names.filter {
          (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        .map { "\(prefix)/\($0.lastPathComponent)" }.sorted())
    }
    return locs
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

    let graph: ModuleGraph
    switch await loadModuleGraph(root: root, swiftPM: swiftPM) {
    case .success(let loaded): graph = loaded
    case .failure(let failure): return .failure(failure)
    }

    do throws(DesignScopeValidationError) {
      _ = try DesignScope.deriveFacts(answers: answers, graph: graph)
    } catch {
      return .failure(GatherFailure("\(error)"))
    }
    return .success(answers.touchedModules)
  }

  /// A write set with no module entries (docs, fixtures) still gets a standards section, one that
  /// says why it holds no excerpt, so a reader never takes an empty section for a lost one.
  private static let noModuleKindsAnchor = "no-module-kinds"
  private static let noModuleKindsStandards = ContextSource(
    label: "standards",
    rawText:
      "## No module kinds\n\nNo module kinds in this task's write set; no standards excerpt.\n")

  private static func configLoadError(root: URL) -> ConfigLoadError? {
    do throws(ConfigLoadError) {
      _ = try ConfigLoader().load(repositoryRoot: root)
      return nil
    } catch {
      return error
    }
  }

  private static func loadModuleGraph(root: URL, swiftPM: any SwiftPM) async -> Result<
    ModuleGraph, GatherFailure
  > {
    let config: Config
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let loaded?): config = loaded
    case .success(nil):
      return .failure(
        GatherFailure("no \(ConfigLoader.fileName): context-pack needs the module graph"))
    case .failure(let failure):
      return .failure(GatherFailure(configFailureMessage(failure.outcome)))
    }
    do {
      return .success(
        try await ModuleGraphLoader(swiftPM: swiftPM, root: root).load(config: config))
    } catch {
      return .failure(GatherFailure("can't load the module graph: \(error)"))
    }
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
  private typealias CacheHits = (hits: [CachedClaim], notes: [String])

  private static func cacheHits(for pin: ResearchLanePin, options o: ContextPackGatherInputs)
    -> Result<CacheHits, GatherFailure>
  {
    guard let cacheHome = o.cacheHome ?? ProcessInfo.processInfo.environment["HOME"] else {
      return .failure(
        GatherFailure("missing required option '--cache-home <path>' ($HOME is not set)"))
    }
    let bucket: EvidenceCacheBucket
    switch pin {
    case .commit:
      return .success(
        (
          hits: [],
          notes: ["\(pin.rawValue) is a commit: the reuse cache holds no codebase claims"]
        ))
    case .package: bucket = .package(pin: pin.claimPin)
    case .sdk: bucket = .sdk(pin: pin.claimPin)
    }
    let store = EvidenceCacheStore(home: URL(filePath: cacheHome, directoryHint: .isDirectory))
    let contents: EvidenceCacheContents
    do {
      contents = try store.contents(of: bucket)
    } catch {
      return .failure(
        GatherFailure("can't read the evidence cache for `\(pin.rawValue)`: \(error)"))
    }
    var notes = contents.findings.map { "evidence cache: \($0.message)" }
    if contents.claims.isEmpty { notes.append("no cache hits for \(pin.claimPin)") }
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
    var tier: DesignTier?
    if let rawTier = o.tier {
      guard let known = DesignTier(rawValue: rawTier) else {
        return .failure(
          GatherFailure(
            "--tier `\(rawTier)` is not a design tier ("
              + DesignTier.allCases.map(\.rawValue).joined(separator: ", ") + ")"))
      }
      tier = known
    }
    let budgets: DocsBudgets
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let config): budgets = config?.docs.budgets ?? DocsBudgets()
    case .failure(let failure):
      return .failure(
        GatherFailure("can't read .swiftgate.toml for the word budgets: \(failure.outcome)"))
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
              probeVerdicts: probeVerdicts, standards: standards, moduleKindAnchors: anchors,
              tier: tier, wordBudgets: DrafterInputs.wordBudgetSource(budgets))),
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

  private static func gatherWorker(
    _ o: ContextPackGatherInputs, _ root: URL, _ swiftPM: any SwiftPM
  ) async -> Result<Gathered, GatherFailure> {
    guard let designPath = o.design else {
      return .failure(GatherFailure("missing required option '--design <path>'"))
    }
    guard let ledgerPath = o.ledger else {
      return .failure(GatherFailure("missing required option '--ledger <path>'"))
    }
    guard let taskID = o.taskID else {
      return .failure(GatherFailure("missing required option '--task-id <id>'"))
    }
    guard o.moduleKind.isEmpty else {
      return .failure(
        GatherFailure(
          "--module-kind doesn't apply to a worker pack: its kinds come from the task's write "
            + "set and the module graph"))
    }
    let designSource: ContextSource
    switch ContextPackFiles.read(label: designPath, path: designPath, root: root) {
    case .success(let s): designSource = s
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    }
    let design = DesignDocument(markdown: .parse(designSource.rawText))

    let ledgerData: Ledger
    switch ContextPackLedger.load(ledgerPath: ledgerPath, root: root) {
    case .success(let l): ledgerData = l
    case .failure(.unreadable(let p)): return .failure(GatherFailure("can't read `\(p)`"))
    case .failure(.malformed(let p)): return .failure(GatherFailure("`\(p)` is not a valid ledger"))
    }
    guard let task = ledgerData.tasks.first(where: { $0.id == taskID }) else {
      return .failure(GatherFailure("task `\(taskID)` not found in `\(ledgerPath)`"))
    }

    var notes: [String] = []
    let claims: ContextSource
    switch optionalClaims(o.claims, root: root, notes: &notes) {
    case .success(let s): claims = s
    case .failure(let message): return .failure(message)
    }

    var dependencyNotes: [DependencyReturnNotes] = []
    if let runID = o.buildRun {
      guard RunID.isValid(runID) else {
        return .failure(GatherFailure("--build-run `\(runID)` is not a valid run id"))
      }
      dependencyNotes = ContextPack.dependencyOrder(of: task.deps, in: ledgerData).map { dep in
        switch ContextPackTaskReturn.notes(
          forTask: dep, buildRun: runID, ledgerPath: ledgerPath, root: root)
        {
        case .success(let text): return DependencyReturnNotes(taskID: dep, notes: text)
        case .failure: return DependencyReturnNotes(taskID: dep, notes: nil)
        }
      }
    }

    if case .invalid(let validation)? = configLoadError(root: root),
      validation.issues.contains(where: {
        if case .unknownModuleKind = $0 { return true } else { return false }
      })
    {
      return .failure(GatherFailure(violation: .unknownModuleKind(writeSetEntry: nil)))
    }
    let graph: ModuleGraph
    switch await loadModuleGraph(root: root, swiftPM: swiftPM) {
    case .success(let loaded): graph = loaded
    case .failure(let failure): return .failure(failure)
    }
    let kinds: [ModuleKind]
    do throws(ContextPackError) {
      kinds = try WorkerModuleKinds.kinds(writeSet: task.writeSet, graph: graph)
    } catch {
      return .failure(GatherFailure(violation: error))
    }

    let standards: ContextSource
    if kinds.isEmpty {
      standards = noModuleKindsStandards
    } else if let standardsPath = o.standards {
      switch readStandardsAndPlaybook(
        standardsPath: standardsPath, playbookPath: o.playbook, root: root)
      {
      case .success(let s): standards = s
      case .failure(let message): return .failure(message)
      }
    } else {
      switch WorkerPackSources.gather(
        designPath: designPath, root: root, harnessRoot: o.harnessRoot
      )
      .standards
      {
      case .success(let s?): standards = s
      case .success(nil):
        return .failure(GatherFailure("no standards doc for worker packs"))
      case .failure(let failure): return .failure(GatherFailure(failure.message))
      }
    }

    return .success(
      (
        .worker(
          WorkerInputs(
            task: task, design: design, designSource: designSource, claims: claims,
            citedClaimIDs: o.claimID, standards: standards,
            moduleKindAnchors: kinds.isEmpty
              ? [noModuleKindsAnchor] : ContextPackModuleKindAnchors.anchors(for: kinds),
            dependencyNotes: dependencyNotes)),
        notes, o.key ?? taskID
      ))
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

  private static func outputPath(role: ContextPackRole, key: ContextPackKey?) -> String {
    let suffix = key.map { "-\($0.value)" } ?? ""
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

  static func describe(_ error: ContextPackError) -> String {
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
    case .missingDependencyReturn(let task):
      return "no task return for dependency `\(task)`: run `swiftgate build check-return` first"
    case .unknownModuleKind(let entry?):
      return "context-pack.module-kind-unknown: write-set entry `\(entry)` is in a module with "
        + "no known kind, so its standards can't be packed"
    case .unknownModuleKind(nil):
      return "context-pack.module-kind-unknown: \(ConfigLoader.fileName) names a module kind "
        + "outside \(ModuleKind.allCases.map(\.rawValue).joined(separator: ", ")), so the "
        + "task's standards can't be packed"
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
      + "Every role honours --key, which must be one file-name component. "
      + "Exit 0 once the pack is written. Exit 2 for a bad --role, a missing or unreadable "
      + "required input, an unsafe --key, an unknown --module-kind, a research-lane --key that "
      + "isn't a lane name, or a --pin that isn't that lane's kind. Exit 1 when the domain "
      + "refuses to build the pack (a missing anchor, an unknown `covers` id, a citation that "
      + "doesn't check out) — never a silently thin pack. --role selects which of: "
      + "--key/--design/--frame-answers/--area/--module-graph/--brief/--pin/--claims "
      + "(research lane), "
      + "--design/--claims/--claim-id (claim checker), --template/--frame-answers/--claims/"
      + "--probe-verdicts/--standards/--module-kind (drafter), --design/--doc-anchor/--claims/"
      + "--claim-id (evidence auditor), --design/--standards/--playbook/--standards-anchor "
      + "(standards reviewer), --design/--doc-anchor/--question-set (challenger), --design/"
      + "--module-graph/--task-sizing-bounds (decomposer), --design/--ledger/--task-id/--claims/"
      + "--standards/--playbook/--build-run (worker) apply. A worker pack's standards are the "
      + "anchors for the module kinds its task's write set touches in the module graph; "
      + "--standards defaults to docs/standards.md, else the harness plugin's.")

  @OptionGroup var packOptions: ContextPackOptions
  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    var options = packOptions.gatherInputs
    options.harnessRoot = ProcessInfo.processInfo.environment[SelfTestCommand.harnessRootVariable]
      .map { URL(filePath: $0, directoryHint: .isDirectory) }
    let outcome = await ContextPackRun.run(
      role: packOptions.role, options: options, root: root,
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
