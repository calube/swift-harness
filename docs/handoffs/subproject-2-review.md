# Sub-project 2 sign-off review (2026-09-26)

A read-only Workflow review of main at 74c290f: 4 dimension reviewers (spec conformance, gate correctness and security, consumer experience, test integrity), each finding adversarially verified, then a synthesis into fix waves. The orchestrator drives the waves below through the runbook's wave loop. Decisions that belong to the user are listed at the end and aren't acted on.


### Verdict

Sub-project 2 isn't excellent yet. It is close in its mechanical core, but three user-facing flows are broken. The solid parts: every §6.1 command exists, the §12 seed families are present, the calibration record is fresh, the plan-lint rules match §9.2 and §9.3, claims are taken atomically, and research concurrency is capped. Here is what stands between it and sign-off:

- **One blocker.** design-lint can never flag a `req-`/`test-` id that another design doc already defines. The unit test misses this because it skips the command's wiring, so the §5.1 "unique repo-wide" promise fails.
- **The flow breaks across sessions.** The design session never releases its plan claim, and resume and approval never take one. So `/swift-harness:plan` in a new session is refused, and so is resuming approval tomorrow. That includes the planned §13 headless acceptance run. After an amend, the flow sends the user to a `/plan` that halts on any task that isn't `pending`.
- **The guards have holes.** Any session or subagent can do three things the edit guard forbids:
  - release another session's lock (`--force`, or the holder's printed id),
  - rewrite the index,
  - co-own another plan's design doc.

  `git checkout`, `git rm` and `git restore` get past the subagent write guard. Nested projects can't satisfy the guard and the other commands at the same time.
- **plan-lint is too lenient.** It stays GREEN when the design moves past `designSha`. It also stays GREEN when a T3 test sits in `covers` but is missing or misspelled in `tests`.
- **Research gets too little input.** Lanes never receive the pin or the doc path, so one claim without a pin loses the whole lane. The Apple docs lane has no snapshot source. The skill launches workflows by a `scriptPath` that the Workflow tool has been seen to refuse.
- **§8.6 reuse cache isn't delivered.** Nothing but probe writes to it.

The fix plan below is 12 tasks in 4 waves.

**Before Wave 1:** merge the lockfile-rewrite branch (known 15). No new task is needed for it.

### Fix waves

### Wave 1: design-doc and plan rules give correct verdicts (blocker first)

Within this wave the three tasks write disjoint files.

**`design-lint-ids-unique-repo-wide`** (opus)
- **Closes:** design-lint-cross-doc-duplicate-never-fires (blocker), duplicate-claim-id-masks-refuted (design-lint side), changelog-append-only-unenforced, design-diff-req-relocation-is-clarify, known 8 (trailing `[UNVERIFIED].` and the unreachable design doc).
- **Writes:**
  - `SwiftGateCLI/Commands/DesignLintCommand.swift`
  - KnownIdSources (return ids with the file that defined them)
  - `SwiftGateDomain/Design/DesignLintSections.swift`
  - `SwiftGateDomain/Design/DesignLintEvidence.swift`
  - `SwiftGateDomain/Design/DesignDiff.swift`
  - DocsLintReferences (unreachable design doc)
  - `Fixtures/seeds/design-lint/*`, `Fixtures/seeds/design-diff/*`
  - matching tests
- **Tests:**
  - A command-level test: two committed designs share a `req-` id, and the second doc goes RED. It must fail against current main first.
  - A duplicate claim id in `claims.jsonl` gives a finding with no winner picked.
  - A Changelog line that is edited or removed classifies as amend; a pure append stays clarify.
  - A `req-` bullet moved out of Requirements classifies as amend.
  - `[UNVERIFIED].` matches its Risks line.
  - A new, unlinked design doc gets an unreachable-doc finding.

**`plan-lint-gates-on-covers-and-design-drift`** (opus)
- **Closes:** plan-lint-ignores-current-design-drift, gate-check-reads-tests-not-covers, duplicate-task-id-crash, stats-overhead-share-contradicts-spec.
- **Writes:**
  - `SwiftGateCLI/Commands/PlanLintCommand.swift`
  - `SwiftGateDomain/Plan/PlanLintCoverage.swift`
  - `PlanLintGraph.swift`, `PlanSchedule.swift`, `LedgerRender.swift`, Ledger decoding
  - `SwiftGateDomain/Design/DesignMetrics.swift`, `StatsCommand.swift`
  - `Fixtures/seeds/plan-lint/*`
- **Tests:**
  - After a committed amend past `designSha`, plan-lint gives a gating `plan-lint.design-moved`.
  - A T3 id in `covers` with `tests: []` gives `gate-too-weak`, and so does a misspelled `tests` id.
  - An unknown `tests` id gives a finding.
  - A duplicate task id gives `plan-lint.duplicate-task-id`, and plan-schedule answers BLOCKED with exit 2, not a trap.
  - `stats --plan` overhead share equals `LedgerRender.predictedOverheadShare`, and the phases-based figure is renamed.
  - Add a seed for each new rule.

**`evidence-check-binds-citations-to-sources`** (opus)
- **Closes:** evidence-checkout-pin-bypass, probe-verdict-unbound, duplicate-claim-id-masks-refuted (evidence check side), known 4 (a citation range past EOF; checkouts read only at the repo root).
- **Writes:**
  - `SwiftGateDomain/Evidence/EvidenceCheck.swift`
  - EvidenceFiles
  - `SwiftGateAdapters/Probe/ProbeBuilder.swift` (verdict records the sha256 of the snippet and of the generated source)
  - `Fixtures/seeds/evidence-check/*`
- **Tests:**
  - These loc spellings are rejected or normalised and pin-checked: `Sources/../.build/checkouts/...`, `.BUILD/checkouts/...`, and any loc containing `..`.
  - A "tampered probe" seed: a hand-written verdict, or an edited snippet, goes RED.
  - A duplicate claim id gives a finding.
  - A range past EOF is rejected, consistent with context-pack.
  - A checkout in a nested project resolves.

### Wave 2: plan-state authority, guards and research inputs

**`plan-state-cli-enforces-session-authority`** (opus)
- **Closes:** lock-takeover-by-agent (CLI side), index-set-no-authority (CLI side), design-ownership-not-exclusive (claim side), known 1 (a command to update plan.json tier and resume after re-scope).
- **Writes:**
  - `PlanClaimCommand.swift` (refuse a `--design` that another plan owns, compared case-insensitively on the canonical path; stop printing the `--force` recipe to agents)
  - `PlanReleaseCommand.swift`
  - `IndexCommand.swift` (`--session` required, and it must hold the lock)
  - PlanStateStore (a new `plan set --tier/--resume`)
  - tests
- **Tests:**
  - A second claim naming the same design exits 1.
  - `index set` without a held lock exits 1.
  - `plan set` updates tier and resume atomically under the lock.
  - Each test reproduces its finding's scratch-repo steps and fails on main first.

**`pretooluse-guards-close-bypasses`** (opus)
- **Closes:** guard-misses-git-writes, lock-takeover-by-agent (hook side), index-set-no-authority (hook side), design-ownership-not-exclusive (guard side), nested-project-design-path-mismatch, known 16 (the dead `.harness/plans` rule), known 12 (hook budget; see user decision 3).
- **Writes:**
  - `SwiftGateDomain/Hooks/Guards.swift` (exactly one owning plan; deny a plan.json edit that repoints `design`)
  - `SwiftGateDomain/Hooks/ShellWriteTargets.swift` (`git checkout`, `restore`, `rm`, `mv` pathspecs)
  - `SwiftGateCLI/Hooks/PreToolUseHook.swift` (resolve PlanLocks against the project root; deny `plan release --force` from any tool call; deny `plan claim|release` or `index set` whose `--session` differs from the payload, or that carries `agent_id`)
  - BashWriteTargetTests and the hook tests
- **Tests:**
  - A payload-driven test for each bypass form in the findings. Each must be denied, and each must fail on main first.
  - In a nested project, `plan claim --design docs/...` lets the holder write, and `evidence check` works with the same value.
  - A hook latency measurement for design-doc writes.

**`research-inputs-carry-pin-doc-and-claims`** (opus)
- **Closes:** lane-prompt-lacks-pin-and-doc-path, pre-mortem-pack-lacks-claims, context-pack-key-path-traversal, known 5 (claim-checker pack ignores `--key`), known 6 (ResearchLanePin), known 9 (claim checker refutes claims whose text says more than their quote; prompt), apple-docs-lane-has-no-snapshot-source (agent side: the lane lists the snapshots it needs as brief requests).
- **Writes:**
  - `ContextPackCommand.swift` (validate the key as a single path component; a pre-mortem pack with claims; claim-checker honours `--key`)
  - `ContextPack.swift` (render the pin and the doc path)
  - the ResearchLanePin source
  - `plugin/workflows/design-research.js` (`basePrompt` adds the pin and the doc path; a claim with no pin is dropped, not the whole lane)
  - `plugin/agents/design-lane-*.md`, `design-claim-checker.md`, `design-pre-mortem.md`
  - `tests/design_research_workflow_test.mjs`, `tests/design_agents_test.mjs`
- **Tests:**
  - `--key '/../x'` exits 2.
  - The research-lane pack contains the pin and the doc path.
  - A lane with one pinless claim keeps its other claims.
  - A short SHA is classified as a commit, and `--key` is checked against the lane names.
  - The claim-checker pack differs per key.

### Wave 3: skill flows across sessions, replan, review workflow

**`design-skill-resumes-across-sessions`** (opus)
- **Closes:** plan-claim-refused-across-sessions, cross-session-resume-skips-claim, workflow-scriptpath-outside-cwd-refused, apple-docs-lane-has-no-snapshot-source (the snapshot and capture step), existing-doc-stop-vs-amend-contradiction, review-final-missing-after-dismissal, known 3 (round numbering after rethink), known 7 (record the frame answer's full text, not only the option label), known 1 (call `plan set` on re-scope).
- **Writes:**
  - `plugin/skills/design/SKILL.md`
  - `references/frame-research-verify.md`
  - `references/review-publish-amend.md`
- **Changes:**
  - Release the claim when design finishes.
  - Claim at the start of in-review, Approve and Revise, and on exit 1 tell the user to run `--force` themselves.
  - Launch the workflows by registered name, or from a copy under `<run>/`, with a fallback when Workflow refuses.
  - Add a pre-lane step that runs `evidence capture` and stores snapshots.
  - Save `review-final.json` on every route into publish.
- **Updates:** the acceptance task text in the plan doc for the headless `/plan` run. That is a docs edit outside `plugin/`, done in this task.
- **Tests:**
  - `tests/skill_commands_test.mjs` stays green, extended to assert that every flag named in the new commands exists.
  - A scripted two-session run in a scratch repo: design approve, then a new-session `/plan` claim succeeds.

**`plan-skill-replans-after-amend`** (opus)
- **Closes:** needs-replan-dead-end, plan-draft-not-gitignored, known 17 (no command dumps the module graph).
- **Writes:**
  - `plugin/skills/plan/SKILL.md` and its references (a replan mode: keep `done` and `pending` tasks fixed, replace the `needs-replan` ones, add fix tasks for changed ids that `done` tasks cover, then plan-schedule and plan-lint at the new `designSha`)
  - `plugin/agents/design-decomposer.md` (a fixed-tasks input)
  - a new module-graph gate subcommand plus its registration
  - `plugin/templates/gitignore` (`**/.harness/plan-draft/`)
- **Tests:**
  - A ledger fixture with `done` and `needs-replan` tasks through replan gives plan-lint GREEN at the new sha.
  - A module-graph command golden test.
  - A bootstrap template test that includes `plan-draft`.

**`review-workflow-respects-caps-and-input-size`** (sonnet)
- **Closes:** review-fanout-over-cap, real-review-synth-check-silently-skips, known 2 (review's `previous` input of ~41 KB is too big for headless tool input).
- **Writes:**
  - `plugin/workflows/design-review.js` (MAX_IN_FLIGHT = 3; pass `previous` by path, not inline)
  - `tests/design_review_workflow_test.mjs` (build or resolve the binary via `plugin/bin/swiftgate`, or fail)
  - `SwiftGateAdaptersTests/RepositoryScriptTests.swift` (reject `skip` lines)
- **Tests:**
  - A deep-tier run never has more than 3 agents in flight, checked with a counter in the stub.
  - A missing binary fails the test.
  - A `previous` input over 40 KB round-trips by path.

### Wave 4: reuse cache, calibration, repo and consumer setup

**`evidence-cache-records-verified-claims`** (opus)
- **Closes:** reuse-cache-never-written.
- **Writes:**
  - a new `swiftgate evidence cache record --design <doc>` command (package claims per pin, snapshots per SDK, checker verdicts with origin, tombstones for refuted claims and for claims an amend replaced)
  - the evidence command registration
  - one line calling it after evidence-check-final in `references/frame-research-verify.md`, and one in the amend step of `references/review-publish-amend.md`
- **Tests:**
  - After record, a second design's context-pack reports cache hits for the same pin.
  - A refuted claim is tombstoned and not served.
  - A command-level test fails on main first.

**`calibration-measures-shipped-agents-unprompted`** (opus)
- **Closes:** calibration-wrong-model, calibration-leading-self-report, flaky-product-intent-seed, known 10 (uikit-in-core-module flake).
- **Writes:**
  - `DesignCalibrationRunner.swift` (default to each agent's frontmatter model; run the agent on `input.md` with its real output schema and score the JSON; use neutral judge questions only)
  - `CalibrateCommand.swift`
  - the freshness check in `CheckCommand.swift` (reject a model mismatch per agent)
  - `Fixtures/calibrate-design/**` (labels, `last-pass.json` with the model per case, and less ambiguous seeds)
- **Tests:**
  - Freshness goes RED when a frontmatter model changes.
  - A margin rule, for example p ≥ 0.7.
  - A fresh calibration pass is recorded (see user decision 2 on cost).

**`repo-and-consumer-setup-gates-hold`** (sonnet)
- **Closes:** plugin-repo-prepush-not-wired, docs-lint-seeds-short, upgrade-bootstrap-leaves-docs-lint-red, known 11 (prove can't revert non-Swift inputs such as templates), known 13 (LiveProcessRunnerTests.timeoutKillsChild flake).
- **Writes:**
  - a root `lefthook.yml` (pre-push runs `plugin/bin/swiftgate check --tier push`; commit-msg runs the comments check)
  - `AGENTS.md` (an install line)
  - `Fixtures/seeds/docs-lint/{broken-relative-link,banned-phrase,local-path}`
  - the bootstrap command source and `plugin/skills/bootstrap/SKILL.md` (a "Left alone" note naming the missing `[docs] managed_files` entries)
  - the prove command source (reverting non-Swift inputs)
  - `LiveProcessRunnerTests.swift` (no wall-clock dependence)
- **Tests:**
  - self-test covers all docs-lint families.
  - Bootstrap on a config without `[docs]` prints the note, and docs-lint goes GREEN after the suggested edit.
  - prove reverts a template.
  - LiveProcessRunnerTests passes 20 runs under load.

### Needs the user's decision

1. **Xcode pin mismatch (known 14).** Options:
   - (a) The mismatch fails t1 and t2.
   - (b) It warns only (current behaviour).
   - (c) It fails only at the push tier.
2. **Calibrating on the shipped model (calibration-wrong-model).** Running the 7 opus agents on opus raises the cost of `calibrate design` several times over. Options:
   - (a) Calibrate each agent on its frontmatter model, always.
   - (b) Use opus only on the push tier or before a release, and sonnet for day-to-day runs.
   - (c) Keep sonnet and document that opus agents are calibrated as a proxy.
3. **Hook budget (known 12).** A Bash or Write guard on a design doc costs about 100 ms against the <50 ms budget. Options:
   - (a) Optimise the guard (cache PlanLocks per session).
   - (b) Raise the budget for design-path writes to 150 ms in the spec.
   - (c) Both.
4. **Review fan-out (review-fanout-over-cap).** Options:
   - (a) Cap review at 3 agents in flight (the plan above assumes this).
   - (b) Amend §11 to allow 4 at deep tier, with the reason.
5. **Publish and Approve need an interactive session (known 18).** Options:
   - (a) Document that publish and Approve need an interactive session, and make headless runs stop at `in-review`.
   - (b) Add a headless approval path (the AskUserQuestion or file-based approval fallback) as a first-class route.
   - (c) Ask for the Artifact tool in headless mode.
6. **§11 cost and latency figures (known 19).** Measured: 2.0M tokens and 78 minutes for two designs, about 1M per design, dominated by research lanes and redrafts, not the cold probe build. Options:
   - (a) Rewrite §11 to about 1–1.5M tokens and 30–45 minutes for standard tier, name the real latency drivers, and close the §14 "unmeasured" row.
   - (b) Keep the targets and open a cost-reduction task (the reuse cache, fewer redraft rounds) before sign-off.
7. **Plan-lint drift versus the plan's working-tree test.** The plan pins working-tree independence, but §5.4 says to compare the current doc's hash. Confirm that §5.4 wins, which the plan above assumes. If it doesn't, record a "Decisions made while planning" entry that drops the comparison and move plan-lint-ignores-current-design-drift out of Wave 1.
## Verified findings

- **major** `reuse-cache-never-written`: §8.6 reuse cache has no production writer except probe: package claims, claim-checker verdicts, snapshots and tombstones are never recorded. Location: plugin/gate/Sources/SwiftGateAdapters/Probe/ProbeBuilder.swift:759; spec §8.6, §11 (10× mitigation). Fix: After verify, have a swiftgate step (such as `evidence check` in the verify phase, or a new `evidence cache record --design <doc>`) append supported package and snapshot claims and claim-checker verdicts with origin, and tombstone refuted claims and claims an amend replaced. Call it from frame-research-verify.md after evidence-check-final.
- **major** `plan-claim-refused-across-sessions`: /swift-harness:plan in any session other than the design session is refused; the planned acceptance run itself does this. Location: plugin/skills/design/references/review-publish-amend.md:309; plugin/skills/plan/SKILL.md:41-50; docs/plans/2026-09-25-design-plan-workflows-plan.md:579. Fix: Have design release the claim when it finishes (`plan release <plan> --session <id>`) and report that, since plan claims an unheld plan. Or have `plan claim` take over when the lock's session matches the plan's last `index set` writer and the index status is `approved`. Update the acceptance task to match.
- **major** `needs-replan-dead-end`: After an amend, the flow sends the user to /swift-harness:plan, which halts on any non-pending task, so needs-replan tasks and fix tasks for done work have no path. Location: plugin/skills/plan/SKILL.md:204; plugin/skills/design/references/review-publish-amend.md:476-490; spec §8.4, §5.9. Fix: Add a replan path to the plan skill: when the ledger has `needs-replan` or `done` tasks, pass the kept tasks to the decomposer as fixed. Have it replace only the `needs-replan` ones and add fix tasks for changed ids that `done` tasks cover. Then run plan-schedule and plan-lint at the new designSha. Otherwise, change the amend text so it doesn't point at /plan.
- **minor** `stats-overhead-share-contradicts-spec`: `stats --design` reports an 'overhead share' that isn't the §9.3 formula. Location: plugin/gate/Sources/SwiftGateDomain/Design/DesignMetrics.swift:400-406; spec §9.3. Fix: Compute stats' overhead share from the ledger (the LedgerRender function) when `--plan` is given. Rename the phases-based figure (for example 'non-draft wall share'), or drop it.
- **minor** `review-fanout-over-cap`: The design review runs up to 4 reviewer chains at once, against the §11 cap of ≤3 concurrent agents per phase. Location: plugin/workflows/design-review.js:336-343; spec §11 (Fan-out, Backpressure). Fix: Cap review at 3 in flight as research does, or amend §11 to say review runs up to 4 at deep, with the reason.
- **minor** `plugin-repo-prepush-not-wired`: The plugin repo has no pre-push hook, so 'calibrate design required at pre-push in the plugin repo' is never enforced automatically. Location: repo root (no lefthook.yml, no .git/hooks, no core.hooksPath); spec §6.2 calibrate design. Fix: Commit a root lefthook.yml (pre-push: `plugin/bin/swiftgate check --tier push`, commit-msg: comments) and add a line to AGENTS.md saying to install it.
- **minor** `docs-lint-seeds-short`: The docs-lint self-test seeds 5 of its 8 families; §6.2 promises one violation per family. Location: plugin/gate/Fixtures/seeds/docs-lint/; spec §6.2 docs-lint ('Ships with a seeded self-test, one violation per family'). Fix: Add seeds broken-relative-link, banned-phrase (with a config.toml fragment), local-path and managed-file-missing under Fixtures/seeds/docs-lint.
- **minor** `changelog-append-only-unenforced`: The §5.3 Changelog rule 'append-only' has no check. Location: spec §5.3 row Changelog; plugin/gate/Sources/SwiftGateDomain/Design/ (no changelog rule). Fix: In design-diff, classify a change that alters or removes an existing Changelog line (not a pure append) as amend. Or add a design-diff finding for it, so history can't be rewritten under a clarify.
- **major** `design-ownership-not-exclusive`: Any plan holder can take over another plan's design doc and .evidence/ by naming it in its own plan.json. Location: plugin/gate/Sources/SwiftGateDomain/Hooks/Guards.swift:295-298; plugin/gate/Sources/SwiftGateCLI/Commands/PlanClaimCommand.swift:52-83. Fix: In `plan claim`, refuse a new plan whose --design is already named by another plan's plan.json (case-insensitive canonical compare). In the guard, allow a design write only when exactly one plan owns the doc and this session holds that plan, and deny a plan.json write that changes `design` to a doc another plan owns.
- **minor** `context-pack-key-path-traversal`: context-pack --key (or a ledger task id) is spliced into the output path unchecked and can overwrite any file, including guarded design docs. Location: plugin/gate/Sources/SwiftGateCLI/Commands/ContextPackCommand.swift:717-720, 181-183, 620. Fix: Validate the key as a single safe path component (no '/', '\0', '..' or leading '.'), as PlanStateLayout.plan(_:) already does for slugs, and exit 2 otherwise. Also give ledger task ids a closed character set in the ledger decoder or in plan-lint.
- **minor** `evidence-checkout-pin-bypass`: A package-checkout citation skips the Package.resolved pin check when its path is spelled with '..' or different letter case. Location: plugin/gate/Sources/SwiftGateDomain/Evidence/EvidenceCheck.swift:589-595 (FileLoc.checkoutPackage), 349-351. Fix: Normalise the loc lexically (drop '.' and fold 'x/..') and compare `.build`/`checkouts` case-insensitively before classifying. Better, reject any file loc that contains '..' at all.
- **major** `lock-takeover-by-agent`: Any session or subagent can release another session's plan lock, by passing that session's id or --force. Location: plugin/gate/Sources/SwiftGateCLI/Commands/PlanClaimCommand.swift:92-131, 66-70; plugin/gate/Sources/SwiftGateCLI/Commands/PlanReleaseCommand.swift:13-23. Fix: In PreToolUse, deny `swiftgate plan release --force` from any Claude tool call so only the user runs it. Also deny `plan claim|release` whose --session differs from the payload's session_id, or any such call carrying an agent_id. Alternatively, have the hook inject the session id rather than trusting the flag.
- **minor** `index-set-no-authority`: `swiftgate index set` lets a subagent or non-holder rewrite any plan's index status, which the edit guard forbids. Location: plugin/gate/Sources/SwiftGateCLI/Commands/IndexCommand.swift:46-75. Fix: Require `--session` on `index set` and accept it only when that session holds the slug's orchestrator.lock (or SWIFT_HARNESS_ORCHESTRATOR=1 is set). Have PreToolUse deny `swiftgate index set` from a payload carrying agent_id.
- **major** `nested-project-design-path-mismatch`: In a project nested below the git root, the guard and the other gate commands read plan.json `design` relative to different roots. Location: plugin/gate/Sources/SwiftGateCLI/Hooks/PreToolUseHook.swift:229-247 vs plugin/gate/Sources/SwiftGateCLI/Commands/EvidenceCheckCommand.swift / PlanStateStore.swift:81-92. Fix: Choose one base. Either store `design` toplevel-relative everywhere (claim prepends `git rev-parse --show-prefix`, and the readers strip it), or resolve against the project root in PlanLocks.records the way the other commands do.
- **minor** `duplicate-claim-id-masks-refuted`: design-lint keeps the last of duplicate claim ids, so a later 'supported' line hides a refuted Decision citation. Location: plugin/gate/Sources/SwiftGateDomain/Design/DesignLintEvidence.swift:~66 (`uniquingKeysWith: { _, latest in latest }`). Fix: Add a design-lint (and evidence check) finding for a repeated claim id in claims.jsonl, and don't pick a winner. At minimum, take the least-trusted status.
- **minor** `duplicate-task-id-crash`: A ledger with a repeated task id crashes plan-schedule and plan-lint instead of producing a finding. Location: plugin/gate/Sources/SwiftGateDomain/Plan/PlanSchedule.swift:29; PlanLintGraph.swift:96,160; LedgerRender.swift:65,231. Fix: Add a `plan-lint.duplicate-task-id` finding checked before scheduling (and a BLOCKED result in plan-schedule). Use `Dictionary(_:uniquingKeysWith:)` in the renderers.
- **blocker** `design-lint-cross-doc-duplicate-never-fires`: design-lint can never flag a req-/test- id that another design doc already defines. Location: plugin/gate/Sources/SwiftGateCLI/Commands/DesignLintCommand.swift:34-36 (spec §5.1 'repo-unique', §5.3 'ids unique repo-wide'). Fix: Have KnownIdSources return ids with the file that defined them, and subtract only the ids that come from this doc's own path. Add a command-level test with two committed designs sharing a req- id.
- **major** `plan-lint-ignores-current-design-drift`: plan-lint stays GREEN after the design is amended and committed past designSha. Location: plugin/gate/Sources/SwiftGateCLI/Commands/PlanLintCommand.swift:230; spec §5.4 ('plan-lint hashes the current doc and compares'). Fix: Compare DesignSha.of(the HEAD/working doc) with plan.designSha, or with the end of the verified clarifyChain. A mismatch should be a gating plan-lint finding (e.g. plan-lint.design-moved) that tells the user to re-approve or replan.
- **minor** `probe-verdict-unbound`: evidence check accepts a hand-written probe verdict with no probe source behind it. Location: plugin/gate/Sources/SwiftGateDomain/Evidence/EvidenceCheck.swift:457-495. Fix: Have `probe` record a sha256 of the snippet and the generated source in verdict.json. evidence check should require the cited Probe_*.swift to exist and its hash to match, and fail otherwise. Add a 'tampered probe' seed under gate/Fixtures/seeds/evidence-check.
- **major** `gate-check-reads-tests-not-covers`: A T3 test in covers but missing or misspelled in tests bypasses plan-lint.gate-too-weak. Location: plugin/gate/Sources/SwiftGateDomain/Plan/PlanLintCoverage.swift:68-74. Fix: Make every `tests` id a design test id and require the test- ids in `covers` to equal `tests` (a gating finding otherwise), or compute the required gate from the test- ids in `covers`.
- **minor** `calibration-leading-self-report`: Calibration seeds ask agents to self-report on a question that names the planted defect. Location: plugin/gate/Fixtures/calibrate-design/*/*/label.json; DesignCalibrationRunner.swift:222-269. Fix: Run the agent on input.md with its real output schema, then score the returned JSON: severity and anchor of the findings, citation kind, and status. Where a judge is still needed, ask a neutral question such as 'what is your most severe finding's anchor/severity', never one that names the defect.
- **major** `guard-misses-git-writes`: The subagent write guard lets git checkout and git rm through on design docs. Location: plugin/gate/Sources/SwiftGateDomain/Hooks/ShellWriteTargets.swift:17-24 (spec §6.3 guard scope; §13 'a subagent write to a … design doc or evidence file is denied'). Fix: Add git checkout/restore/rm/mv (pathspec operands after `--` or matching paths) to writtenOperands, with tests in BashWriteTargetTests.
- **minor** `flaky-product-intent-seed`: Calibration seed design-lane-codebase/product-intent-question passed at p=0.6 of 3 options. Location: plugin/gate/Fixtures/calibrate-design/last-pass.json (case product-intent-question, question cover). Fix: Make the case less ambiguous (a brief that asks a clear product choice with no code answer available), or require a margin such as p ≥ 0.7 and rerun calibration.
- **minor** `design-diff-req-relocation-is-clarify`: Moving a req- bullet out of Requirements is classified as clarify. Location: swiftgate design-diff (DesignDiff.swift classification); spec §6.2 'changes touching a req-… line → amend'. Fix: Compare the set of req- ids parsed from the Requirements section, not the req- lines anywhere in the doc. Any change to that set or its statements is amend.
- **minor** `real-review-synth-check-silently-skips`: The design_review_workflow_test check against the real review-synth passes without running when the debug binary is missing. Location: tests/design_review_workflow_test.mjs:119-122,360-363; plugin/gate/Tests/SwiftGateAdaptersTests/RepositoryScriptTests.swift:58-66. Fix: Build the binary when it's missing (or resolve it via plugin/bin/swiftgate), or fail the test. Have RepositoryScriptTests reject any 'skip' line.
- **major** `lane-prompt-lacks-pin-and-doc-path`: Research lanes never receive the pin or the design doc path, and one claim without a pin throws away the whole lane. Location: plugin/workflows/design-research.js:188-199 and :162; plugin/agents/design-lane-codebase.md:95; plugin/agents/design-lane-apple-docs.md:30. Fix: Add `pin` and the design doc path to `args.lanes[]` (or render them into the research-lane pack from `--pin`, plus a new `--design`), and put both in `basePrompt`. Then drop "else omit" from the lane tables.
- **major** `workflow-scriptpath-outside-cwd-refused`: The skill launches both design workflows by a plugin `scriptPath` that a real run found the Workflow tool refuses. Location: plugin/skills/design/references/frame-research-verify.md:178-180, 207; plugin/skills/design/references/review-publish-amend.md:88-89, 391-392. Fix: Launch the plugin's registered workflows by name (`swift-harness-design-research`, `swift-harness-design-review`), not by scriptPath, or copy the script into `<run>/` first and point scriptPath there. Also extend the Agent-tool fallback to the case where Workflow refuses the launch.
- **major** `apple-docs-lane-has-no-snapshot-source`: No step stores Apple doc snapshots or captures, so the Apple docs lane can't back any semantics claim. Location: plugin/agents/design-lane-apple-docs.md:36-47, 109-111; plugin/skills/design/SKILL.md and references (no capture step). Fix: Add a research-phase step, run before the lanes start, in which the main session stores the snapshots or captures each lane brief asks for. For example, run `swiftgate evidence capture` for command output and save doc pages under `snapshots/`, then list the stored names in the lane's brief or pack.
- **major** `cross-session-resume-skips-claim`: Resuming approval or --revise in a new session hits the edit guard: those entry points never claim the plan and never say how to take it over. Location: plugin/skills/design/SKILL.md:20; plugin/skills/design/references/review-publish-amend.md:253-309, 311. Fix: Begin Read the approval, Revise from comments and the in-review mode with `plan claim <plan> --session <id>`. On exit 1, say that the earlier design session holds the plan and that the user can run `swiftgate plan release <plan> --force` if that session has ended.
- **major** `upgrade-bootstrap-leaves-docs-lint-red`: Upgrading a repo that already has a .swiftgate.toml leaves docs-lint (and so pre-push) RED, while bootstrap reports 'Nothing to do.'. Location: plugin/skills/bootstrap/SKILL.md §4 Follow up; bootstrap's 'Left alone' advice. Fix: When `.swiftgate.toml` lacks `[docs] managed_files`, have bootstrap print a `Left alone: .swiftgate.toml: consider editing` note naming the missing entries (the skill already offers those edits). Or add the key, since it's an additive change.
- **minor** `plan-draft-not-gitignored`: `.harness/plan-draft/` isn't in the stamped .gitignore, so plan drafts and module-graph dumps show up as untracked files. Location: plugin/templates/gitignore:1-11; plugin/skills/plan/SKILL.md:116-144; review-publish-amend.md:478. Fix: Add `**/.harness/plan-draft/` to templates/gitignore.
- **minor** `existing-doc-stop-vs-amend-contradiction`: The skill and its reference disagree on what to do when the frame finds an existing doc. Location: plugin/skills/design/SKILL.md:22; plugin/skills/design/references/frame-research-verify.md:99-100. Fix: Make the reference match the skill: ask with AskUserQuestion whether to switch to `--amend <slug>` (recommended) or stop.
- **minor** `review-final-missing-after-dismissal`: review-final.json is saved only on a `ready` verdict, so a design published after the user dismisses findings loses its delta review at amend time. Location: plugin/skills/design/references/review-publish-amend.md:125, 147-149, 458-460. Fix: Save the last round's workflow.json as review-final.json on every route into publish.
- **minor** `pre-mortem-pack-lacks-claims`: The pre-mortem's contract says its pack holds the cited claims, but it gets the challenger pack, which has none. Location: plugin/agents/design-pre-mortem.md:31; review-publish-amend.md (pre-mortem reads the challenger's pack); ContextPackCommand.swift gatherChallenger. Fix: Either pass `--claims`/`--claim-id` into a pre-mortem pack (the evidence auditor's pack works), or correct the agent's Inputs section and tell it where claims.jsonl lives.
