# Sub-project 2 — interfaces note

Running record of the types, file formats and flags each merged wave introduced, for later workers.
Only the orchestrator edits this file, appending one section per wave at merge. Workers read it.

## Before wave 1: gate fix

- New module kind `test-support` (`ModuleKind.testSupport`, `ModuleRole.testSupport`). It's excluded from T1
  presence, diff coverage and the determinism lint. Rule `arch.test-support-dependency` (major): only test
  targets and other test-support modules may depend on one. `SwiftGateTestSupport` is declared with this kind.

## Wave 1

**Bootstrap**
- `BootstrapPlanner.Paths.docsIndex = "docs/index.md"`, `HarnessTemplates.docsIndex: String` (last init parameter),
  `BootstrapFiles.TemplateNames.docsIndex = "templates/docs-index.md"`. The router is created once, then left alone.
  The design and plan skills own adding rows.
- `Paths.planIndex` / `emptyPlanIndex` were removed: nothing under `.harness/plans/` is stamped any more.
- `BootstrapPlanner.gitHooks = ["pre-commit", "pre-push"]`. The `commit-msg` hook lands with `comments --commit-msg`.
- `templates/design-doc.md`: frontmatter `status` / `area` / `tier`, plus the spec §5.3 sections in order.

**Evidence records** (all in `SwiftGateDomain`)
- `Claim` (id, lane, text, citation, status) and `Citation` (kind `.file/.snapshot/.capture/.probe/.answer`, `loc`,
  `pin?`, `quote?`).
- `ClaimStatusMachine.canTransition(from:to:citationKind:)`. `ClaimJSON.encodeLine` / `decode` (JSONL).
- `Amendment` (title, at, class, fromSha, toSha, changedIds, newClaims, trigger, review?, approval?).
  `Amendment.Class` is `.amend` / `.clarify`. Also `Amendment.isValid(_:)` and `AmendmentJSON`.
- `IdKind` `.requirement/.testPlanItem/.claim` → prefixes `req-` / `test-` / `ev-`. `IdPolicy.isValid(_:kind:)`
  requires ≥3 words and rejects `-R1`-style suffixes. Also `IdPolicy.isValidADRSlug(_:)`.
- `EvidenceLayout(designDocPath:)` → `.root`, `.claimsFile`, `.amendmentsFile`, `.snapshotsDirectory`,
  `.capturesDirectory`, `.probesDirectory`.

**CLI stubs** (`gate/Sources/SwiftGateCLI/Commands/`, one owner each)
- Files: `EvidenceCheckCommand`, `EvidenceCaptureCommand`, `EvidenceFindCommand`, `ProbeCommand`,
  `DesignScopeCommand`, `DesignLintCommand`, `DesignDiffCommand`, `DesignRenderCommand`, `DocsLintCommand`,
  `ProseCommand`, `PlanClaimCommand`, `PlanReleaseCommand`, `PlanScheduleCommand`, `PlanLintCommand`,
  `ContextPackCommand`, `IndexCommand` (nested `IndexSetCommand`), `CalibrateCommand` (nested
  `CalibrateDesignCommand`).
- A stub calls `try StubCommand.notImplemented("<path>", json:)`, which exits 2 (`Verdict.blocked`). Replace the call;
  don't edit `SwiftGate.swift`.
- `evidence capture` takes its passthrough command with ArgumentParser `.remaining` (`-- <cmd>`).
- `RepositoryScriptTests` discovers `tests/*_test.mjs` automatically.

## Wave 2

**Config** (`Config.docs`, `Config.plan`)
- `DocsConfig` (managedFiles, bannedPhrases, anchors, sentenceCeiling, budgets), `BannedPhrase` (phrase, reason),
  `DocsBudgets` (router, topic, design, agentsMdLines, sections `[String:Int]`).
- `PlanConfig` (maxParallel, estLinesMin, estLinesMax, maxModulesPerTask, maxTestsPerTask, workerPackTokenBudget).
- TOML: `[docs]` `managed_files`, `[[docs.banned_phrases]]` `phrase`/`reason`, `anchors`, `sentence_ceiling`;
  `[docs.budgets]` `router`/`topic`/`design`/`agents_md_lines`/`sections`; `[plan]` `max_parallel`, `est_lines_min`,
  `est_lines_max`, `max_modules_per_task`, `max_tests_per_task`, `worker_pack_token_budget`.
- Defaults (estimates, to tune): max_parallel 3, estLines 40–400, 2 modules, 6 tests, pack 15000 tokens;
  sentence ceiling 40, router 400, topic 800, design 1200 prose words, AGENTS.md 60 lines.
- The root `.swiftgate.toml` has a live `[docs]` section: managed files `docs/index.md` and `AGENTS.md`, plus banned phrases.

**Plan state** (`SwiftGateDomain/Plan/`)
- `PlanFile` / `PlanFileJSON`, `Ledger` / `LedgerTask` / `LedgerJSON`, `TaskStatusReport` / `TaskStatusReportJSON`.
  Each is a single pretty-printed JSON object with sorted keys and ISO-8601 dates (not JSONL). `PlanFile.approval` is optional.
- `LedgerTask.gate: CheckTier` (Codable in `Plan/CheckTierCodable.swift`). `TaskStatus` is closed: unknown values
  fail decoding and name the value.
- `WriteSet.entriesOverlap(_:_:)` / `WriteSet.overlaps(_:_:)`: the disjointness primitive for `plan-lint`.
- `TaskStatusReport.Report.evidence: [Citation]` reuses the wave-1 `Citation`.

**Markdown and design docs**
- `MarkdownDocument.parse(_:)` returns frontmatter plus a `sections` tree. `Section` has level, heading, anchor
  (GitHub slug), bullets, tables, fences, links, `proseWordCount` (excludes tables and fences) and subsections.
  Look sections up with `section(anchor:)`.
- `Bullet` (text, `id`, `remainder`, `tags`), `Fence` (language, body, `mermaidDiagramType`), `Table`, `Link` (`isRelative`).
- `DesignDocument(markdown:)` exposes typed views of every spec §5.3 section. `status` includes `.unknown(String)`
  on purpose: the parser keeps bad values, and **`design-lint` must report `.unknown` status as a violation**.
- Test-plan tier parsing splits on the literal `" — tier "`.
- `gate/Fixtures/design/valid.md` is a full, spec-compliant design doc. Later waves treat it as read-only.

## Wave 3

- **`designSha` isn't retrievable.** It hashes content that git never stores. Find a revision by walking
  `git log --follow -- <doc>` and hashing each revision with its status line stripped (`hash-object --stdin`, never `-w`).
  `Git.blobContents` only finds blobs that are actually stored, so don't use it to look up a `designSha` (spec §5.4).

**Shared plan state**
- `Git.commonDirectory()` returns an absolute, realpath-canonical path. Empty or no repository → BLOCKED.
- `Git.revisions(of:)` lists commit ids newest first and follows renames. It throws `GitError.invalidPath` on an empty or NUL path.
  `Git.blobContents(_:)` only finds stored blobs.
- `PlanStateLayout(commonDirectory:)` exposes `.root` (`<common>/swift-harness/plans`) and `.indexFile`.
  `.plan(name)` gives `{directory, planFile, ledgerFile, orchestratorLock}` and rejects `/`, `.`, `..`, NUL, newline and empty names.
- `FakeGit(commonDirectory:, blobs:, history:)`. Its existing `revisions:` parameter is for `revision(_:)`.
- `GitBlobID.of(_:)` computes git's blob id (SHA-1 of `blob <bytes>\0content`) in process.

**Probes**
- `ProbeIdentifier.enumName(forClaimID:)` / `fileName(forClaimID:)` → `Probe_<id with - as _>` and `Probe_<…>.swift`.
  The probe builder MUST name files this way.
- `CompilerDiagnostics.parse(_:)` reads only the primary `path:line:col: error|warning:` lines.
  `ProbeAttribution.attribute(_:probes:)` matches by file basename. An error it can't attribute forces at least BLOCKED.
- Fixtures are `gate/Tests/Fixtures/Probe/{good,mixed,unattributed}`; the capture recipe is in `gate/Tests/Fixtures/README.md`.

**Known suspect flake:** the Foundation shim test ("swiftgate shim caches and rebuilds") failed once on a cold rebuild,
then passed. If it recurs, run it through `flake-hunter`.
