# Handoff: sub-project 2, design and plan workflows

<!-- RESUME
State (2026-09-25): Foundation (sub-project 1) is BUILT, live-verified and pushed to main: 598 tests, gate GREEN.
Next action: brainstorm and spec sub-project 2 (design and plan workflows). Start with the brainstorming skill. Write the spec to
  docs/designs/<date>-design-plan-workflows-design.md, then write a plan, then build it wave by wave with workers.
Read first: this file → Foundation spec RESUME header → spec §2 row 2 and §4.2 (plans layout).
Do NOT re-read the whole Foundation spec or plan; grep for the sections you need.
-->

## 1. Where things are

| What | Where |
|---|---|
| Repo | `~/Developer/swift-harness` on private GitHub `calube/swift-harness`, branch `main` |
| Foundation spec | `docs/designs/2026-09-24-swift-harness-foundation-design.md` (RESUME header at the top) |
| Foundation plan | `docs/plans/2026-09-24-foundation-plan.md` (complete) |
| Standards / playbook | `docs/standards.md` (rule anchors C/A/D/E/O/U/X/G/K/H), `docs/testing-playbook.md` (P1–P11) |
| Decisions | `docs/adrs/0001-review-severity-for-standards-violations.md` |
| End-to-end evidence | `docs/e2e-report.md`: tier timings, seeded violations, live-session hooks, the real review-workflow run |
| Worker brief | `docs/handoffs/worker-brief.md`: the brief every build worker got. Reuse it for sub-project 2 |
| Throwaway e2e repo | `~/Developer/swift-harness-e2e` (`source env.sh` first). Safe to delete |

The plugin is **not installed** in Claude Code. It was tested with `claude -p --plugin-dir`. Install per
project with the README steps.

## 2. What sub-project 2 must deliver (locked in the Foundation brainstorm)

**`/swift-harness:design`** writes a design doc:
1. **Frame**, in the main session. Questions go to the user **only through the `AskUserQuestion` tool**: multiple choice,
   recommended option first, never prose lists.
2. **Research** with parallel read-only agents (codebase via the `swiftgate` module graph, Apple and Point-Free docs at the
   **pinned** versions, prior plans and decisions). Every claim goes into `evidence/` with a citation (`file:line`, URL+version,
   or command output).
3. **Hallucination prevention.** A claim with no citation is `UNVERIFIED` and can't be stated as fact. **Symbol probes**
   type-check a tiny snippet against the pinned packages for every API the design relies on. A **claim checker** re-opens
   citations and confirms each one says what the claim says.
4. **Design doc** from a fixed template: problem, evidence, 2–3 options, decision, module kinds, test plan by tier,
   observability, perf and scale (throughput, tail latency, fan-out, failure isolation, resources, backpressure, 10×),
   risks, open questions.
5. **Review pass**, one round, tuned for speed and correctness, 3 agents: evidence auditor, standards conformance, and a
   `self-reflect` challenge. Blockers loop back once, then go to the user.
6. **Publish as a Claude Artifact** (HTML, visual, commentable). The user approves it there.

**`/swift-harness:plan`** writes the ledger. It runs only after the user approves the design:
1. Tasks, each with an id, dependencies, **write set**, the gate tier it must pass, acceptance tests from the test plan, and a size.
2. Deterministic scheduling: build the DAG and group tasks into **waves**. Overlapping write sets never share a wave.
   There is one worktree per task, named `../<repo>-<plan>-<task>` as a sibling of the repo.
3. `swiftgate plan-lint`: the DAG is acyclic, every task has a gate and tests, write sets are disjoint within a wave, and
   **every design requirement maps to at least one task**.
4. Publish the ledger view as an Artifact. Git stays canonical.

**Ledger rules:**
- There is one ledger **per plan, per repo**: `.harness/plans/<date>-<slug>/{design.md, ledger.json, evidence/}` plus
  `.harness/plans/index.json` (`{plans:[{slug,status,resume}]}`, the shape the Foundation hooks already read).
- `~/.swift-harness/projects.json` holds pointers only (the schema `bootstrap` already writes).
- **Only the orchestrator writes the ledger.** The Foundation PreToolUse hook already blocks writes to `ledger.json` and
  `index.json` unless `SWIFT_HARNESS_ORCHESTRATOR=1` or `.harness/orchestrator.lock` is present.
- Workers report through `.harness/task-status.json` in their own worktree.

**Escalation.** A workflow agent that needs a user decision messages the orchestrator (question, 2–4 options,
recommendation, evidence). The orchestrator asks through `AskUserQuestion`, merging concurrent asks up to 4 per prompt,
and records the answer as cited evidence.

## 3. Verify before designing on it (open items)

1. **Can workflow agents get a reply mid-run?** Check whether a Workflow `agent()` can message the orchestrator and wait for
   the answer. The workflow-authoring skill says workflow agents can't background-wait. Fallback: halt the workflow, ask,
   then resume with `resumeFromRunId`.
2. **Ledger branch.** Is the ledger committed on main or on a plan branch? It depends on how sub-project 5's build loop merges
   waves. Decide it in this spec.
3. **Artifact publishing from a workflow.** Scripts have no filesystem or network access, so publishing is a skill step
   in the main session. Confirm this with the `artifact-design` and `artifact-capabilities` skills.
4. **Subagent identity in hook payloads.** `agent_id` hasn't been seen live yet. The orchestrator-only ledger guard relies on
   the marker file or env var, not on that field.

## 4. What the Foundation build taught us (apply these to sub-project 2)

- **Orchestrate thin.** Workers get the brief plus a short note on the interfaces they'll touch, and return ≤200-word
  reports. Keep a running interfaces note, but in the repo or a durable place, not only the session scratchpad. It's what
  kept context small across ~25 workers.
- **One committer per worktree or branch.** Parallel lanes use sibling worktrees. Name merge points ahead of time: `CheckRun`
  was extended by 5 lanes before `CheckRun.Dependencies` unified it.
- **Running it beats reading it.** The e2e run found 9 harness bugs that 500+ unit tests missed. The first real review
  returned `merge` on a planted smell because design violations could never outrank defects (ADR 0001). Validate
  sub-project 2 on a real feature request against `examples/SampleApp` before calling it done.
- **Emulation is not installation.** The review workflow ran with emulated agent types because the plugin wasn't loaded.
  The plugin's own agent types still need one run after install.
- **Costs seen:** one review run was 6 agents, 50s and ~452k subagent tokens. Mutation testing was 21 mutants in 122s at 4 workers.
  This laptop is under memory pressure, so cap parallelism.
- **Toolchain facts:**
  - Xcode 26.2 / Swift 6.2.3; TCA 1.26.2 via its `@swift-6.1` manifest.
  - Never add `swift-issue-reporting` directly before Swift 6.4.
  - `xcodebuild` needs `-skipMacroValidation`.
  - No MainActor default isolation in Core (TCA #3768).
  - `swift test` 6.2 has no shuffle or repeat.
  - Host XCTest skips aren't visible under `--parallel`.

## 5. Known Foundation gaps (not blocking sub-project 2)

- App and UI-test targets aren't in the module graph (no `.xcodeproj` parsing).
- Simulator-tier `prove` and `stress` are pending.
- Host XCTest skip visibility.
- Live hook payloads not yet seen: subagent `agent_id`, Write, SessionStart resume.
- The judge's calibration set was labelled by the same agent that tuned it. Expand it with independent labels.
