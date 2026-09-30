# Comment labelling sheet

When every answer is in, turn the sheet into `labels.json` from the repository root with:

```sh
node tests/judge_labelling_sheet.mjs apply comments
```

You are labelling blind: each case shows only a comment a commit added to this repository's
Swift, and the 6 lines of code after it, exactly as the commit hook's judge sees them. Case
numbers and keys say nothing about the answer, and the order is arbitrary.

How to fill it in:

- The subject of every case is a comment added to Swift source, with the code around it.
- For each case, write `yes` or `no` after each `Answer <question>:` line.
- Leave an answer empty to skip that question for that case. A case with every answer
  empty is skipped entirely.
- Answer from the text shown only. The `Source:` line names the commit and file each comment
  came from so the set can be checked against history; you don't need to open them.
- Don't open the case directories, and don't edit anything outside the answer lines: the
  `key` on each case heading is how the answers find their case, and the `Source:` line must
  stay as it is.

The command records every answered case with `labeller: "person"` and refuses the whole sheet
if any answer isn't `yes` or `no`.

## Case 1 · key 022d8d5d

Comment:

```swift
// A macro expansion (for example `#expect(try …)` in a non-throwing test) is a compile error
```

The code after it:

```swift
    // in the repository's own code, never an environment problem, even when the compiler's note
    // can't name a real file: it must never read as no-evidence, which would let the Stop hook
    // release on a test that doesn't compile.
    let macroLocated = log.macroExpansionErrors.map { error -> (String, Int?, String) in
      let path = error.file.flatMap(relative).flatMap { $0.contains(".build/") ? nil : $0 }
      return (path ?? evidence.packagePath, path != nil ? error.line : nil, error.message)
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: c7614a38d5bc8a2d8a580e592a1395d3734e2402 plugin/gate/Sources/SwiftGateDomain/Testing/HostTestEvidence.swift

## Case 2 · key 031d11f2

Comment:

```swift
// pin (a revision missing from the remote) resolves silently to something else and rewrites
```

The code after it:

```swift
    // `Package.resolved`, which a hook denies an agent to do by hand.
    var arguments = ["test", "--only-use-versions-from-resolved-file"]
    arguments.append(request.parallel ? "--parallel" : "--no-parallel")
    if request.codeCoverage { arguments.append("--enable-code-coverage") }
    arguments += ["--xunit-output", request.xunitOutputPath]
    for filter in request.filters { arguments += ["--filter", filter] }
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 4043060f305569ef4768a4959b2233357a902192 plugin/gate/Sources/SwiftGateAdapters/SwiftPM.swift

## Case 3 · key 04980157

Comment:

```swift
/// harness ships and its own commands read — a stamped template, a self-test seed — so it
```

The code after it:

```swift
  /// reverts alongside the Swift sources instead of silently keeping the change under test.
  static func partition(_ changed: [String], prefix: String, graph: ModuleGraph)
    -> (reverted: [String], copied: [String])
  {
    var reverted: [String] = []
    var copied: [String] = []
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 5a875de59295e0c67919e36dca0e1d1fafa4422d plugin/gate/Sources/SwiftGateCLI/ChangedTestChecks.swift

## Case 4 · key 10351905

Comment:

```swift
/// state, and setting the index through `index set`'s own path.
```

The code after it:

```swift
enum BuildLoop {
  /// `nil` when `session` holds `slug`'s lock; otherwise the refusal to return.
  static func authorize<Report>(
    _ command: String, slug: String, session: String?, git: any Git
  ) async -> BuildLoopResult<Report>? {
    guard let refusal = await IndexSetAuthority.check(slug: slug, session: session, git: git)
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 95cf420e9c4dbc70e12e398fbf5abe54bef8bfd9 plugin/gate/Sources/SwiftGateCLI/Commands/BuildStartCommand.swift

## Case 5 · key 12bef096

Comment:

```swift
/// same adapters `arch` uses (`ConfigLoader`, `ModuleGraphLoader`) — no second loader — so the
```

The code after it:

```swift
/// counts `DesignScope.deriveFacts` computes are checked against the repository's real modules,
/// never hand-counted by whatever wrote the frame-answers file.
enum DesignScopeRun {
  enum Outcome: Sendable, Equatable {
    case recommended(DesignScopeReport)
    case failed(message: String)
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateCLI/Commands/DesignScopeCommand.swift

## Case 6 · key 1d7f8bcd

Comment:

```swift
/// Answered from the local cache, so no backend call was made.
```

The code after it:

```swift
  public let cached: Bool

  public init(
    inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil,
    wallMilliseconds: Int, backendMilliseconds: Int? = nil, servedModel: String? = nil,
    cached: Bool = false
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: d5a98cc6157801682875549cccbe35f5cff46a18 plugin/gate/Sources/SwiftGateDomain/Judge/JudgeUsage.swift

## Case 7 · key 221a48f7

Comment:

```swift
/// | Relative links | every relative link — any extension, or none — resolves against the repo's tracked files |
```

The code after it:

```swift
/// | Router reachability | every `docs/` doc is reachable from `docs/index.md` |
///
/// Unlike ``DesignLintSections`` and its siblings, this rule reads the *whole* docs corpus at
/// once — reference integrity and reachability are cross-file by nature — so the input is every
/// file's path and raw text (§5.10's "no IO in the domain": the FS read lives in the CLI's
/// `DocsTreeReader` adapter, not here). Two decisions worth stating for later readers:
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Docs/DocsLintReferences.swift

## Case 8 · key 2a402004

Comment:

```swift
/// Only failures a later attempt can plausibly fix: transport errors, throttling, and 5xx.
```

The code after it:

```swift
  func isRetryable(_ error: any Error) -> Bool {
    switch error {
    case HTTPError.unacceptableStatus(let status): status == 429 || (500..<600).contains(status)
    case is URLError: true
    default: false
    }
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 5ff680b845737e68702e85d338744901fb005434 examples/SampleApp/Packages/APIClient/Sources/APIClientLive/APIClientLive.swift

## Case 9 · key 2a5570a7

Comment:

```swift
/// The final gate's proof bases: `prove` retries a test that only fails to compile at the merge
```

The code after it:

```swift
/// base at the surface commit of the task that added the API it calls.
enum BuildProofBasesRun {
  static func run(slug: String, git: any Git) async -> BuildLoopResult<BuildProofBasesReport> {
    let command = "build proof-bases"
    let plan: PlanStateLayout.Plan
    do {
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 24fc934a2c7f166eb8f3c0509d4e2c4b0faa403a plugin/gate/Sources/SwiftGateCLI/Commands/BuildProofBasesCommand.swift

## Case 10 · key 2b25c541

Comment:

```swift
/// `ModuleCache.noindex`. Both record the absolute path they were built at.
```

The code after it:

```swift
  static let moduleCacheNames = ["ModuleCache", "ModuleCache.noindex"]

  private let runner: any ProcessRunner
  private let repositoryRoot: String
  private let timeout: Duration
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: e4b3b54729458add44489a909cbb0330cfdb6daf plugin/gate/Sources/SwiftGateAdapters/Build/LiveGitWorkspace.swift

## Case 11 · key 2d704246

Comment:

```swift
/// The same argv first parses in process to the `record` leaf, so a command the binary
```

The code after it:

```swift
    /// doesn't have fails here by name rather than as an opaque exit code.
    func record(_ design: String, extra: [String] = []) async throws -> ProcessOutput {
      let arguments =
        ["evidence", "cache", "record", "--design", design, "--cache-home", cacheHome, "--json"]
        + extra
      do {
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: a3121d2f3065675ca10c6729bee6b390b8e2daa0 plugin/gate/Tests/SwiftGateCLITests/EvidenceCacheRecordCommandTests.swift

## Case 12 · key 2dce1754

Comment:

```swift
/// `Fixtures` library.
```

The code after it:

```swift
  private static func graphWithTestTargets() throws -> ModuleGraph {
    try ModuleGraph(packages: [
      PackageManifest(
        name: "Pkg", path: "",
        targets: [
          PackageTarget(name: "Foo", type: .library, path: "Sources/Foo"),
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 894d0851160be2098e3412db2694e778f53bf034 plugin/gate/Tests/SwiftGateDomainTests/PlanLintGraphTests.swift

## Case 13 · key 31eb34b2

Comment:

```swift
/// codenames of the same length (`SH1`, `KO01`).
```

The code after it:

```swift
  private static let technicalTokenExceptions: Set<String> = [
    "UTF8", "SHA1", "MD5", "ARM64",
  ]

  static func isWholeWordMatch(_ range: Range<String.Index>, in text: String) -> Bool {
    let before =
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateRules/Comments/CommentRules.swift

## Case 14 · key 35059536

Comment:

```swift
/// dependency edges and write sets — never array order — affect the result.
```

The code after it:

```swift
  ///
  /// - Every dependency must name another task in `tasks`, checked before any layering happens,
  ///   so a cycle and a missing dependency are never conflated.
  /// - A task's layer is one past the deepest layer of its deps (no deps → layer 0). Layering
  ///   stalls exactly when what's left forms a cycle.
  /// - Within a layer, tasks are placed id-ascending into the first wave (started in this layer)
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Plan/PlanSchedule.swift

## Case 15 · key 356323a7

Comment:

```swift
/// Scripted fake transport: returns the queued responses in order and records every request.
```

The code after it:

```swift
final class ScriptedTransport: Sendable {
  enum Reply: Sendable {
    case status(Int, Data = Data())
    case transportError(URLError.Code)
  }
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 5ff680b845737e68702e85d338744901fb005434 examples/SampleApp/Packages/APIClient/Tests/APIClientLiveTests/APIClientLiveTests.swift

## Case 16 · key 358e40e9

Comment:

```swift
// when it's one of the harness's own stamped resources — a template a test can guard — so it
```

The code after it:

```swift
    // reverts alongside the Swift sources instead of silently keeping the change under test.
    var reverted: [String] = []
    var copied: [String] = []
    for path in changed {
      guard path.hasPrefix(prefix) else { continue }
      let relative = String(path.dropFirst(prefix.count))
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 3e34108a391406be0e87310ee54eab9e99bf7bfb plugin/gate/Sources/SwiftGateCLI/ChangedTestChecks.swift

## Case 17 · key 3a950b29

Comment:

```swift
/// one dependent task in the whole ledger — namely `t(i+1)`, so the run never branches — and
```

The code after it:

```swift
  /// every task in the run touches the same single module. One `minor` warning per maximal run,
  /// located at its first task: this many tasks strung end to end through one module is either one
  /// task cut apart for no reason, or a chain that never needed to be one.
  public static func singleDependentChainFindings(
    ledger: Ledger, graph: ModuleGraph, ledgerPath: String
  )
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Plan/PlanLintGraph.swift

## Case 18 · key 3c7ba090

Comment:

```swift
// 2 negatives, both flagged at 0.1: nothing predicted positive and nothing labelled positive.
```

The code after it:

```swift
    let result = JudgeBenchmarkMetrics.question(
      Self.failsIfBroken,
      cases: JudgeReportCases([
        Self.item("case-0", positive: false), Self.item("case-1", positive: false),
      ]),
      run: Self.run([["case-0": 0.1, "case-1": 0.1]]), threshold: 0.5)
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 7c56d4250738931a4b264ebc9f8719478f350638 plugin/gate/Tests/SwiftGateDomainTests/JudgeBenchmarkMetricsTests.swift

## Case 19 · key 458ceece

Comment:

```swift
/// `~/.swift-harness/projects.json`: the bootstrapped repositories on this machine, as absolute
```

The code after it:

```swift
/// paths. Pointers only; each repository's `.harness/plans/index.json` stays canonical (spec §4.2).
public struct ProjectRegistry: Sendable, Equatable {
  public static let schema = 1
  /// Relative to the home directory.
  public static let path = ".swift-harness/projects.json"
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Bootstrap/ProjectRegistry.swift

## Case 20 · key 46a8cb4b

Comment:

```swift
/// ``PlanStateLayout``): the plan's identity and approval chain. The
```

The code after it:

```swift
/// ledger alongside it (``Ledger``) holds tasks and waves, so a plan can ride out an amendment's
/// `clarifyChain` without touching task state or the wave schedule.
public struct PlanFile: Sendable, Equatable, Codable {
  /// The reviewer's decision on the design page (spec §8.2, `design-render`'s approval bar).
  /// Closed so an unrecognized value fails decoding instead of a gate reading it as approved.
  public enum ApprovalDecision: String, Sendable, Equatable, Codable, CaseIterable {
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Plan/PlanFile.swift

## Case 21 · key 53edcbf9

Comment:

```swift
/// Each privacy class is interpolated as its own OSLog argument so the unified logging system
```

The code after it:

```swift
  /// redacts private and sensitive values exactly as a direct `Logger` call would.
  public static func osLog(subsystem: String, minimumLevel: LogLevel = .debug) -> Self {
    let minimum = OSLogRendering.severity(of: minimumLevel)
    return Self(
      isEnabled: { level, _ in OSLogRendering.severity(of: level) >= minimum },
      emit: { record in
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 5ff680b845737e68702e85d338744901fb005434 examples/SampleApp/Packages/LogClient/Sources/LogClientLive/LogClientLive.swift

## Case 22 · key 59bc2b11

Comment:

```swift
// Each state's visible text (not colour alone) names its own state and no other's.
```

The code after it:

```swift
    #expect(blockedLI.contains(LedgerRender.statusLabel(.blocked)))
    #expect(!blockedLI.contains(LedgerRender.statusLabel(.abandoned)))
    #expect(abandonedLI.contains(LedgerRender.statusLabel(.abandoned)))
    #expect(!abandonedLI.contains(LedgerRender.statusLabel(.blocked)))
    #expect(pendingLI.contains(LedgerRender.statusLabel(.pending)))
    #expect(!pendingLI.contains(LedgerRender.statusLabel(.blocked)))
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 10ba1481689bde549241085673295994667b4afd plugin/gate/Tests/SwiftGateDomainTests/LedgerBuildStatesTests.swift

## Case 23 · key 5b8f22a1

Comment:

```swift
/// Each family calls the same run-layer code its own command uses — never a re-implementation —
```

The code after it:

```swift
/// and turns the result into the rule-id-shaped identifiers `expected.json` names.
private enum SeedRunners {
  // MARK: evidence check

  static func evidenceCheck(caseDirectory: URL) async -> SeedRunOutcome {
    let design = "docs/example/designs/seed.md"
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateCLI/Commands/SelfTestCommand.swift

## Case 24 · key 5d4ac45f

Comment:

```swift
/// infinite-loop mutant. A process-wide snapshot from `ps` (not `proc_listchildpids`, which this
```

The code after it:

```swift
/// process cannot always resolve for pids outside its own tree) finds it regardless of which
/// group it put itself in.
private enum ProcessTree {
  /// `root` and every process descended from it, root first, from one `ps` snapshot.
  static func descendants(of root: pid_t) -> [pid_t] {
    var childrenByParent: [pid_t: [pid_t]] = [:]
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 9cc97fde8a871b1779762e11db17d64a264e9313 plugin/gate/Sources/SwiftGateAdapters/LiveProcessRunner.swift

## Case 25 · key 5f988ade

Comment:

```swift
/// before building; the proof base, where the surface's stubs exist, can still load it.
```

The code after it:

```swift
  public static func retryable(_ tests: [ChangedTest], in judgement: ChangedTestJudgement)
    -> [ChangedTest]
  {
    let noEvidence = judgement.findings.filter { $0.ruleID == noEvidenceRuleID }
    if noEvidence.contains(where: { finding in !tests.contains { isAbout($0, finding) } }) {
      return tests
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 0a34dc550951dfb1568202d9d2baf823cc239257 plugin/gate/Sources/SwiftGateDomain/Testing/ChangedTestRules.swift

## Case 26 · key 611b45c4

Comment:

```swift
/// with no incoming path from the root — including a pair that only link to each other — is
```

The code after it:

```swift
  /// never added to `visited` and is flagged.
  private static func reachabilityFindings(
    resolutions: [LinkOccurrence], pathSet: Set<String>
  ) throws(ReportContractViolation) -> [Finding] {
    guard pathSet.contains(routerRoot) else { return [] }
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Docs/DocsLintReferences.swift

## Case 27 · key 634646b6

Comment:

```swift
/// Spec §5.3's separator is `" — tier "` specifically, not the bare word "tier" — a behaviour
```

The code after it:

```swift
  /// description is free prose and may contain "tier" itself (e.g. "no tier annotation").
  private static let tierSeparator = " — tier "

  private static func parseTestPlanBullet(_ bullet: MarkdownDocument.Bullet) -> TestPlanBullet? {
    guard let id = bullet.id else { return nil }
    guard let tierRange = bullet.remainder.range(of: tierSeparator) else {
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Design/DesignDocument.swift

## Case 28 · key 68239770

Comment:

```swift
/// - Parameter proofBases: ancestors of HEAD, oldest first, where a test that fails to compile
```

The code after it:

```swift
  ///   or to load its package at an earlier base is tried again.
  static func prove(
    _ environment: Environment, graph: ModuleGraph, base: String, proofBases: [String] = [],
    context: GateRun.Context
  ) async -> ChangedTestJudgement {
    let (result, milliseconds) = await GateRun.timed {
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 0a34dc550951dfb1568202d9d2baf823cc239257 plugin/gate/Sources/SwiftGateCLI/ChangedTestChecks.swift

## Case 29 · key 6dc7be65

Comment:

```swift
// still carry one clean absolute path.
```

The code after it:

```swift
    let root = Fixture.checkoutRoot.appending(path: "bin/..").path
    let context = try await sessionContext(environment: ["CLAUDE_PLUGIN_ROOT": root])

    let line = try #require(
      context.split(separator: "\n").first { $0.hasPrefix(Self.referenceDocsPrefix) },
      "no reference docs line in: \(context)")
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 2dd72e7d9da84a488e33adc763ec475f0bce531b plugin/gate/Tests/SwiftGateCLITests/ConsumerSteeringTests.swift

## Case 30 · key 6ec9ddf3

Comment:

```swift
/// construct is judged without plan state.
```

The code after it:

```swift
private struct ResolvedWrite {
  static let recordedCommand = "\"swiftgate check --tier fast 2>&1 | tail -25\""
  static let resolved = "Packages/Feed/Package.resolved"

  let harness: HookHarness
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: d3fda86d2f88e27539f9fb6835fab5d586acfcaf plugin/gate/Tests/SwiftGateCLITests/BashWriteTargetTests.swift

## Case 31 · key 7b0d9e21

Comment:

```swift
/// everything else — brackets, quotes, angle brackets, the arrow's `>`, parens — becomes its
```

The code after it:

```swift
/// decimal character reference (Mermaid's own escape convention for label text, e.g. `#93;` for
/// `]`), so a task id can never reopen Mermaid's own grammar (closing a node early, forging an
/// edge) or, once Mermaid's `htmlLabels` renders the label, reach the page as live markup.
enum MermaidLabel {
  static func escape(_ text: String) -> String {
    var result = ""
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Design/LedgerRender.swift

## Case 32 · key 7d16cdf7

Comment:

```swift
/// an advisory note (spec §6.2: a repo with none still gets the generic families and defaults).
```

The code after it:

```swift
  /// A missing or unreadable config file counts as "no section": ``StaticCheckInputs/loadConfig``
  /// already turns a malformed one into its own blocking or red outcome before this ever runs.
  private static func hasDocsSection(root: URL) -> Bool {
    let url = root.appending(path: Config.fileName, directoryHint: .notDirectory)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateCLI/Commands/DocsLintCommand.swift

## Case 33 · key 7d3f579f

Comment:

```swift
// Each repo's claim has its own id and line range; only the text and quote are shared.
```

The code after it:

```swift
    let fromFirst = try Claims.reusable(
      Claims.packageClaim("ev-first-repo-effect-cancels", text: text, quote: quote))
    let fromSecond = try Claims.reusable(
      Claims.packageClaim(
        "ev-second-repo-effect-cancels", text: text, quote: quote, lines: "L90-L99"))
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Tests/SwiftGateAdaptersTests/EvidenceCacheStoreTests.swift

## Case 34 · key 7e1d42ab

Comment:

```swift
// Spec §9: at `sketch`, no research lane or claim checker ran, so a Decision bullet may stay
```

The code after it:

```swift
    // `[UNVERIFIED]`, and neither Decision nor Perf & scale mirrors its `[UNVERIFIED]` bullets in
    // Risks. A Decision may also cite the user's own frame answer once `evidence check` found its
    // quote: the answer is the user's choice, and nothing else at sketch could judge it. Every
    // other citation must still be `supported`.
    let sketchRelaxesDecision = tier == .sketch
    let sketchUnmirrored: Set<String> = sketchRelaxesDecision ? ["Decision", "Perf & scale"] : []
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: a46a70620d204f97a78fcca41ef66d8682dff644 plugin/gate/Sources/SwiftGateDomain/Design/DesignLintEvidence.swift

## Case 35 · key 7e7388ee

Comment:

```swift
/// Runs git in the sandbox repository and returns stdout; a nonzero exit is `blocked`.
```

The code after it:

```swift
  @discardableResult
  private func git(_ arguments: [String]) async throws(CalibrationCaseError) -> String {
    let output = try await run(arguments)
    guard output.status.isSuccess else {
      throw .blocked(
        "git \(arguments.joined(separator: " ")) exited \(output.status): "
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 1dea708c9f49023bc2811b45949a6d47a2f67216 plugin/gate/Sources/SwiftGateAdapters/Calibration/BuildCalibrationRunner.swift

## Case 36 · key 81675481

Comment:

```swift
// citation rule — including a Decision citing a claim that isn't `supported` — is unchanged.
```

The code after it:

```swift
    let sketchRelaxesDecision = tier == .sketch
    let taggedSections:
      [(
        name: String, section: MarkdownDocument.Section?, requireSupported: Bool,
        forbidUnverified: Bool
      )] = [
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 147f8832757cb16e29daf48b364dcb35d8c7f566 plugin/gate/Sources/SwiftGateDomain/Design/DesignLintEvidence.swift

## Case 37 · key 8446c57d

Comment:

```swift
// Half deleted and holding a directory it may not empty, so neither git nor a plain delete
```

The code after it:

```swift
    // can remove it.
    let stuck = base.appending(path: ".app-swiftgate-prove-\(dead)-9c0d")
    _ = try await Self.git("worktree", "add", "--detach", "--quiet", stuck.path, in: root)
    try FileManager.default.removeItem(at: stuck.appending(path: ".git"))
    let locked = stuck.appending(path: "locked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: ae72a0b9aabdd1d8a08961c4fe64e8fefb519b59 plugin/gate/Tests/SwiftGateCLITests/ScratchWorktreeSweepTests.swift

## Case 38 · key 89d8af91

Comment:

```swift
/// path's own candidate sibling is checked, never a directory listing, so the hook stays fast
```

The code after it:

```swift
/// however full the parent directory is.
enum RepositoryCheckouts {
  static func of(root: URL, git: any Git, around paths: [String]) async
    -> SubagentScopeGuard.Checkouts
  {
    let common = (try? await git.commonDirectory()).map { URL(filePath: $0) }
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 627007b23b7ad4eebd0642f5088f0c7347a6a98a plugin/gate/Sources/SwiftGateCLI/Hooks/PreToolUseHook.swift

## Case 39 · key 9279e9c1

Comment:

```swift
/// tests may need the vendor types it wraps.
```

The code after it:

```swift
  static let outsideLive = RuleScope { unit in
    guard let role = unit.scope?.role, !unit.isTestFile else { return false }
    return role != .clientLive
  }

  /// Every classified production module except the log and tracing Live modules, which are the
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateRules/Lint/LintSupport.swift

## Case 40 · key 928601a8

Comment:

```swift
/// `PlanConfig.maxModulesPerTask`'s doc comment names it too). Any other 2-module set, or any
```

The code after it:

```swift
  /// set of more than 2, is never a pair.
  static func isInterfaceLivePair(_ modules: Set<String>) -> Bool {
    guard modules.count == 2 else { return false }
    let sorted = modules.sorted()
    return sorted[0] + "Live" == sorted[1]
  }
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Plan/PlanLintCoverage.swift

## Case 41 · key 98d46a97

Comment:

```swift
/// cell chosen by the state's seeded generator.
```

The code after it:

```swift
public enum GameEngine {
  public static func step(_ state: GameState, _ input: GameInput) -> GameState {
    var next = state
    switch input {
    case .reset:
      next.board = Array(repeating: nil, count: GameState.cellCount)
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 5ff680b845737e68702e85d338744901fb005434 examples/SampleApp/Packages/GameEngine/Sources/GameEngine/GameEngine.swift

## Case 42 · key 99478cf6

Comment:

```swift
/// counts as 1.
```

The code after it:

```swift
  public static let modulesTouchedDeepThreshold = 4

  /// Turns frame answers into graph facts, checked against `graph`. Deterministic: duplicate
  /// names are checked first (`touchedModules` then `newModules`, first offender reported), then
  /// every touched module must already be in the graph, then no new module may already be in the
  /// graph.
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 8dcc16acc4184157b296cd7649de2d3dcbf7522a plugin/gate/Sources/SwiftGateDomain/Design/DesignScope.swift

## Case 43 · key 996d9fdb

Comment:

```swift
/// reaches the members after `root` itself is reaped; a descendant in a group of its own is
```

The code after it:

```swift
  /// reparented once `root` dies and can no longer be found by walking parents, so a later signal
  /// passes the groups an earlier one returned. A group already gone is not an error: `kill` on
  /// an empty group is a no-op.
  @discardableResult
  static func terminate(root: pid_t, signal: Int32, alongside groups: Set<pid_t> = [])
    -> Set<pid_t>
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 238b672efadb7ac977b9ab5b42a3be95ffbd2777 plugin/gate/Sources/SwiftGateAdapters/LiveProcessRunner.swift

## Case 44 · key 9f673aee

Comment:

```swift
// untouched state rather than one warmed by an earlier repeat.
```

The code after it:

```swift
    let samples = try await Latency.samples {
      let elsewhere = FileManager.default.temporaryDirectory
        .appending(path: "swiftgate-noconfig-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: elsewhere.appending(path: ".git"), withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: elsewhere) }
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Tests/SwiftGateCLITests/HookCommandTests.swift

## Case 45 · key a057d3c2

Comment:

```swift
/// ``IdPolicy``). `comments` and `testlint` flag any of these ids — or a codename-shaped token —
```

The code after it:

```swift
/// found in a comment or test name.
///
/// This type only merges already-read ids into one set; reading them off disk (every common-dir
/// ledger, `claims.jsonl`, and design docs) is the adapter layer's job, wired in by whichever
/// caller assembles the check's `RuleContext`.
public enum KnownIds {
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Docs/KnownIds.swift

## Case 46 · key a15300f1

Comment:

```swift
// Every worker gets the Decision section, covered or not.
```

The code after it:

```swift
    #expect(text.contains("Client-side queue [ev-tca-effect-run-supports-cancellation]"))
  }

  // MARK: - Research lane: all 5 spec §5.10 parts, plus the evidence reuse cache

  /// A `--cache-home` unique to the calling test, so cache reads/writes never touch a real
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: c326b53bc6303ff166e8231be50ae8a2ddb5375b plugin/gate/Tests/SwiftGateCLITests/ContextPackCommandTests.swift

## Case 47 · key a2fecf23

Comment:

```swift
/// `message` is a `StaticString` so user data can only enter through privacy-tagged attributes.
```

The code after it:

```swift
  public func log(
    _ level: LogLevel,
    _ message: StaticString,
    category: String,
    _ attributes: @autoclosure () -> [LogAttribute] = []
  ) {
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 5ff680b845737e68702e85d338744901fb005434 examples/SampleApp/Packages/LogClient/Sources/LogClient/LogClient.swift

## Case 48 · key a79a393e

Comment:

```swift
// burning real CPU first — standing in for a hook whose own logic, or a child process it
```

The code after it:

```swift
    // spawns, got slower.
    let slowGit = LiveGit(
      runner: FakeProcessRunner { _ in
        Self.burnCPU(for: .milliseconds(120))
        return ProcessOutput(status: .exited(0), stdout: ".git\n")
      },
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: c2f496188b9669671cdc0f3895c52faccd8fca29 plugin/gate/Tests/SwiftGateCLITests/HookLatencyCPUBudgetTests.swift

## Case 49 · key a7ed1f09

Comment:

```swift
// If argv had ever reached a shell, this file would exist.
```

The code after it:

```swift
      #expect(!FileManager.default.fileExists(atPath: marker))

      let capturePath = try #require(report.capturePath)
      let onDisk = try Data(contentsOf: root.appending(path: capturePath))
      #expect(String(decoding: onDisk, as: UTF8.self).contains(payload))
    }
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Tests/SwiftGateCLITests/EvidenceCaptureCommandTests.swift

## Case 50 · key aae04810

Comment:

```swift
// Restored only in the working tree: a ref check must not see it.
```

The code after it:

```swift
    try repo.write(EvidenceRepo.source, EvidenceRepo.original)

    let atHead = await repo.check(at: "HEAD")
    #expect(
      try jsonLines(atHead) == [
        StrictLine(id: "ev-queue-enqueue-is-async", status: .stale, loc: nil)
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Tests/SwiftGateCLITests/EvidenceCheckCommandTests.swift

## Case 51 · key aae4cc8f

Comment:

```swift
// iOS-only: sources are compiled out on macOS so `swift test` on the host stays Core-only.
```

The code after it:

```swift
    .target(
      name: "CounterUI",
      dependencies: [
        "CounterCore",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 5ff680b845737e68702e85d338744901fb005434 examples/SampleApp/Packages/CounterFeature/Package.swift

## Case 52 · key ab39fb4f

Comment:

```swift
// A directory that can't be written to can't have its entries unlinked.
```

The code after it:

```swift
    let crashing = SprintStore(
      layout: scenario.layout, lock: SprintScenario.lock(scenario.layout), timeout: .seconds(30),
      beforeRename: { _ in
        try FileSystemConditions.setMode(0o555, root)
        throw SimulatedCrash()
      })
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 25aea64d930c0c7cd3e01639db7362a9a3382d73 plugin/gate/Tests/SwiftGateAdaptersTests/SprintStoreTests.swift

## Case 53 · key ad1fc97d

Comment:

```swift
// An option flag never reads the declared tier.
```

The code after it:

```swift
    return JudgeBlockCalibration.flagFires(
      question, expected: expected, declaredTier: declaredTier ?? "")
  }

  static func tally(_ question: String, _ scored: [ScoredCase], unscored: Int, threshold: Double)
    -> JudgeQuestionMetrics
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 7c56d4250738931a4b264ebc9f8719478f350638 plugin/gate/Sources/SwiftGateDomain/Judge/Benchmark/JudgeBenchmarkMetrics.swift

## Case 54 · key ad28fbb7

Comment:

```swift
// letter (`SH1`, `KO01`, `PR2a`). A single leading letter is deliberately excluded — this
```

The code after it:

```swift
      // harness's own tests prove that shape collides with ordinary abbreviations (test tiers
      // `T0`-`T3`, a `-R1` revision suffix, a standards code like `D7`), so it would flag its own
      // corpus. Bounded at 3 letters and 2 digits so the match never starts inside a longer
      // all-caps acronym (`HTTP2` has 4 leading letters) or spans a 3-digit version number
      // (`H264`) — in both cases the excess character breaks the closing `\b`, so no match is
      // found there at all.
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateRules/Comments/CommentRules.swift

## Case 55 · key aed630ff

Comment:

```swift
/// `PackageDescription` factory names `surface-check` judges a manifest by.
```

The code after it:

```swift
public enum ManifestDeclarationsReader {
  public static func isManifest(_ path: String) -> Bool {
    ManifestDiff.isManifest(path)
  }

  public static func read(_ text: String) -> ManifestReading {
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 825ddf7963efbb3c22ab2c48d1d9fecb9e6475ef plugin/gate/Sources/SwiftGateRules/Surface/ManifestDeclarationsReader.swift

## Case 56 · key b16d6944

Comment:

```swift
/// `ModuleGraphLoader` that `arch`, `design-scope` and SessionStart use.
```

The code after it:

```swift
enum ModuleGraphRun {
  enum Outcome: Sendable, Equatable {
    case dumped(String)
    case failed(message: String)
  }
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 7847c40f9849d176179d46506a4cb5da82acb832 plugin/gate/Sources/SwiftGateCLI/Commands/ModuleGraphCommand.swift

## Case 57 · key b2d8a133

Comment:

```swift
/// Names of file-local non-test functions that (transitively) contain assertions.
```

The code after it:

```swift
  let assertingHelpers: Set<String>

  init(_ unit: SourceUnit) {
    self.unit = unit
    tests = TestFunction.all(in: unit)
    let testIDs = Set(tests.map(\.decl.id))
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateRules/Testlint/TestlintRules.swift

## Case 58 · key b5e2f562

Comment:

```swift
/// `nil` when the config decodes.
```

The code after it:

```swift
  var loadConfig: @Sendable (_ text: String) -> ConfigLoadError?

  static let live = BuildSeedChecks(
    schedule: { BuildScheduler.next(ledger: $0, running: $1, preset: $2, startedAt: $3, now: $4) },
    setStatus: { plan, task, status in
      do throws(LedgerWriterError) {
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 77e7b8f537c75aa1d98f9a6df134f8a585479387 plugin/gate/Sources/SwiftGateCLI/Commands/SelfTestCommand.swift

## Case 59 · key b7372439

Comment:

```swift
/// Locale-independent so output is byte-stable across machines.
```

The code after it:

```swift
  public static func duration(_ milliseconds: Int) -> String {
    guard milliseconds >= 1000 else { return "\(milliseconds)ms" }
    return "\(milliseconds / 1000).\(milliseconds % 1000 / 100)s"
  }
}
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/ReportRenderer.swift

## Case 60 · key b9a4e85b

Comment:

```swift
/// The interface's contract with the features that depend on it: tests must stub what they use,
```

The code after it:

```swift
/// and an override set in a dependency context is the one a feature reads.
@Suite
struct APIClientTests {
  @Test(
    "the test value fails an unstubbed call instead of answering — catches a feature test passing on a made-up fact it never stubbed"
  )
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 89a17a906a831ef7371944c7e2356bb88d0e19e6 examples/SampleApp/Packages/APIClient/Tests/APIClientTests/APIClientTests.swift

## Case 61 · key bdee5ed0

Comment:

```swift
/// domain inputs. Every slicing decision — which lines of a source end up in the pack — stays in
```

The code after it:

```swift
/// `ContextPack` (`SwiftGateDomain`); this type only reads files and hands their untouched
/// contents to the domain builders.
public enum ContextPackFiles {
  public enum Failure: Error, Sendable, Equatable {
    case unreadable(path: String)
  }
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateAdapters/Context/ContextPackSources.swift

## Case 62 · key c137f26a

Comment:

```swift
// Absent: sampleTask never set actualLines, so it stays nil and the key never appears.
```

The code after it:

```swift
    #expect(Self.sampleTask.actualLines == nil)
    let absentPass = try encoder.encode(Self.sampleTask)
    #expect(!String(decoding: absentPass, as: UTF8.self).contains("actualLines"))
    #expect(try JSONDecoder().decode(LedgerTask.self, from: absentPass).actualLines == nil)
  }
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Tests/SwiftGateDomainTests/LedgerModelTests.swift

## Case 63 · key c13d8a08

Comment:

```swift
// Parallel tests open and close descriptors too; a leak of even 1 per run clears this margin.
```

The code after it:

```swift
    #expect(after - before < runs / 2, "\(after - before) more descriptors open after \(runs) runs")
  }

  @Test(
    "a run returns once the child exits and its output closes, not after the drain limit — catches the parent holding a pipe's write end so every run waits out the limit"
  )
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: e5550ff28d4d6a1fda8a269a933445fe5c26e06c plugin/gate/Tests/SwiftGateAdaptersTests/LiveProcessRunnerTests.swift

## Case 64 · key c301a4e6

Comment:

```swift
/// depends on `--role` (checked in ``ContextPackRun``, not by ArgumentParser) — a single option
```

The code after it:

```swift
/// group keeps the command's argument surface in one place instead of duplicating it per role.
struct ContextPackOptions: ParsableArguments {
  @Option(help: "The agent role the pack is sliced for (spec §5.10).")
  var role: String

  @Option(help: "Distinguishes several packs of the same role, e.g. a worker's task id.")
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateCLI/Commands/ContextPackCommand.swift

## Case 65 · key c9456317

Comment:

```swift
// Production source is reverted; tests, manifests, resources and config keep the change. A
```

The code after it:

```swift
    // path outside the module graph (no Package.swift target claims it) is production input too
    // when it's one of the harness's own stamped resources — a template a test can guard — so it
    // reverts alongside the Swift sources instead of silently keeping the change under test.
    var reverted: [String] = []
    var copied: [String] = []
    for path in changed {
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 3e34108a391406be0e87310ee54eab9e99bf7bfb plugin/gate/Sources/SwiftGateCLI/ChangedTestChecks.swift

## Case 66 · key ca5f8d93

Comment:

```swift
// Deliberately not staged: `git add` never ran.
```

The code after it:

```swift

    let outcome = await CommentsCheck.run(
      root: repo.root, git: repo.git, swiftPM: ScopeResolution.liveSwiftPM(root: repo.root))
    guard case .checked(let result) = outcome else {
      Issue.record("expected checked, got \(outcome)")
      return
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Tests/SwiftGateCLITests/MarkdownLocalPathHookTests.swift

## Case 67 · key ce0987f5

Comment:

```swift
/// Regression: the counter buttons stop updating the on-screen value (store not wired to the view).
```

The code after it:

```swift
  @MainActor
  func testIncrementAndDecrementUpdateTheDisplayedCount() {
    let app = XCUIApplication()
    app.launch()

    let value = app.staticTexts["counter.value"]
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 5ff680b845737e68702e85d338744901fb005434 examples/SampleApp/UITests/CounterFlowUITests.swift

## Case 68 · key cedb0215

Comment:

```swift
/// carries its Mermaid diagrams, and every section — plus the document as a whole — stays inside
```

The code after it:

```swift
/// its configured word budget. Every numeric limit comes from `DocsBudgets`; this file names none
/// of its own.
public enum DesignLintDiagrams {
  /// Mermaid diagram grammars `design-lint` recognises without running `mmdc`. A fence whose
  /// declaration falls outside this set — a typo, an invented type, an all-blank fence, or a `%%`
  /// comment standing in for the real declaration — is unknown. Full syntax validation still runs
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Design/DesignLintDiagrams.swift

## Case 69 · key d2715192

Comment:

```swift
// alongside the two real, correctly attributed failures.
```

The code after it:

```swift
    let attribution = ProbeAttribution.attribute(
      diagnostics, probes: [Self.fabricated, Self.wrongSignature])
    #expect(attribution.verdicts.allSatisfy { $0.verdict == .red })
    #expect(attribution.unattributed.count == 7)
    #expect(attribution.verdict == .red)
  }
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Tests/SwiftGateDomainTests/ProbeVerdictTests.swift

## Case 70 · key d9006d33

Comment:

```swift
/// Composition root: the only place that links the `*Live` client modules, whose `DependencyKey`
```

The code after it:

```swift
/// conformances supply the live values the features resolve at runtime.
@main
struct SampleApp: App {
  @MainActor static let store = Store(initialState: CounterFeature.State()) { CounterFeature() }

  var body: some Scene {
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 5ff680b845737e68702e85d338744901fb005434 examples/SampleApp/App/SampleApp.swift

## Case 71 · key db2ceef5

Comment:

```swift
/// `design-lint <doc>`): the caller — the FS adapter — reads every file docs-lint scans and hands
```

The code after it:

```swift
/// each one over as a ``ScannedDocument``.
public enum DocsLintPolicy {
  /// The harness's own product paths: binaries and caches it legitimately tells readers to look
  /// at, so ``LocalPathRule`` never flags them. No config key — letting a repo override this would
  /// let a real machine-specific path slip through disguised as "product".
  public static let productPaths: [String] = [
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Docs/DocsLintPolicy.swift

## Case 72 · key de7599c2

Comment:

```swift
/// The exact frame-answers JSON `design-scope` already decodes (Wave 8's
```

The code after it:

```swift
  /// `{schemaVersion, touchedModules, newModules, newDependencies}`); research-lane reuses that
  /// decoder rather than taking touched-module names as a second, independently-typed CLI input.
  private static func frameAnswersJSON(touching modules: [String]) -> String {
    let names = modules.map { "\"\($0)\"" }.joined(separator: ", ")
    return
      "{\"schemaVersion\": 1, \"touchedModules\": [\(names)], \"newModules\": [], "
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Tests/SwiftGateCLITests/ContextPackCommandTests.swift

## Case 73 · key dfb62f95

Comment:

```swift
/// handshake that replaces guessing how long a child takes to start on a loaded machine.
```

The code after it:

```swift
public struct ReadinessFIFO: Sendable {
  private let directory: URL
  public var path: String { directory.appending(path: "ready").path }

  public init() throws {
    let token = UUID().uuidString  // swiftgate:allow det.uuid-init — unique directory
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: d12703c26d0d1f539c55c1bb27319eb5b6d1afbc plugin/gate/Sources/SwiftGateTestSupport/ReadinessFIFO.swift

## Case 74 · key e2922d6b

Comment:

```swift
/// `@Suite(.serialized, …)` in any argument position.
```

The code after it:

```swift
  private static func isSerializedSuite(_ attributes: AttributeListSyntax) -> Bool {
    attributes.contains { element in
      guard let attribute = element.as(AttributeSyntax.self),
        ["Suite", "Testing.Suite"].contains(attribute.attributeName.trimmedDescription),
        case .argumentList(let arguments) = attribute.arguments
      else { return false }
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateRules/Testlint/SerializationRules.swift

## Case 75 · key e2bd91e8

Comment:

```swift
/// Ordered levels, worst first.
```

The code after it:

```swift
    case score([String])
  }

  /// Which answer marks the subject as a problem.
  public enum Flag: Sendable, Hashable {
    /// The probability of this option.
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Judge/Judge.swift

## Case 76 · key e4949c78

Comment:

```swift
///   starts with the flow's name (case- and punctuation-insensitive), the same mapping testlint
```

The code after it:

```swift
///   applies statically.
/// - At most `pyramid.max_flows` UI tests run. The config already caps the flow list; this caps
///   the tests, so one flow cannot quietly grow into a suite.
/// - Every declared flow has a test: a critical flow without one is a gap, not a pass.
public enum FlowCoverage {
  public static let unmappedRuleID = "t3.unmapped-flow"
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Simulator/FlowCoverage.swift

## Case 77 · key e544097f

Comment:

```swift
/// exits 0 and decides through this JSON, never through exit code 2, so the decision and its
```

The code after it:

```swift
/// reason travel together.
public enum HookOutput {
  /// Context Claude reads: SessionStart at the start of the session, PreToolUse and PostToolUse
  /// next to the tool result.
  public static func context(_ event: HookEvent, _ text: String) -> String {
    encode(["hookSpecificOutput": ["hookEventName": event.claudeName, "additionalContext": text]])
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateDomain/Hooks/HookOutput.swift

## Case 78 · key ee3a657b

Comment:

```swift
/// Whether a repository-relative file lies where a directory walk would never look: under an
```

The code after it:

```swift
  /// excluded directory, build output, or a hidden directory.
  public func isExcluded(_ relativePath: String) -> Bool {
    let components = relativePath.split(separator: "/").dropLast()
    var prefix = ""
    for component in components {
      prefix = prefix.isEmpty ? String(component) : "\(prefix)/\(component)"
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateAdapters/SwiftSourceCollector.swift

## Case 79 · key f360b33c

Comment:

```swift
/// reports outlive it. The history file stays behind: the destination's own history counts only
```

The code after it:

```swift
  /// its own runs. A run already in `destination` counts as kept, since run ids are unique.
  /// - Throws: when this store's runs directory exists but can't be listed.
  public func keepRuns(in destination: RunStore) throws(RunStoreError) -> RunKeepOutcome {
    let files = FileManager.default
    let source = worktreeRoot.appending(path: RunLayout.runsDirectory, directoryHint: .isDirectory)
    let names: [String]
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 974ca066877d5dec599572b082b9c9ada9de1b1b plugin/gate/Sources/SwiftGateAdapters/RunStore.swift

## Case 80 · key fd1ae16d

Comment:

```swift
/// own hygiene, not a code defect to fail the build over), but never silent either.
```

The code after it:

```swift
enum KnownIdSourceFindings {
  static let ruleID = "comments.id-source-unreadable"

  static func make(_ unreadable: [KnownIdSources.UnreadableSource]) -> [Finding] {
    unreadable.compactMap { source in
      try? Finding(
```

Questions:

- loses-fact: If this comment were deleted, would a reader lose a fact they cannot recover from the code (a non-obvious why, a footgun warning, a contract, a suppression reason)? Options: yes, no.
- right-size: Is the comment the right size for the fact it carries (no restated code, no history narration, no padding)? Options: yes, no.

Answer loses-fact:
Answer right-size:

Source: 618c1800c5739ff306eaede382291dd5513baeaa plugin/gate/Sources/SwiftGateCLI/StaticCheckInputs.swift
