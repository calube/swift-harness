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

## Wave 7

**The shared valid design, `GF/design/valid.md`.** It must produce zero findings under every design-lint rule.
When a new rule finds it invalid, the task that adds the rule fixes the fixture. It never builds a private
"valid" copy to route around it. Every tag in it must be honest: cite an `ev-` claim only where that claim
supports the bullet, and otherwise use `[UNVERIFIED]` with a restatement in Risks or Open questions.
`design-lint-command` must assert that it's clean under every rule together.

**Design-lint, shared conventions.** Each rule family is a static `check(...) throws(ReportContractViolation) ->
[Finding]` with rule ids prefixed `design-lint.`, and every finding is `major` (gating).

**Evidence tags** (`D/Design/DesignLintEvidence.swift`)
- `DesignLintEvidence.check(document:docPath:claims:)`, with `claims: [Claim]`.
- Rule ids: `design-lint.untagged-bullet` (Evidence, Decision and Perf), `design-lint.unknown-claim` (any tagged
  section), `design-lint.citation-not-supported` (Decision only, spec §5.3), `design-lint.unverified-in-decision`,
  `design-lint.unverified-uncovered`, `design-lint.perf-missing-dimension`.
- Coverage is mechanical: the unverified bullet's text, with `[UNVERIFIED]` and `[ev-…]` tags stripped,
  whitespace collapsed, case ignored and a trailing period dropped, must be contained in some Risks or
  Open-questions bullet. A paraphrase doesn't count. The spec's Risks row now says this.
- `DesignLintEvidence.PerfDimension: CaseIterable`: `throughput`, `tailLatency`, `fanOut`, `failureIsolation`,
  `resources`, `backpressure`, `tenX`, each with a public `displayName`.

**Sections and ids** (`D/Design/DesignLintSections.swift`)
- `DesignLintSections.check(document:docPath:otherDesignIds:)`. `otherDesignIds: Set<String>` holds the `req-`/`test-`
  ids DEFINED by every other design. The caller scans `docs/**/designs/*.md`. A citation never goes in the set.
- Rule ids: `design-lint.section-missing`, `.section-order`, `.problem-empty`, `.requirement-id-form`,
  `.requirement-id-duplicate`, `.test-id-form`, `.test-id-duplicate`, `.test-tier-invalid`, `.options-count`,
  `.module-kind-unknown`.
- `DesignDocument.RequiredSection` (`.anchor`, `.name`) is the one ordered list of required sections, read by
  both the parser and the lint. Module kinds are `ModuleKind` raw values: `feature`, `engine`, `render`,
  `library`, `client`, `test-support`.
- Baseline fixture: `GF/design/sections/complete.md`.

**Design review verdict** (`D/Review/DesignReviewVerdict.swift`, `C/Commands/ReviewCommands.swift`)
- `review-synth --run-directory <dir> --design <doc> --tier quick|standard|deep [--json] [files…]`. Exit 0 on any
  verdict (`ready`, `revise`, `rethink`), and `design-review.json` is written. Exit 2 on a bad or missing tier, an
  unknown or duplicate reviewer, an anchor absent from the doc (matched case-sensitively, never inside a fence),
  or an unreadable file. Nothing is written on exit 2.
- `design-review.json`: `schemaVersion`, `tier`, `verdict`, `required`, `rerun`, `findings[{finding, reviewers}]`,
  `dropped`, `notReviewed`, `notResearched`.
- Reviewer input: `{schemaVersion: 1, reviewer, status: reviewed|not-reviewed|not-researched, reason?, findings}`.
  A finding uses `location: {anchor}` and carries no `file` or `line`.
- Reviewers: `evidence-auditor`, `standards-reviewer`, `challenger`, `pre-mortem`. Required: quick = none, standard
  = the first 3, deep = all 4. `quick` is `ready` when no file is given, or every given file is `reviewed` with
  no kept blocker or major.
- `ReviewSynthesis.dropReason(_:)` is the ONE verify-step drop rule for both code and design review. Don't copy it.

## Wave 8

**Plan lock hardening.** A dangling-symlink `orchestrator.lock` used to read as "held by an empty session" that
neither `release` nor `--force` would clear, so the plan could never be claimed again. `claim` now fails with an
io error naming the path. The lock's error paths (read-only dir, `EEXIST` from a concurrent claimer, a staging
file left by a crash, `ENOTSUP`/`ENOSPC` on a real FAT volume) are tested. The volume tests attach a 1 MB image
with `hdiutil -nobrowse`, always detach in a `defer`, and are skipped when `hdiutil` is absent.

**`design-scope`** (`D/Design/DesignScope.swift`, `C/Commands/DesignScopeCommand.swift`)
- `swiftgate design-scope --frame-answers <path> [--json]`. Input:
  `{schemaVersion: 1, touchedModules: [String], newModules: [{name, kind}], newDependencies: [String]}`.
  `kind` is a `ModuleKind` raw value. Frame answers NAME modules. They never count them.
- The CLI loads the module graph with `ConfigLoader` + `ModuleGraphLoader`, the same loaders `arch` uses, and
  derives `{addsDependency, addsModuleKind, modulesAdded, modulesTouched}` in pure domain code.
- Exit 0 whenever a tier is recommended. Exit 2, with no report, on: a missing flag, an unreadable file,
  malformed JSON, a bad `schemaVersion`, an unknown kind, a touched module not in the graph, a "new" module
  that already exists, or duplicate names. A default tier is never assumed.
- Constants, not config: `DesignScope.modulesAddedDeepThreshold = 2`, `.modulesTouchedDeepThreshold = 4`.
  A new dependency or a new module kind is never `quick`, which is proven over every input combination.
- Output: `DesignScopeReport{command, tier: DesignTier, reasons: [{code: DesignScopeReason, message}], input,
  message}`. `input` echoes both the answers and the derived counts.

**Docs-lint policy and budgets** (`D/Docs/DocsLintPolicy.swift`, `D/Docs/LocalPathRule.swift`)
- `DocsLintPolicy.check(documents: [DocsLintPolicy.ScannedDocument], config: DocsConfig)` sweeps the whole corpus.
  `ScannedDocument{path, rawText, markdown}`.
- Rule ids, all `major`: `docs-lint.managed-file-missing`, `.managed-file-unlisted` (router `docs/**/index.md`
  files and `AGENTS.md` absent from `managed_files`), `.anchor-vacuous`, `.banned-phrase`,
  `.agents-md-line-budget`, `.router-word-budget`, `.topic-word-budget`, `.local-path`.
- Section budgets (`[docs.budgets.sections]`, e.g. `architecture = 80`) belong to design-lint only. A design doc,
  meaning a `.md` directly under a path component named `designs`, is exempt from docs-lint's whole-file budgets
  because design-lint governs it.
- `LocalPathRule.scan(_ text: String, file: String) -> [Finding]` is pure. It flags home-relative paths (tilde or the
  home variable), the macOS and Linux user-folder roots and the system temp roots, INCLUDING inside fenced and inline code (the spec is silent, and a
  copied example still breaks for its reader). URLs and system paths like `/usr/bin/find` pass.
- `DocsLintPolicy.productPaths = ["~/.swift-harness/", "~/.local/bin/swiftgate", "~/.cache/swift-harness/"]`.
  This is a constant with no config key.

**Docs-lint references and links** (`D/Docs/DocsLintReferences.swift`)
- `DocsLintReferences.check(...)` takes `DocsLintReferences.DocFile{path, text}` (the docs corpus), `claims:
  [Claim]` and `repoPaths: Set<String>` (every tracked file, from `git ls-files`). No IO.
- Rule ids, all `major`: `docs-lint.dangling-id`, `.bare-adr-reference`, `.requirement-uncited` (cited nowhere
  outside its defining design), `.broken-relative-link`, `.unreachable-doc` (a walk from
  `DocsLintReferences.routerRoot = "docs/index.md"` that handles cycles).
- Every relative link resolves against `repoPaths`. A file link must be in the set. A directory link must be a
  real directory prefix (`../gate/Sour` fails). `#anchor` is stripped and not verified. A leading `/` means
  repo-root-absolute. Climbing above the root is flagged. External schemes and links inside code are ignored.
- **`docs-lint-command` must unify the two corpus types** (`ScannedDocument` and `DocFile`) into one, built once
  from the filesystem. Don't keep two readers of the same files.

## Wave 9

**Citation contract for evidence kinds.** `snapshot`, `capture`, `probe` and `answer` locs are relative to
`<slug>.evidence/`, so citations travel with the doc: `snapshots/<name>`, `captures/<sha256hex>.txt`,
`probes/Probe_<id>.swift`, `answers.jsonl#<runId>/<n>`. A `file` loc is repo-relative (`<path>:L<a>[-L<b>]`,
`.build/checkouts/…` allowed); absolute, home-relative and above-root locs fail. A capture's `pin` is exactly
`sha256:` + 64 lowercase hex. The one sha256 hex helper is `CaptureDigest.sha256Hex(_: Data)` in
`D/Evidence/EvidenceCheck.swift`; don't add another.

**`evidence capture`** (`A/Evidence/EvidenceCapture.swift`, `C/Commands/EvidenceCaptureCommand.swift`)
- `swiftgate evidence capture --design <doc> -- <cmd…>`. argv goes straight to the executable, never a shell.
- Stores `captures/<sha256(content)>.txt`, plain text:
  `"$ argv\nexit: exited N|signaled N\n\n--- stdout ---\n…\n\n--- stderr ---\n…\n"`.
- `EvidenceCapture.run(argv:evidenceRoot:repoRelativeCapturesDirectory:workingDirectory:runner:timeout:)
  -> Result<Outcome, Failure>`. `Outcome{citation, capturePath, status, stdout, stderr}`; `status` is the
  process-status enum. JSON: `"status": {"exited": N}` / `{"signaled": N}`, `null` on the blocked path.
- Exit 0 whenever the capture itself succeeds, whatever the captured command's exit. Exit 2 for a bad
  `--design`, empty command, launch failure or write failure.
- `NewSubcommandRegistrationTests.implemented` lists every subcommand whose stub is replaced; each command task
  adds its own entry there.

**Evidence check rules** (`D/Evidence/EvidenceCheck.swift`), pure, no IO
- `EvidenceCheck.check(_: [Claim], sources: some EvidenceSources, mode: .workingTree | .atRef)
  -> [EvidenceCheckResult]`. `EvidenceSources`: `repoFile(path) -> String?`,
  `evidenceFile(pathUnderEvidenceRoot) -> Data?`, `packageResolved: Data?`, `sdkVersion: String?`.
  `InMemoryEvidenceSources` implements it. `evidence-check-command` supplies the real one.
- Outcome: `.passed`, `.relocated(loc:)`, `.failed(EvidenceCheckFailure)`, `.stale(EvidenceStaleReason)`; plus
  `claimStatus: Claim.Status?` (nil only for a probe with no usable verdict) and `isFailing`.
- `ProbeVerdictRecord{claimId, verdict: pass|fail, diagnostics[{file,line,column,level,message}],
  pins{identity: version}, sdk}` at `ProbeVerdictRecord.path(forClaimID:)`, written with `.encode`.
  `probe-builds-scratch-package` must write this type.
- `AnswerRecord` lines live at `EvidenceLayout.answersFile`; one bad line fails the whole file. An answer
  claim's quote, if present, must appear in the recorded question.

**Evidence reuse cache** (`D/Evidence/EvidenceCache.swift`, `A/Evidence/EvidenceCacheStore.swift`)
- Only `ReusableClaim(_ claim) throws(EvidenceCacheRefusal)` admits a claim; codebase claims are refused.
  Enums: `ReusableClaimKind`, `EvidenceCacheOrigin` (`research-lane`, `claim-checker`, `probe`),
  `EvidenceCacheTombstoneReason`, `EvidenceCacheVerdict`.
- Files under `<home>/.swift-harness/evidence-cache/`: `<pkg>@<ver>.jsonl`, `sdk/<pin>.jsonl`,
  `verdicts.jsonl`; lock `evidence-cache.lock` (`FileCountingLock`, one slot). Pins must be one file component.
- Lines: `{"type": "claim"|"verdict"|"reuse"|"tombstone", claim?, origin?, verdict?, reason?, textHash,
  quoteHash?}`; hashes are sha256 hex.
- `EvidenceCacheStore(home:lock:timeout:)`: `record`, `recordVerdict`, `markReused`, `markVerdictReused`,
  `tombstone`, `contents(of: EvidenceCacheBucket) -> EvidenceCacheContents{claims, verdicts, tombstones,
  findings}`. A corrupt line is a minor `evidence-cache.corrupt-line` finding naming the file, never dropped.

## Wave 10

**Plan-lint coverage and sizing** (`D/Plan/PlanLintCoverage.swift`), pure
- `uncoveredIDs(design:tasks:)`, `coverageFindings(design:tasks:designPath:)`, `minimumGate(for: Tier) -> CheckTier`
  (total over all four tiers; T0 and T1 → `fast`, T2 → `push`, T3 → `ready`), `testTiers(design:) -> [String: Tier]`,
  `gateFindings(task:testTiers:)`, `sizeFindings(task:modulesTouched:workerPack:bounds: PlanConfig)`.
- `sizeFindings` takes `modulesTouched: Set<String>` and `workerPack: ContextPack?` already resolved;
  `plan-lint-graph-and-waves` resolves them from write sets and the module graph. Two modules pass only as
  `X` + `XLive`.
- Rule ids, `major` unless noted: `plan-lint.uncovered-requirement`, `.gate-too-weak`, `.est-lines-high`,
  `.est-lines-low` (`minor`), `.too-many-modules`, `.too-many-tests`, `.pack-over-budget`. Bounds from `PlanConfig`.
- §9.3's "single-dependent chain within one module" warning is NOT here: it needs the whole DAG, so it moved to
  `plan-lint-graph-and-waves`.

**`plan-schedule`** (`D/Plan/PlanSchedule.swift`, `C/Commands/PlanScheduleCommand.swift`)
- `PlanSchedule.schedule(tasks: [LedgerTask], maxParallel: Int) -> Result<[[String]], PlanSchedule.ScheduleError>`;
  `ScheduleError.cycle(ids:)` / `.missingDependency(task:dependency:)`. Deterministic: sorted by id, input order
  ignored. Overlap uses `WriteSet`'s own rules.
- CLI: `swiftgate plan-schedule <ledger>` (required path; a top-level hyphenated command, not `plan schedule`).
  Reads a full ledger via `LedgerJSON.decode`, ignores its `waves`, recomputes from `tasks` + `maxParallel`.
  Exit 0 with waves, 1 on cycle or missing dependency (message names the ids), 2 unreadable/malformed.
  `--json` keys: `command, verdict, ledger, waves?, cycle?, missingDependencyTask?, missingDependencyOn?, message`.

**`prose`** (`D/Prose/ProseRules.swift`, `C/Commands/ProseCommand.swift`)
- `swiftgate prose <files…> [--json]`. `ProseRules.check(_:file:sentenceCeiling:)`. Exit 0 clean, 1 findings,
  2 unreadable file or no files. `--json` is `RunReport`.
- Rule ids, all `major`: `prose.adverb`, `.em-dash`, `.number-word`, `.passive-voice`, `.filler`, `.jargon`,
  `.sentence-length`. Only `[docs] sentence_ceiling` is config; word lists are constants.
- Passive voice = be-verb, optional modifier, then a listed irregular participle or an `-ed` word; state words and
  `un…ed` are exempt; get-passives are missed.
- Reads prose through `MarkdownDocument.proseLines` (line-numbered, skips code, inline code, tables, diagrams,
  HTML comments, frontmatter). Reuse it; don't add a markdown reader.
- Not wired into any tier or hook yet; the repo's docs don't pass. `plugin-docs-pass-docs-lint-and-prose` wires it.

## Wave 11

**`context-pack`** (`A/Context/ContextPackSources.swift`, `C/Commands/ContextPackCommand.swift`)
- `swiftgate context-pack --role <role> [flags]` for all 8 `ContextPackRole`s (an exhaustive switch, no `default`).
  Flags, all repo-relative: `--design --claims --claim-id --brief --pin --template --frame-answers --area
  --module-graph --probe-verdicts --standards --playbook --module-kind --standards-anchor --doc-anchor
  --question-set --task-sizing-bounds --ledger --task-id --key --cache-home` (defaults to `$HOME`).
- Writes `.harness/context-pack/<role>[-<key>].md` and prints the token estimate (bytes / 4).
  `ContextPackRun.run(role:options:root:) -> Outcome{.written(Written{role, relativePath, tokens, notes}),
  .invalid, .violation}`.
- Exit 0 written, 1 domain violation (a missing anchor, never a thinner pack), 2 bad `--role`, unreadable input,
  unknown value, or a touched module missing from the graph. An absent OPTIONAL input is a note.
- The research-lane pack follows spec §5.10: frame answers, area, module-graph slice for the modules the frame
  answers name (`touchedModules`, decoded with design-scope's type), user-cache hits for the pin from
  `EvidenceCacheStore` (tombstones excluded; "no cache hits for <pin>" is a note), the repo's same-pin claims,
  and the lane brief.

**`design-lint`** (`A/Design/DesignLintInputs.swift`, `C/Commands/DesignLintCommand.swift`)
- `swiftgate design-lint <doc> [--json]` runs sections-and-ids, evidence tags, diagrams-and-budgets and `prose`
  in one pass. Exit 0 clean, 1 findings, 2 unreadable or malformed input.
- New rule ids: `design-lint.status-unknown`, `.claims-file-missing`, `.mermaid-syntax` (major);
  `.mmdc-unavailable`, `.claims-file-unreadable-lines` (minor). `mmdc` validates fences when on PATH;
  otherwise the minor note, never blocked.
- `GF/design/valid.md` is clean under every family together, with `GF/design/valid.evidence/claims.jsonl`
  citing the real TCA 1.26.2 line (capture recipe in `gate/Fixtures/design/README.md`).
- Prose's em-dash rule exempts exactly the §5.3 ` — tier T<n>` tail of a `test-…:` bullet
  (`ProseRules.isTestPlanTierSeparator`), so `prose` and `design-lint` agree on design docs.

**`docs-lint`** (`A/Docs/DocsTreeReader.swift`, `C/Commands/DocsLintCommand.swift`, `GF/docs-lint/`)
- `swiftgate docs-lint [--json]`, no positional args. Scans `docs/**/*.md` plus root `AGENTS.md`; `repoPaths`
  from real `git ls-files -z --full-name`. A `CLAUDE.md` symlink counts once; directory symlinks don't loop.
- One corpus type: `DocsLintPolicy.ScannedDocument{path, rawText, markdown}`; `DocsLintReferences.DocFile` is a
  typealias. Builder: `DocsTreeReader(runner:).read(repositoryRoot:) async throws(ReadFailure) ->
  Corpus{documents, repoPaths}`. Reference findings carry real line numbers.
- Exit 0 clean, 1 any finding, 2 unreadable docs or git failure. Minor, non-gating: `docs-lint.no-docs-section`,
  `docs-lint.no-docs-directory`.
- Not wired into any tier or hook yet.

## Wave 12

**`evidence check`** (`A/Evidence/EvidenceFiles.swift`, `C/Commands/EvidenceCheckCommand.swift`)
- `swiftgate evidence check --design <doc> [--at <ref>] [--package-resolved <path>] [--sdk <v>] [--json]`.
  `--design` is required. Without `--sdk`, runs `xcrun --sdk iphonesimulator --show-sdk-version`, only when a probe
  or snapshot claim exists. The adapter implements `EvidenceSources`; every rule stays in `EvidenceCheck`.
- Under `--at`: cited repo files and `Package.resolved` come from the ref via `Git.contents`. `.build/` files
  (untracked) and `<slug>.evidence/` files (fresh probes count before commit) come from the working tree.
- Exit 0 all pass, 1 any fail or stale (a probe with no verdict file fails `probeVerdictMissing`), 2 bad design
  path, bad ref, missing `claims.jsonl`, or a malformed claims line (named `file:line`). A package claim with no
  `Package.resolved` fails `packageResolvedMissing`.
- `--json`: an array of `{"id", "status"}` plus `"loc"` only when relocated; a probe with no verdict keeps its
  recorded status. Blocked: `{"message", "verdict": "BLOCKED"}`. The design skill rewrites `claims.jsonl` from it.

**`evidence find`** (`D/Evidence/EvidenceQuery.swift`, `C/Commands/EvidenceFindCommand.swift`)
- `swiftgate evidence find <query> [--pkg <name>@<ver>] [--cache-home <dir>] [--json]`.
- `EvidenceQuery.matches(_: Claim)`: case-insensitive substring over `claim.text` or `citation.quote`. `--pkg`
  splits on the first `@` and compares identity and version exactly, never a prefix; no `@<ver>` → exit 2.
- `EvidenceFindHit{id, text, status, origin: EvidenceHitOrigin(.repo | .cache(EvidenceCacheOrigin)),
  reuseCount: Int?, pin: String?, source: String}`. Cache hits use the text hash as id; `reuseCount` is nil only
  for repo hits. Sorted by `(source, id)`.
- JSON: `{command, verdict, query, pkg, hits: [{id, text, status, origin, reuseCount, pin, source}], notes,
  message}`; `origin` is `"repo"` or the cache origin's raw value. Exit 0 always ("no matches for …" when
  empty); 2 only for a malformed `--pkg` or an unresolvable `--cache-home`. Corrupt input is a note.

**Plan-lint graph and waves** (`D/Plan/PlanLintGraph.swift`), pure
- One entry point for every plan-lint family: `PlanLintGraph.allFindings(design: DesignDocument, designPath:
  String, ledger: Ledger, ledgerPath: String, graph: ModuleGraph, workerPacks: [String: ContextPack], bounds:
  PlanConfig) throws(ReportContractViolation) -> [Finding]`. `plan-lint-command` supplies the design at
  `designSha`, the decoded ledger, the loaded `ModuleGraph`, a built worker `ContextPack` for EVERY task, and
  `PlanConfig`.
- Rule ids: `plan-lint.dag-cycle`, `.missing-dependency`, `.waves-mismatch`, `.write-set-overlap`,
  `.pack-missing`, `.pack-unknown-task` (major); `.hot-file` (a path in ≥ 3 tasks), `.single-dependent-chain`
  (minor). Plus the Wave 10 coverage and sizing ids.

## Wave 13

**`probe`** (`A/Probe/ProbeBuilder.swift`, `C/Commands/ProbeCommand.swift`, `GF/probe/`)
- `swiftgate probe --design <doc> --package <dir> --target <name> [--sdk <v>] [--cache-home <dir>] [--json]`.
  Inputs are `<slug>.evidence/probes/<ev-id>.snippet.swift`; snippet ids must match `ev-[a-z0-9-]+`.
- One scratch package per worktree under `.harness/probe/`, pinned to the target's `Package.resolved`, depending
  only on products the target already uses. Local path packages are left out with a note (codebase code is cited
  by file, never probed). Never `swift-issue-reporting`; no MainActor default isolation.
- iOS targets build with `xcodebuild -skipMacroValidation` for `iphonesimulator` and a per-worktree
  `-derivedDataPath` under `.harness/probe/`; host-only packages use `swift build`. Build only: no test, no boot.
- Writes `probes/Probe_<id>.swift` (wrapper) and `probes/Probe_<id>.verdict.json` via `ProbeVerdictRecord.encode`.
- Exit 0 all pass, 1 any fail, 2 blocked (bad design path, no snippets, an unpinned dependency, an unattributed
  error, or a failed build with no diagnostics).
- JSON: `{command, verdict, design, platform, sdk, built, probes: [{claimId, verdict, cached, wrapper,
  verdictFile, diagnostics}], notes, message}`.
- Cache: `EvidenceCacheStore` bucket `sdk/<platform><ver>.jsonl`, origin `probe`. The key covers the snippet's
  sha256, deployment targets, products and traits, every `Package.resolved` pin, and the SDK. A hit runs no build.
- A recorded real iOS run against `examples/SampleApp` (TCA 1.26.2, iphonesimulator 26.2) lives in
  `FX/Probe/ios-sampleapp.{stdout,status}`: `@Reducer` snippet passes; `Effect.teleport` fails with
  "type 'Effect<Int>' has no member 'teleport'". The capture command is in `FX/README.md`.

**Mermaid validation** has fake-runner tests (`TA/MermaidValidationTests.swift`), so the `mmdc`-present path is
covered on machines without `mmdc`.

## Wave 14

**Markdown writes checked for local paths** (`C/Hooks/PostToolUseHook.swift`, `C/Commands/CommentsCommand.swift`)
- PostToolUse on a `*.md` Edit/Write/MultiEdit runs `LocalPathRule.scan` on that file (fastest-of-N < 50 ms for
  1,000 lines). Block text: "`swiftgate docs-lint` <path>: RED\n" + one line per finding, the Swift path's shape.
  Rule id `docs-lint.local-path` (major); `DocsLintPolicy.productPaths` stay allowed. Non-markdown writes unchanged.
- `comments --staged` also scans staged `*.md` (git-tracked, hand-edited only); findings merge into its result.
  No new flag.

**`plan-lint`** (`A/PlanState/PlanStateStore.swift`, `C/Commands/PlanLintCommand.swift`)
- `swiftgate plan-lint <slug> [--json]` from the repo toplevel. Reads
  `<git-common-dir>/swift-harness/plans/<slug>/{plan.json,ledger.json}` via `PlanStateStore.locate(slug:git:)`, so
  every linked worktree sees the same plan. One call to `PlanLintGraph.allFindings`.
- The design comes from `DesignAtSha.find(designSha:path:git:) -> Found{commit, text}?`: walk
  `Git.revisions(of:)` newest first, `DesignSha.strippingStatus`, `GitBlobID.of`, stop at the match. Never the
  working tree, never `Git.blobContents`.
- Worker packs are the FULL §5.10 pack per task: claims from the working-tree `<slug>.evidence/claims.jsonl`,
  standards from `docs/standards.md` plus `docs/testing-playbook.md` when present, anchors via
  `ContextPackModuleKindAnchors` for the kinds of the modules the task touches. An absent claims or standards file
  is a stderr note; a malformed claims file makes every pack `pack-missing`.
- Exit 0 clean, 1 gating finding, 2 blocked (missing or malformed `plan.json`/`ledger.json`, nil or unknown
  `designSha`, no `.swiftgate.toml`, module-graph failure). JSON is the standard `RunReport`; a blocked reason is a
  `swiftgate.environment` finding.

**Push tier runs evidence check** (`C/Commands/CheckCommand.swift`)
- `check --tier push` (not `fast`) re-checks every `approved`/`built` design's claims at `HEAD` through
  `evidence check`'s own code path (`PushDocGates.run`). Rule ids: `evidence-check.stale-claim`,
  `.status-unknown`, `.blocked` (all major: a design whose evidence can't be checked gates), `.summary` (nit:
  "N design doc(s) found, M approved or built and checked at HEAD").
- **Extension point** for the next two `CheckCommand` edits (calibration freshness; docs-lint and prose):
  `if tier != .fast { parts.findings += try await PushDocGates.run(...) }` in `CheckRun.run`, after the
  simulator-tiers block. Add sibling steps there. `Dependencies` gained `runner: any ProcessRunner`.
- One design-doc predicate: `DesignDocument.isDesignDocPath(_ repoRelativePath: String) -> Bool` (a `.md`
  directly under a path component named `designs`), used by docs-lint, known-id sources and the push tier.

**For `plugin-docs-pass-docs-lint-and-prose`:** `isDesignDocPath` counts `docs/designs/README.md` as a design;
decide whether router/README files are excluded before docs-lint and prose gate push. This repo's two designs
predate §5.3 frontmatter (status lives in a RESUME comment), so push sees them as neither approved nor built.

## Wave 15

**Artifact `db` call shape (verified from the `artifact-design` and `artifact-capabilities` skills).** The page
doesn't declare capabilities in its HTML. The publisher passes Artifact `capabilities: {"comments": {}, "db": {}}`.
In the page: `const db = await window.claude.use("db");` then
`db.collection("approval").doc(designSha).set({decision: "approve" | "request-changes", at: (new Date).toISOString()})`.
`db` can be `null` (capability not granted); the page says so instead of failing silently. **Artifacts render
Mermaid natively from `<pre class="mermaid">`: never load a Mermaid library** (a test guards it).

**`design-render`** (`D/Design/DesignRender.swift`, `D/Design/ArtifactPageShell.swift`,
`C/Commands/DesignRenderCommand.swift`)
- `swiftgate design-render <doc> [--package-resolved <path>] [--sdk <v>] [--json]` runs `design-lint` and
  `evidence check` first. Output `.harness/design-render/<slug>.html`. Exit 0 written, 1 lint gating (nothing
  written), 2 blocked. JSON: `command, verdict, design, output, designSha, capabilities, notes, findings, message`.
- `ArtifactPageShell(title:, body: HTMLFragment, capabilities: [ArtifactCapability], pageData: [String: String] =
  [:], script: String? = nil)`, with `.html` and `.capabilityDeclaration`. The ledger page reuses it.
  `HTMLEscape.escape` is the one escaper; `HTMLFragment.text` escapes. Page data reaches `<script>` only as JSON
  that escapes `</`.
- Titles shown; `req-…`/`ev-…` ids only in `data-` attributes. Every claim status has a badge that expands to its
  quote; an evidence-check result overrides the recorded status. Buttons carry the doc's `designSha`.

**`stats` design and plan metrics** (`D/Design/DesignMetrics.swift`, `C/Commands/StatsCommand.swift`)
- `swiftgate stats --design <doc> [--plan <slug>] [--cache-home <dir>] [--json]`. Every rate is `nil` ("n/a") at a
  zero denominator. Missing optional inputs are notes; a malformed file is exit 2 naming `file:line`.
- `phases.jsonl` at `.harness/runs/design-<slug>/phases.jsonl`, written by the design skill: `{schemaVersion, runId,
  phase: DesignPlanPhase, agentRole: ContextPackRole?, lane: ResearchLane?, tokens, costUSD?, wallMilliseconds}`.
  `DesignPlanPhase` = frame, research, verify, draft, review, revise, publish, amend, clarify, decompose, schedule,
  lint, index. The pre-mortem logs as `agentRole: challenger`.
- `review-log.jsonl`: `{findingId, reviewer, disposition: accepted | dismissed, reason}` (`ReviewLogRecord`).
- `ResearchLane` = codebase, apple-docs, packages, prior-decisions (matches `Claim.lane`). Escape = a `supported`
  claim whose id is in an `amend` (not `clarify`) amendment's `changedIds`.
- `LedgerTask.actualLines: Int?` (absent → nil, negative fails decoding, omitted when nil). Estimate error =
  `actualLines − estLines` per task that has it; `meanAbsoluteError = mean(|error|)`; others counted as excluded.
  Sub-project 5 writes `actualLines`.

## Wave 16

**`design-render --ledger <plan>`** (`D/Design/LedgerRender.swift`, `C/Commands/DesignRenderCommand.swift`)
- Writes `.harness/design-render/<slug>-ledger.html`. Exit 0 written, 2 blocked (nil or unknown `designSha`,
  unreadable plan state); no exit 1 (no lint step). JSON: `{command: "design-render", verdict, plan, output,
  designSha, capabilities, notes, message}`; the ledger page declares no capabilities.
- `LedgerRender.page(Input(slug:ledger:design:designSha:))` is pure. Reads the plan through `PlanStateStore` and the
  design through `DesignAtSha`; waves from `PlanSchedule` (a stored/recomputed mismatch shows the recomputed order
  plus a visible warning); gaps from `PlanLintCoverage.uncoveredIDs`, shown as text.
- DAG: a Mermaid flowchart in `<pre class="mermaid">` from `dagMermaidSource(tasks:)`, labels escaped; edges equal
  `deps`.
- `predictedOverheadShare(tasks:waves:)` = (wall − critical path) / wall; wall sums each wave's largest `estLines`,
  the critical path is the longest `estLines`-weighted chain. The spec now states this definition.

## Wave 17

Every `swiftgate` subcommand stub is now implemented. The stub-exits-2 test has no cases left and runs again if a
new stub is added.

**`calibrate design`** (`A/Calibration/`, `C/Commands/CalibrateCommand.swift`)
- `swiftgate calibrate design [--model <m>] [--json]` (default model `sonnet`) runs each `agents/design-*.md` agent
  on its seeds through the Foundation judge's Claude CLI runner. Exit 0 all labels met (writes
  `gate/Fixtures/calibrate-design/last-pass.json`), 1 a miss or seed defect (record bytes untouched), 2 claude or
  IO failure. Every design agent must have seeds and every seed dir must name an agent. Enforces nothing at push
  yet: `calibration-seeds-labelled-by-construction` seeds the cases and wires freshness.
- Case layout: `gate/Fixtures/calibrate-design/<agent-stem>/<case>/input.md` + `label.json`
  `{"schemaVersion": 1, "questions": [{"id", "text", "options": [≥ 2 distinct], "expected"}]}` (README in that dir).
- `CalibrationRecord{schemaVersion: 1, contentHash, hashedFiles, model, passedAt, cases: [{agent, case, answers:
  [{question, expected, answered, probability}]}]}`; decode with `.decode`.
- Hash: `DesignCalibrationHash.hash(discover(root:))` = sha256 over sorted `<path>\0<sha256>\n` lines of
  `agents/design-*.md` + `workflows/design-*.js`; `isHashed(path)`. Edits and renames change it; order doesn't.

**Research lane agents** (`agents/design-lane-{codebase,apple-docs,packages,prior-decisions}.md`)
- `model: sonnet`, tools Read/Grep/Glob only (no Bash). Cache hits and same-pin claims arrive in the context pack;
  lanes Grep `claims.jsonl` rather than run `evidence find`. Grep/Glob must target `.build/checkouts/<pkg>` directly,
  because a search from the repo root skips gitignored paths.
- Return `{lane, claims: [§5.2, status "new"], probes: [{claimId, swift}], needsDecision: [{question, options[2–4],
  recommendation, evidence[]}]}`; `lane` values match `ResearchLane`.
- `tests/design_agents_test.mjs` checks EVERY `agents/design-*.md`: `name` = file stem; `description`; `model` in
  sonnet/opus/haiku/fable; `tools` only Read/Grep/Glob unless `toolExceptions: <Tool> — <reason>`; no relay or proxy
  agent types. Each agent registers `{prefix, keys, strings}` in the test's `CONTRACTS`; an unregistered
  `design-*.md` fails.
- `claude plugin validate .` at the repo root only validates the marketplace manifest. Until packaging, validate
  a plugin-shaped copy with `--strict`.

**`workflows/design-research.js`**
- Args `{tier: quick|standard|deep, mode: research|reresearch, claimIds?, lanes: [{name, packPath}], answers:
  [{question, answer}]}`; `answers` required (`[]` first); `reresearch` takes exactly one lane. Errors:
  `InvalidArgsError`, `UnknownModeError`, `UnknownTierError`, `TooManyLanesError`, `MissingClaimIdsError`,
  `MissingPackPathError`, `UnknownLaneError`, `DuplicateLaneError`. Agent type `swift-harness:design-lane-<name>`.
- Returns `{schemaVersion: 1, status: complete|needs-decision|incomplete, tier, mode, claimIds?, lanes: [{lane,
  status: researched|needs-decision|not-researched, claims, probes, needsDecision} | {lane, status, reason}],
  needsDecision: [{lane, question, options, recommendation, evidence}], unusedAnswers}`. ≤ 3 lanes in flight.
- On `needs-decision`, the design skill asks the user, then relaunches with the same `scriptPath` and args plus
  `resumeFromRunId`, carrying every answer so far. An answered lane replays its first call from cache and makes one
  follow-up call with the answer; other lanes' prompts stay byte-identical.

## Wave 18

**`workflows/design-review.js`**
- Args `{tier, packs: [{reviewer, packPath}], reviewers?: […], previous?: <prior return>}`. In a revise round,
  `packs` lists only the reviewers being re-run; the others' results carry forward from `previous`. `quick` runs no
  reviewers (§8.1). All reviewers run at once (≤ 4). Errors: `InvalidArgsError`, `UnknownTierError`,
  `UnknownReviewerError`, `DuplicateReviewerError`, `ReviewerNotInTierError`, `MissingPackPathError`,
  `MissingPreviousResultError`.
- Each reviewer pipes into an independent `swift-harness:verifier` call. The reviewer schema has no `verified`: a
  reviewer's `verified`/`verification_note` is stripped, and the verifier decides both. Verifier death makes that
  reviewer's findings `not-reviewed` ("verifier failed; findings unverified").
- Return `{schemaVersion: 1, tier, status: complete|incomplete, ran, carried, reviews: [DesignReviewJSON
  envelope]}`. The skill writes each `reviews` entry to its own file and passes them to `review-synth --design`
  (checked end to end against the real binary).
- Agent types: `swift-harness:design-{evidence-auditor, standards-conformance, challenger, pre-mortem}`. The
  standards agent is `standards-conformance` but reviews as `standards-reviewer`.
- `agents/verifier.md` is written for code findings; the workflow prompt adapts it to design anchors until the
  agent file gains a design section (added to `design-review-agents`).

**`skills/prose/SKILL.md`** (`/swift-harness:prose`)
- Mirrors `swiftgate prose`: every rule id with what it flags, the fix, and a before/after; ceiling from
  `[docs] sentence_ceiling` (default 40). Runs `"$SG" prose <file>` with `SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`
  and rewrites rather than argues. The drafter loads it before `design-lint`.
- `ProseSkillTests` fail if a rule id or the ceiling drifts, or if the skill fails its own rules.
- Skills must avoid `[A-Z]\d` tokens: `RuleAnchorTests` reads them as rule citations.

## Wave 19

**Design reviewer agents** (`agents/design-{evidence-auditor, standards-conformance, challenger, pre-mortem}.md`)
- `opus`, read-only. Output `{findings: [{location: {anchor}, severity, category, title, failure_scenario, evidence,
  fix, kind, rule}]}`, no `verified`; anchors are `RequiredSection` values. The test reads the reviewer schema from
  `workflows/design-review.js`, so the two can't drift.
- Challenger questions: best end-to-end, not merely complete; biggest blind spot; hardest requirement shown or only
  asserted; what the rejected option does better; simplest sufficient design; where runtime failure surfaces and
  which test fails first; costliest decision to reverse.
- No `pre-mortem` context-pack role exists (§5.10 lists none). **The design skill passes the pre-mortem the
  challenger's pack** (the doc).
- `agents/verifier.md` has a design-findings section: location is a section anchor, verified against the design
  text and the pack's cited claims.

**Single-step agents** (`agents/design-{claim-checker, drafter, decomposer}.md`), `opus`, Read/Grep/Glob only
- Claim checker: takes the claim-checker pack path; judges only `quote-ok` claims; returns `{verdicts: [{id, status:
  supported|refuted, reason}], skipped: [{id, reason}]}`.
- Drafter: takes the drafter pack, doc path, area, tier, today's date, the prose skill path and, when revising,
  findings. Follows `templates/design-doc.md` section order, cites `supported` claims only, uses the
  ` — tier T<n>` test-plan syntax, and returns only the doc text.
- Decomposer: takes the decomposer pack, plan slug and repo name. Returns `{tasks: [LedgerTask without actualLines,
  status "pending"], unresolved: [{ruleId, task, reason}]}`; gets exactly one fix round with `plan-lint` findings.

A test that runs a real `swiftgate` binary must set `cwd` and `LLVM_PROFILE_FILE` to a temp dir: under the push
tier's coverage build the binary otherwise leaves `default.profraw` in the checkout.

## Wave 20

**`skills/design/SKILL.md`** (frame → research → verify → draft; `references/frame-research-verify.md`)
- Reads the session id from the SessionStart line `Session id: <id>` and runs
  `plan claim <plan> --session <id> --design <doc>` at frame.
- The claim checker runs at every tier, quick included: without it no non-probe claim reaches `supported`, and
  every quick Decision bullet would fail design-lint. The spec's §8.1 tier table now says so.
- At draft, `docs-lint`'s `unreachable-doc` and `requirement-uncited` findings on the new doc are tolerated against
  a frame-time baseline: nothing links or cites the doc before publish.
- Frame answers are claims with lane `prior-decisions`.
- **Seam for review/publish/amend:** the "Where the draft leaves things" section in SKILL.md, plus a new
  `references/review-publish-amend.md`.

**`skills/plan/SKILL.md`** (`references/state-files.md` holds the JSON shapes and `phases.jsonl` records)
- The claim check is `plan claim` exiting 0 for this session. Approval must match `designSha` directly or through
  `design-diff --chain`. `evidence check --design --at HEAD` runs first; non-zero halts and asks.
- The skill writes shared `plan.json`/`ledger.json` with the Write tool as the plan's lock holder (spec §3.2: `/plan`
  writes them; the edit guard allows the holder). Drafts go to `.harness/plan-draft/<slug>/` and are validated by
  `plan-schedule` and `plan-lint`, which decode strictly, before the shared files are written. Run ids are
  `plan-<UTC>`.

**`tests/skill_commands_test.mjs`** scans every `skills/**/*.md` (inline code, fences and prose) for
`swiftgate`/`"$SG"` calls and checks each subcommand path against `--help`'s `SUBCOMMANDS:` list and each flag
against that subcommand's help. A later skill that names a missing command or flag fails it.

**Open items raised here:**
- No command dumps the module graph, so the design and plan skills each build `module-graph.txt` themselves
  (with `swift package describe`). Two copies of one procedure; a `swiftgate` command would replace both.
- `docs-lint.requirement-uncited` at quick tier: a quick design has no ADR, so its requirements may never be cited
  outside it. Decide before `plugin-docs-pass-docs-lint-and-prose` makes docs-lint gate push.

## Wave 21

**`skills/design/SKILL.md` review → publish → amend** (`references/review-publish-amend.md`)
- Review: per-reviewer `context-pack` packs (the pre-mortem gets the challenger's), `design-review.js`, each
  `reviews` entry to its own file, `review-synth --design --tier <tier>`; one revise round (2 at deep) re-running
  only reviewers with gating findings. `review-log.jsonl` `findingId` = `<design-run>/review-<r>/<n>`.
- Publish: `design/<slug>` branch, status `proposed`, `design-render`, then Artifact publish with `capabilities
  {"comments": {}, "db": {}}`; approval read with `ArtifactData get` (collection `approval`, `doc_id` =
  `designSha`); `--revise` uses `ArtifactComments` read/reply/resolve. Status `approved` only with an approval
  record for the current `designSha`; then merge and add the area router row.
- On approval the skill writes `approval` `{decision, designSha, at}` into the plan's `plan.json`, so a clarify made
  before `/plan` still has a chain start. With no `db`, approval goes through `AskUserQuestion` and becomes an
  `answer` claim quoting `at designSha <sha>`.
- `unreachable-doc` is tolerated only until publish. A `quick` design keeps tolerating `requirement-uncited` (open
  item).
- `--amend` delta review carries the challenger forward from `.harness/runs/design-<slug>/review-final.json`;
  without that file it runs the full review. A `stale` claim spawns a one-claim `reresearch` lane.
- Seeds should drive a revise → ready round and a clarify → `design-diff --chain` valid case.

## Between waves 21 and 22: closed plan-file types

- `PlanFile.Approval.decision` is `PlanFile.ApprovalDecision` (`approve`, `request-changes`); `PlanFile.tier` is
  `DesignTier?` (`quick`/`standard`/`deep`). An unknown value fails decoding; `PlanFileJSON` output is unchanged
  byte for byte. `PlanFile.tiers` is gone: parse with `DesignTier(rawValue:)`.
- `DesignRender`'s approval buttons and page JS take their decision strings from `ApprovalDecision.rawValue`.
- `tests/skill_commands_test.mjs` joins ` \` continuation lines inside fenced blocks before checking flags, so a
  flag on a wrapped line is checked against its command.

## Wave 22

**Calibration seeds and freshness** (`gate/Fixtures/calibrate-design/`)
- Seeds are `<agent>/<case>/{input.md,label.json}`, each defect paired with a clean twin. `last-pass.json` (a
  `CalibrationRecord`) is committed from a live `swiftgate calibrate design` run: 23/23 cases, 11 agents, sonnet,
  about 2.5 min.
- `CalibrationFreshness.run(root:)` runs on the push and ready tiers, not fast. The rules
  `calibration-freshness.{stale,no-record,unreadable}` are major and `.summary` is a nit. The hash covers
  `agents/design-*.md` and the design workflows, not seeds. Editing either means rerunning `calibrate design` and
  committing `last-pass.json`, or push and `committedRecordIsFresh` go red. A repo with no design agents skips it.
- The Claude judge passes `--settings '{"verbose":false}'`, so a global `verbose: true` can't turn
  `claude -p --output-format json` into an event array.

**`swiftgate self-test` seed runner** (`gate/Fixtures/seeds/<command>/<case>/`)
- `expected.json` is closed: `{"schemaVersion":1, "verdict":"red"|"green", "ruleIDs":[String]}`. `ruleIDs` is
  sorted, unique and non-empty, and empty exactly when the verdict is green. An unknown key or value fails with a
  named reason, and a case without `expected.json` is a hygiene failure.
- Each family keeps its inputs in the case directory:
  - evidence-check: `docs/example/designs/seed.md` + `seed.evidence/claims.jsonl`
  - probe: `probes/<ev-id>.snippet.swift`, built against `gate/Fixtures/probe/HostTarget`. A probe case's
    `ruleIDs` are the failing claim ids, since that's what `probe` reports.
  - design-lint: `design.md`, plus an optional `design.evidence/`
  - design-diff: `revisions/1.md` and `2.md`; the runner builds a temp repo and `plan.json`.
- A new command family means a case in `SelfTestCommand.swift`'s private `SeedFamily` enum and `SeedRunners`;
  the seeds themselves are data. Each family has a `valid` (green) case.
- `design-lint.section-word-budget` now reaches nested sections; before, a doc's `#` title hid every `##` section
  from it.

## Wave 23

**Docs gates on push** (decided 2026-09-25)
- Push runs `docs-lint` over the whole corpus, and `prose` over gated docs counting only lines added since the
  merge base with `origin/main`. The fast tier runs neither. New rules: `docs-lint.blocked` and `prose.blocked`
  (major) and `prose.summary` (nit).
- `[docs] prose_exclude = [globs]` is skipped by prose and every word-budget check. Reachability, links and ids
  still cover those files. `[docs.budgets.files]` maps a path to its own word budget. Both are repo config only:
  code defaults and `templates/swiftgate.toml` stay strict for consumer projects. This repo excludes
  `docs/plans/**`, `docs/handoffs/**`, `agents/**` and `skills/**`, and budgets its long reference docs near their
  current size. A plain `swiftgate prose <file>` ignores `prose_exclude`.
- `docs-lint.requirement-uncited` skips a doc under `designs/` whose frontmatter says `tier: quick`. A missing or
  unknown tier stays major, and the message names an unknown tier.
- `docs-lint.dangling-id` counts only ids `IdPolicy.isValid` accepts that start their own token, so `test-first`
  and the tail of `self-test-…` no longer count.
- The local-path rule scans code spans too, so a doc that describes it names path kinds rather than literal paths.
- A test that runs push in a temp dir must `git init` there: push's `docs-lint` needs git.

**Self-test seed families** `plan-lint`, `docs-lint`, `prose`, `comments` and `testlint`
- `SeedRepo` (in `SelfTestCommand.swift`) builds a canonical-path throwaway git repo with `git`, `write` and
  `seedKnownID(_:slug:)`. Reuse it for any seed that needs git.
- `plan-lint/overlapping-wave` yields both `write-set-overlap` and `waves-mismatch`: the scheduler never groups
  overlapping write sets, so stored waves that do also diverge from the recomputed schedule.

## Wave 24

**The plugin ships from `plugin/`** ([ADR 0002](../adrs/0002-consumer-plugin-in-plugin-dir.md))
- Moved from the root into `plugin/`: `.claude-plugin/plugin.json`, `skills/`, `agents/`, `hooks/`, `workflows/`,
  `templates/`, `bin/`, `gate/` and `docs/{standards,testing-playbook,hooks}.md`. The root keeps
  `.claude-plugin/marketplace.json` (`source: "./plugin"`), `AGENTS.md`, `docs/`, `tests/`, `examples/` and `evals/`.
  The root `bin/swiftgate` is gone: run `plugin/bin/swiftgate`, and seed a worktree's cache from
  `plugin/gate/.build`.
- The review verdict contract consumers read at runtime is `plugin/docs/review-contract.md`.
- The shim's cache order is `SWIFTGATE_CACHE_DIR`, then `CLAUDE_PLUGIN_DATA`, then the user cache.
  `SWIFTGATE_HARNESS_ROOT` is `plugin/`. Bootstrap repoints an existing `~/.local/bin/swiftgate` at
  `plugin/bin/swiftgate`, whether or not the old target still exists.
- The ready tier runs `claude plugin validate --strict plugin` when `claude` is on PATH. The rules are
  `plugin-validate.failed` (major), and `.not-run` and `.summary` (nits).
- `tests/plugin_boundary_test.mjs` fails when a file under `plugin/` references a path above `plugin/`.
  `RepositoryConfigPathsTests` fails when a `[docs.budgets.files]` key, a `prose_exclude` glob, `managed_files` or
  a calibration glob matches no file.
- `last-pass.json` was regenerated live after the move: 23/23 cases, 11 agents, 148 s.
- `plan-lint` reads the repo's own `docs/standards.md` when it has one, else the harness root's copy. With neither,
  it's a named failure.
- `self-test --sample-app <dir>` points the sample-app seeds at another checkout. Prove now reverts a renamed source
  to its old content at its new path.
- The dead worktree-relative `.harness/plans` guard rule is still there. Deleting it drops `isOrchestrator` from
  `EditGuard.evaluate`, and prove needs that removal in its own change. Open item.
- The merge commit records 4 `prove.not-proven` tests whose only edit is the checkout-root repoint to
  `Fixture.harnessCheckout`: `packageDiscovery`, `fixtureMatchesRealDescribe`, `repositoryDocsPassDocsLint` and
  `retries`. The user accepted them.
- `.swiftgate.toml` excludes `evals/corpora` from the gate, and `evals/cases/**`, `evals/sessions/**` and
  `evals/corpora/**` from prose.

## Wave 25

**Consumer steering** ([ADR 0002](../adrs/0002-consumer-plugin-in-plugin-dir.md), Steering)
- Claude Code sets both `CLAUDE_PLUGIN_ROOT` (the plugin dir) and `CLAUDE_PLUGIN_DATA`
  (a per-plugin data dir under the user's Claude config) in plugin hook processes; this was observed with
  `claude -p --plugin-dir`. The shim needs no `SWIFT_HARNESS_PLUGIN_ROOT` fallback.
- SessionStart adds one line: `Plugin reference docs: <abs dir> (…)`, where the path ends at the first space. It's
  emitted only when `<dir>/standards.md` exists. Otherwise the line is `Plugin reference docs unavailable: <reason>. …`.
  In code: `SessionContext.ReferenceDocs { found(directory:), unavailable(reason:) }`, optional
  `Inputs.referenceDocs` (nil renders nothing). `SessionStartHook.referenceDocs(environment:)` reads only
  `CLAUDE_PLUGIN_ROOT`, and it must be absolute.
- The stamped `AGENTS.md` names "the plugin reference docs (path in your session context)" and never an absolute path.
  `plugin/docs/index.md` is the consumer router for `standards.md`, `testing-playbook.md`, `review-contract.md`
  and `hooks.md`.
- `ConsumerSteeringTests.shippedPluginHasNoContributorDocLeaks` scans
  `plugin/{skills,agents,workflows,templates,docs,hooks}`. It flags relative links and `${CLAUDE_PLUGIN_ROOT}` paths
  that resolve into the repo-root `docs/{designs,adrs,plans,handoffs}`. Bare `docs/designs/` strings pass.

**Contributor AGENTS.md**
- The root `AGENTS.md` is a 50-line contributor guide. Nothing automated enforces "AGENTS.md names no app-only
  rule", which stays a review item.

## Wave 26 (rehearsal)

**Marketplace install, unattended rehearsal** (evidence in `docs/e2e-report.md`)
- Install from the consumer repo: `claude plugin marketplace add <harness checkout> --scope project`, then
  `claude plugin install swift-harness@<marketplace> --scope project`. Project scope still writes
  `plugins/known_marketplaces.json`, `plugins/installed_plugins.json` and `plugins/marketplaces/` under the user's
  Claude config, so a rehearsal removes its own entries afterwards. A directory marketplace loads the plugin from
  the checkout, so checkout edits apply without `claude plugin update`.
- Live subagent PreToolUse payload fields: `session_id`, `transcript_path`, `cwd`, `prompt_id`, `permission_mode`,
  `agent_id`, `agent_type`, `effort`, `hook_event_name`, `tool_name`, `tool_input`, `tool_use_id`. A subagent's
  payload carries the main session's `session_id`; only `agent_id`/`agent_type` tell it apart, and main-session
  payloads have neither. `guard.plan-state` denied a subagent's writes to the ledger, design doc and `claims.jsonl`.
- Every plugin agent is read-only, so a guarded-write test uses a `general-purpose` subagent.
- Headless flags that worked: `--setting-sources project,local`, `--session-id` equal to `plan claim --session`,
  `--output-format json --verbose`, `SWIFTGATE_HOOK_RECORD_DIR`. The temp consumer repo needs a local bare `origin`,
  or Stop reports BLOCKED. Warm the gate first with `plugin/bin/swiftgate --version` under the install's
  `CLAUDE_PLUGIN_DATA`, because the first call builds cold (about 2 min).
- The `status` skill reads `<git common dir>/swift-harness/plans/index.json`, and a plan is active unless
  `PlanStatus.isFinished`. `tests/plan_state_paths_test.mjs` fails on the old `.harness/plans` path.
- `docs/e2e-report.md` has a word budget in `.swiftgate.toml` (2600 now); each new section raises it.

## Wave 27 (rehearsal)

**A probe refutes a nonexistent API, unattended rehearsal** (evidence in `docs/e2e-report.md`)
- The claim that `@PersistedState` exists at TCA 1.26.2 ended `refuted` from a failing probe and never reached
  Decision. Putting it into Decision turns `design-lint` RED (`citation-not-supported`).
- The design skill in a headless session (`claude -p`, which has no `AskUserQuestion`) ends the turn with at
  most 4 numbered questions in the "Headless" shape of `references/frame-research-verify.md`. It writes and
  claims nothing until the answers come back with `claude -p --resume <session id> "<answers>"`. Answers are
  recorded exactly like `AskUserQuestion` answers.
- A premise the request names (an API, a type, a behaviour) is never checked before research. It goes into the
  `packages` brief (the `codebase` brief at `quick`), and verify's probe decides it.
- `context-pack --role research-lane --pin` picks the reuse-cache bucket through `ResearchLanePin`: `<pkg>@<ver>`
  reads the package bucket, a 40- or 64-hex commit reads nothing (codebase claims are never cached), and any
  other pin reads the SDK bucket. That last case is a catch-all, noted for review. Each lane writes its own pack
  file.
- `docs-lint` resolves `ev-` tags against each design doc's `claims.jsonl`. A design with no claims file leaves
  its tags dangling; an unreadable one blocks.
- Open, for the sub-project review: a trailing `[UNVERIFIED].` doesn't match its Risks line; the gitignore
  template doesn't cover `.harness/design-render/`; `docs-lint` didn't flag the new design doc as unreachable or
  uncited.
- The `docs/e2e-report.md` budget is 4000 words.

## Defect fix: Bash writes go through the file guards

- `ShellSyntax.writeTargets(in:) -> [ShellWriteTarget]` (`path`, `entries`, `isDirectory`). Targets come from
  redirections, `tee`, the `cp`/`mv`/`install`/`ln` destination (and `mv` sources), the operands of `rm`/`truncate`/
  `touch`, `dd of=`, and `sed -i`/`perl -i` files. `SimpleCommand.redirectTargets` is new.
- `PreToolUseHook.writeViolation(_:payload:root:dependencies:) -> GuardViolation?` is the single judgment of a
  write, for file tools and Bash alike. A Bash deny reason starts with "this command writes `<path>`.".
- Known limits (in `plugin/docs/hooks.md` § Bash writes): interpreter code, heredoc text, `eval`, `$VAR`/`$(…)`
  targets, and a recursive delete of a guarded directory's parent. The evals hook corpus caught 19/21 evasions
  after the fix (12/21 before); the two misses are documented limits.
- Open for review: a Bash or Write to a design doc costs about 100ms because it spawns git, while hooks.md budgets
  PreToolUse at < 50ms. `LiveProcessRunnerTests.timeoutKillsChild` flakes under heavy load (load average 50+) and
  blocked one mutate baseline.
