# Sub-project 2 brainstorm — locked decisions (input to the spec)

<!-- RESUME
State (2026-09-25): brainstorm in progress. Locked D1–D24 below (D11 amended by D19). Brainstorm COMPLETE. Next: write spec to
docs/designs/2026-09-25-design-plan-workflows-design.md, self-review, user review, writing-plans.
Spec must also fix Foundation spec §2 row 2 (`.harness/ledger.json`, "ledger canonical in git") — superseded by D11/D12.
-->

## Verified facts (open items from the handoff)

- Workflow `agent()` can't block for a reply mid-run; script API has no pause primitive. Escalation = return early
  with `needsDecision[]`, ask, relaunch with `resumeFromRunId` (unchanged agent() prefix replays from cache).
- Scripts have no filesystem/network; only the main session can publish Artifacts. Approval via page `db`
  capability (read back with `ArtifactData`), comments via `comments` capability (`ArtifactComments`).
- Ledger guard: `Guards.swift` `OrchestratorMarker.isOrchestrator` — any `agent_id` → not orchestrator; else env
  `SWIFT_HARNESS_ORCHESTRATOR=1`; else `.harness/orchestrator.lock` == session id. Protects plan `ledger.json` + `index.json`.
- Reusable: `ResolvedPins.parse` (Doctor.swift) + `HarnessFiles.resolvedVersions` for pins; `SessionContext.swift`
  reads `index.json {plans:[{slug,status,resume}]}`; `plan-lint` not implemented.

## Decisions

- D1 Approach A: skill-sequenced phases; two small workflows (`design-research.js` ≤4 agents, `design-review.js` 3);
  deterministic swiftgate gates between; escalation by halt/ask/resume at phase boundaries.
- D2 Models: native `sonnet` for research lanes + probe authoring; native `opus` for claim checker, drafter, reviewers,
  decomposer. Plugin never names relay agent types.
- D3 Claim schema `{id,lane,text,citation{kind,loc,pin,quote},status}`; kinds file|snapshot|capture|probe|answer.
  Deterministic `swiftgate evidence check` (quote ⊂ cited lines; pins match Package.resolved; snapshot has quote;
  capture hash matches). Package docs cited from `.build/checkouts/<pkg>` at the pin, not web. Apple doc snapshots back
  semantics only; API existence/signature needs a probe. Opus claim checker judges only `quote-ok` claims.
- D4 `swiftgate probe`: one scratch package pinned to Package.resolved, one file per probe wrapped in
  `enum Probe_<id>`, built once (xcodebuild iOS sim w/ -skipMacroValidation, or swift build host), reused DerivedData,
  per-probe verdict from diagnostics.
- D5 `design-lint`: Evidence/Decision/Perf sections are bullets, each tagged `[C-xxx]` or `[UNVERIFIED]`; cited ids
  must be `supported`; UNVERIFIED must appear in Risks/Open questions. Prose sections not sentence-linted.
- D6 Review: evidence auditor · standards conformance · challenger (plugin-owned `agents/design-challenger.md`, a
  port of self-reflect's questions — not a dependency on the personal skill). §9.1 finding contract, location =
  section anchor. Design verdicts `ready · revise · rethink`. One revise round (re-run only blocker-raising
  reviewers); survivors → AskUserQuestion.
- D7 Approval: Artifact with `comments` + `db`; Approve/Request-changes writes `{decision, designSha, at}`.
  `--revise` pulls comments (questions → replies; change requests → redraft round, republish same URL).
- D8 Design drift: workers can't edit design/evidence/amendments (extend guard); report `design-conflict` in
  task-status with cited evidence. `/design --amend`: amendment record, evidence+probes on new claims, 2-agent delta
  review. `swiftgate design-diff` classifies: touches R*/Decision/Module kinds/Test plan → **amend** (re-approval,
  new sha); else **clarify** (auto-apply + changelog; approval valid via re-verifiable clarify chain). Only tasks whose
  `covers` intersect changed R*/TP* pause (`needs-replan`); completed tasks immutable → fix tasks.
- D9 Staleness: `evidence check --at <ref>` — same lines ok / moved-in-file auto-relocate / gone → stale; pin or SDK
  change → stale. Runs at /plan start and each wave boundary, and at pre-push over merged designs. Stale claim →
  targeted re-research lane → amend or clarify.
- D10 Reuse: user-level `~/.swift-harness/evidence-cache/<pkg>@<ver>.jsonl` (package claims immutable per pin),
  cross-repo; claim-checker verdicts cached by (text hash, quote hash); snapshots/probes cached per SDK. Codebase claims
  not cached. Tombstones on refute/amend; entries carry origin + reuse count.
- D11 Durable vs ephemeral: design doc + ADR + evidence committed (via `design/<slug>` branch → PR; Artifact approval
  merges it). Ledger, plan.json, index.json, task-status are NOT committed — location per D19 (git common dir). `gc` never touches plans. No plan branch.
- D12 Design shape: `docs/<area>/design/<slug>.md` (template-linted, `<slug>-R*` / `<slug>-TP*` ids) + `decisions/NNNN-*.md`
  ADR + area router row; evidence alongside. Adopts the Owner subsystem doc layout (router "If you're → Read",
  per-topic files, AGENTS.md entry pointer + CLAUDE.md symlink, decisions/). Quick tier = single-doc exception.
  Note (2026-09-25): D12's paths are now `designs/` and `adrs/`, matching the plugin repo's own layout.
- D13 `swiftgate docs-lint` now, generic families: reference integrity (ids, ADR links, register rows cited), relative
  links, router reachability / managed files, non-vacuity, banned phrases with reasons; repo-specific anchors optional
  config. Seeded self-test. Design status frontmatter proposed → approved → built → superseded-by.
- D14 Depth tiers quick (2 agents) / standard (~9) / deep (~12: + pre-mortem, per-option probes, 2 revise rounds).
  `swiftgate design-scope` recommends; quick not offered for new module kind or new dependency. Mechanical checks
  run at every tier.
- D15 Plan: ledger schema (tasks id/deps/writeSet/gate/tests/covers/estLines/status/worktree; waves). Write sets =
  exact paths or `/`-terminated prefixes. `plan-schedule`: Kahn layers + greedy split on overlap, tie-break by id,
  width cap `[plan] max_parallel` default 3. `plan-lint`: acyclic, deps exist, gate ≥ tests' tier, disjoint per wave,
  waves == recomputed, every R*/TP* in design at designSha covered (read from design, not ledger copy); hot-file
  warning. Decomposer = one opus Agent-tool subagent, one SendMessage fix round. Worktrees named, created by sub-project 5.
- D16 Task size: unit = one module's vertical slice turning ≥1 TP green. Error: estLines > 400, > 2 modules
  (interface+live pair only), > 6 TPs, or context pack over budget. Warning: estLines < 40 or single-dependent
  same-module chain. Bounds in `.swiftgate.toml [plan]`; stats reports estimate error + overhead share.
- D17 Context engineering: slice never summarise — `swiftgate context-pack` builds verbatim, anchor-selected inputs per
  role (lanes, drafter, reviewers, workers). Worker pack budget default ~15k tokens, hard fail in plan-lint. Fresh
  agents per phase; one SendMessage continuation max. Auto-loaded context budgeted (AGENTS.md ≤ 60 lines; SessionStart
  injection capped). Tokens per agent/phase + pack size recorded in stats.

- D18 Id policy — ids are machine keys, never reader words. Committed items use descriptive kebab ids from titles
  (`req-…`, `test-…`, `ev-…`; prefix + ≥3 words; repo-unique; no `<slug>-R1` namespacing). ADRs keep NNNN but every
  reference carries the title. Local ids (tasks, waves, amendments) never leave the ledger. `swiftgate comments` +
  `testlint` + commit-msg check reject known ids (deterministic list from ledgers/evidence/docs) and codename patterns
  (`[A-Z]{1,3}\d+[a-z]?`, Phase/Stage/Wave N) in comments, test names, commit messages. Harness never mints codenames.
  Motivation: MDS docs/code accumulated opaque slugs (OB-xx, SH5, KO01, PR2a) — don't repeat.
- D19 Shared state lives in `$(git rev-parse --git-common-dir)/swift-harness/plans/` (index.json, ledgers, plan.json,
  per-plan `orchestrator.lock`). Shared by all worktrees, never committed/copied, survives `git clean -fdx`.
  Per-worktree `.harness/` (gitignored) keeps runs, derived-data, hook-state, task-status.json, context pack.
  Foundation edits in scope: SessionContext + Guards resolve via common dir, guard matches resolved absolute paths,
  lock per plan (a session may write only its own plan's ledger). Bootstrap drops `.harness/plans/` gitignore.
  Reason: gitignored files are never copied into `git worktree add` checkouts; Foundation resolves paths per worktree.

- D20 Proving it catches lies: (1) mechanical seeds in `swiftgate self-test` — forged quote, wrong file, wrong pin,
  tampered capture (evidence check); fabricated API + wrong signature (probe); untagged Decision bullet, citation to
  refuted claim, UNVERIFIED not in Risks (design-lint); uncovered req, cycle, overlapping wave, hand-edited waves,
  oversize task, over-budget pack (plan-lint); req-line edit posing as clarify (design-diff); dangling id, bare ADR
  number, unreachable doc, vacuous anchor (docs-lint); id/codename leak (comments/testlint). (2) Agent calibration
  seeds labelled by construction (overstated claim vs genuine quote → claim checker; decision contradicting evidence →
  auditor; UIKit in Core → standards; option on probe-refuted API → challenger/auditor). Precision from the user's
  Request-changes / dismissed findings log. `swiftgate calibrate design` REQUIRED at pre-push when
  agents/design-*.md or workflows/design-*.js changed since last recorded pass; else skipped. (3) E2E acceptance:
  real plugin install; standard /design → /plan on a real SampleApp feature; a second run naming a nonexistent API
  must end refuted/UNVERIFIED, never in Decision. Metrics: refute + UNVERIFIED rate per lane, probe fail rate, cache
  hit rate, cost/wall per phase, **escape rate** (supported claims later disproved by amendment).

- D21 Artifacts are visual-first: `design-render` builds views (diagrams, comparison tables, evidence badges, DAG,
  wave timeline, coverage matrix), prose only where a diagram can't carry it.
- D22 Repo design docs use Mermaid: template Architecture section needs ≥2 mermaid blocks; Mermaid is the single
  source for repo + Artifact; syntax validation only when `mmdc` is installed.
- D23 Concise docs by prose word budgets (`[docs.budgets]`, whole design ~1,200 words default); enforced by
  design-lint and docs-lint.
- D24 Plugin-owned `prose` skill + `swiftgate prose` linter, written fresh (user's wordsmith lives in a company repo
  with no licence; same precedent as comment-audit). Drafter applies it before design-lint.

- D25 Docs use relative repo paths, never machine paths. `LocalPathRule` runs at write time (PostToolUse on `*.md`,
  < 1s), at pre-commit (`comments --staged`) and in docs-lint. Evidence `loc` must be repo-relative. Allowlist:
  the harness's own product paths (`~/.swift-harness/`, `~/.local/bin/swiftgate`).
- D26 Contributors and consumers are split ([ADR 0002](../adrs/0002-consumer-plugin-in-plugin-dir.md)): `plugin/` is what ships, via marketplace `source: "./plugin"`;
  the repo root is contributor space. The shim builds into `${CLAUDE_PLUGIN_DATA}`. `claude plugin validate plugin`
  joins the ready gate. Lands as a packaging wave before the first real install.

## Perf/scale notes (to carry into spec)

~0.6–1M subagent tokens per standard design (estimate from Foundation review: 6 agents ≈ 452k). p99 wall ~10–15 min,
dominated by cold probe build. ≤3 concurrent agents per phase; no machine-wide agent cap exists (only sim cap).
Dead lane → `NOT RESEARCHED`, design can't be `ready`. Plan branches no longer exist (D11) so the index.json-on-main
race is gone; index.json writes still go through `swiftgate index set` with a FileLock (concurrent local sessions).
