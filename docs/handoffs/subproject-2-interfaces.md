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

## Wave 4

**Edit guard** (`PlanStateGuard`, rule `guard.plan-state`)
- It protects everything under `<common>/swift-harness/plans/`, plus `docs/**/designs/*.md` and `*.evidence/**`. Nobody may
  edit `orchestrator.lock`. Any payload `agent_id` means deny.
- Write access:
  - `index.json`: any session whose id is in some plan's `orchestrator.lock`.
  - A design doc or its evidence: only the holder of the plan whose `plan.json` field `design` names that doc.
    Paths are resolved against the **writing session's own worktree**.
  - `SWIFT_HARNESS_ORCHESTRATOR=1` overrides. A git failure fails closed. The guard never writes.
- **Design skill constraint:** author the design doc in the session's own checkout, on its `design/<slug>` branch.
  Never write into a sibling worktree's copy.
- In this repo, editing `docs/designs/` from a plugin-loaded session needs a claim or the override.
- The dead worktree-relative `.harness/plans` rule is still present. The packaging task deletes it.

**Id-leak rules** (`comments.leaked-id`, `test.leaked-id`)
- `IdLeakScan.matches(in:knownIds:)` flags:
  - exact known ids
  - `Phase|Stage|Wave` + number
  - bare `[A-Z]{2,3}\d{1,2}[a-z]?`

  It needs 2 or more capitals because `T0`–`T3` tiers and standards codes like `D7` are legitimate. `UTF8`, `SHA1`,
  `MD5` and `ARM64` are denylisted.
- `KnownIds.build(ledgerTaskIds:claimIds:docIds:)` → pass the result to `RuleContext(knownIds:)`.

**SessionStart**
- It injects `Session id: <id> (pass as `--session` to `swiftgate plan claim`/`plan release`).`, once, only when the id is non-empty.
- Then `Active plans (RESUME summaries; ledgers are orchestrator-only):` followed by `- <slug> (<status>): <resume>`,
  capped at 4,000 characters with an `…and N more` line.
- `SessionContext.resolvePlans(indexData:)`. Use `PlanIndex.encode()` for index writes: pretty-printed, sorted keys, trailing newline.
  It never fails a session.

## Wave 5

**`plan claim` / `plan release`** (the only writers of `orchestrator.lock`)
- `swiftgate plan claim <plan> --session <id> [--design docs/**/designs/<name>.md] [--tier quick|standard|deep] [--json]`.
  Exit 0 when claimed or already held, 1 when held by another session (the message names the holder), 2 when blocked.
  A new plan requires `--design`.
- The claim writes the lock by exclusive create (`mkstemp` + `link(2)`). The lock is exactly `<session-id>\n`.
  A new plan also gets a seed `plan.json` (`design` set, `designSha` and `tier` optional/nil), written with
  `link(2)` so it never overwrites an existing one.
- `swiftgate plan release <plan> --session <id> [--force] [--json]`. Exit 0 when released or not claimed, 1 when the
  caller isn't the holder, 2 when blocked. `--force` needs no `--session` and reports whose lock it overrode.
- JSON keys: `command`, `plan`, `status` (`claimed`, `already-held`, `held-by-other`, `released`, `not-claimed`,
  `force-released`, `blocked`), `verdict`, `holder?`, `lockFile?`, `message`.
- `plan-lint` exits 2 while `designSha` is nil.

**`index set`**
- `swiftgate index set <slug> <status> <resume>`. `status` must be a `PlanStatus`: `designing`, `in-review`,
  `approved`, `planned`, `building`, `done`, `abandoned`, `superseded` (spec §5.8). Anything else exits 2 and lists
  the allowed values.
- `PlanStatus.isFinished` covers `done`, `abandoned` and `superseded`. SessionStart shows every other status,
  including an unknown legacy one, as active.
- `PlanIndexStore(path:lock:timeout:).update { }` does a locked read-modify-write. The lock is `index.lock` next to
  `index.json`. Writes are atomic (temp file + rename). Malformed JSON throws and never writes.
  `PlanIndex.settingStatus(slug:status:resume:)` upserts one entry.

**`comments --commit-msg`**
- `swiftgate comments --commit-msg <file>`: exit 0 when clean, 1 on a leaked id, 2 outside a repo or on an
  unreadable file. It can't be combined with `--staged` (enforced in `validate()`), so keep that when editing
  `CommentsCommand.swift`.
- Bootstrap now stamps the `commit-msg` lefthook stanza, and `gitHooks` includes `commit-msg`.
- `KnownIdSources.load(root:git:)` returns the ids plus the sources it couldn't read. Each unreadable source is a
  non-gating `comments.id-source-unreadable` finding.
- `StaticCheckInputs.load` and `TestlintCheck.run` take an optional `git:` so they can check known ids.
  `IdLeakScan` is public.

**Test hygiene:** commands that do real work (`plan claim`, `plan release`, `index set`) are listed by exact
invocation name in `NewSubcommandRegistrationTests.implemented`, because running them there would act on this
checkout's real shared plan state. When the next stub graduates, add its invocation name there and test it in its
own suite against a temp repo.

## Wave 6

**Markdown reader and CRLF.** `MarkdownDocument` treats `\r\n` like `\n` at the line splitter, so no parsed line
carries a trailing `\r`. A lone `\r` stays content. The model keeps no raw text or byte ranges: anything that hashes
or quotes original bytes must read the file itself (as `DesignSha` and the context-pack slicers do).

**Context packs** (`D/Context/ContextPack.swift`, pure, no IO)
- `ContextPackRole`: closed enum, kebab-case raw values: `research-lane`, `claim-checker`, `drafter`,
  `evidence-auditor`, `standards-reviewer`, `challenger`, `decomposer`, `worker`.
- `ContextPack.build(role:inputs:) throws` is the single dispatch: an exhaustive switch over
  `ContextPackRoleInputs` (one case per role, no `default`). A role that doesn't match its inputs throws
  `.roleMismatch`. Per-role builders are also public: `researchLanePack`, `claimCheckerPack`, `drafterPack`,
  `evidenceAuditorPack`, `standardsReviewerPack`, `challengerPack`, `decomposerPack`, `workerPack`.
- Sources with no domain type yet (template, module graph, challenger question set, sizing bounds) go in as a
  `ContextSource` (raw text + source label) and are sliced verbatim by anchor.
- `ContextPack{role, slices, estimatedTokens}`, `ContextPackSlice{sourceLabel, anchor, lines, text}`,
  `TokenCountEstimate{value}` = UTF-8 bytes / 4. `isOverBudget(tokens:)` answers the budget; `plan-lint` owns the
  finding.
- `MarkdownAnchorSlicer.slice(anchor:of:rawText:sourceLabel:)` and
  `CitationExcerptSlicer.slice(for:rawText:sourceLabel:)` are public for `context-pack-command` and
  `evidence-check-rules`.
- `ContextPackError`: `.missingAnchor`, `.duplicateAnchor`, `.unknownCoversID`, `.invalidCitationRange`,
  `.citationRangeOutOfBounds`, `.citationQuoteNotFound`, `.roleMismatch`. A pack is never silently empty.

**`designSha` and `design-diff`** (`D/Design/DesignDiff.swift`, `C/Commands/DesignDiffCommand.swift`)
- `DesignSha.of(_:)` = git blob id of the doc with the frontmatter `status:` line removed, computed in-process.
  Only a top-level `status:` key inside the frontmatter is stripped. An indented one, or one in the body, is
  content. `DesignSha.strippingStatus(_:)` is public. Fixtures in `FX/DesignSha/` are captured `git hash-object`
  output.
- `DesignDiff.compare(old:new:)` → `DesignDiff.Class` (`unchanged`, `clarify`, `amend`) plus
  `DesignDiff.Trigger` (`requirement-line`, `decision`, `module-kinds`, `test-plan`) and changed ids.
  `ClarifyChain.verify(approvedSha:links:revisions:)` checks the chain one link at a time. A chain that crosses a
  file rename fails and says why.
- `swiftgate design-diff <old> <new> [--json]`: a revision is a path or `<ref>:<path>` (resolved through git, never
  falling back to the working tree). Exit 0 when classified (read `class`), 2 on status `unknown-ref`,
  `missing-path`, `unreadable`, `invalid-revision` or `git-failed`.
- `swiftgate design-diff --chain <plan.json> [--json]`: exit 0 `valid`, 1 `broken`, 2 `no-approval`,
  `unreadable` or `git-failed`.
- JSON keys: `command`, `mode`, `status`, `verdict`, `old`, `new`, `class`, `oldSha`, `newSha`, `triggers`,
  `changedIds`, `plan`, `design`, `approvedSha`, `endSha`,
  `brokenLink{index, fromSha, toSha, problem, triggers?, changedIds?}`, `message`.
- `design-diff` is in `NewSubcommandRegistrationTests.implemented`. Its CLI tests are in
  `TC/DesignDiffCommandTests.swift`.

**Design-lint diagrams and budgets** (`D/Design/DesignLintDiagrams.swift`)
- `DesignLintDiagrams.check(document:docPath:budgets:) throws(ReportContractViolation) -> [Finding]`.
- Rule ids, all `major` (spec §5.3: over budget is a violation): `design-lint.architecture-diagram-count`,
  `design-lint.architecture-diagram-unknown-type`, `design-lint.section-word-budget`,
  `design-lint.document-word-budget`. Sibling design-lint rules use the `design-lint.` prefix.
- `DesignLintDiagrams.knownMermaidDiagramTypes` is the closed type set. A blank or `%%` first line is unknown.
- `DocsBudgets.defaultSectionWords = ["architecture": 80]` is the `sections` default. A repo's
  `[docs.budgets.sections]` merges over it by key and never drops a default it didn't name. Section budgets
  apply only to anchors listed in `sections`; everything else is bounded by `budgets.design` (whole doc, summed
  over subsections). **`docs-lint` budgets inherit the `architecture` default too:** decide deliberately whether
  it applies outside design docs.
- Fixtures: `GF/design/diagrams/{missing-diagrams,unknown-type,known-types-with-direction,blank-and-comment-fences}.md`.
