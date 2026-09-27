# Sub-project 5 brainstorm: the build executor (locked decisions, input to the spec)

<!-- RESUME
State (2026-09-26): brainstorm started with the user. Brainstorm COMPLETE: D1–D14 locked (D1 amended by D5). Spec drafted at
docs/designs/2026-09-26-build-executor-design.md and APPROVED by the user on 2026-09-26. Next: the implementation plan.
Motivation: a 45-minute AI coding interview. A README goes in; design → plan → parallel build → validation
comes out. The general executor comes first, and the interview entry point and presets sit on top of it.
-->

## Scope

- `/swift-harness:build`: execute a `planned` ledger wave by wave, meaning worktrees, workers, review, merge,
  gate and status updates. This is the "sub-project 5" that the sub-project 2 design (§1 Non-goals) scoped out.
- An interview entry point: one file (a README or spec) → design → plan → build, driven by a config preset.
- Out of scope: the simulator QA and profiling tool choices. Those are sub-projects 3 and 4, designed with
  the user. The build executor only leaves a hook point for a final validation step.

## Verified facts

- Sub-project 2 already defines the executor's inputs: `ledger.json` (§5.7) with `status`, `worktree`,
  `writeSet`, `deps`, `gate`, `covers`; `TaskStatus` is `pending · in-progress · done · needs-replan`, and
  sub-project 5 may add states, but `done` is immutable. The worker `design-conflict` report goes in
  `.harness/task-status.json` (§5.9, `TaskStatusReport.swift`). `PlanStatus` already has `building`.
- `plan-schedule` splits waves by disjoint write sets (Kahn order), so tasks within one wave never share
  a write-set path. Semantic conflicts (a signature changed in one task, called in another) are still possible
  across waves, and within a wave through shared interfaces.
- `ledger.json` and `index.json` are orchestrator-only (guard: any `agent_id` means not the orchestrator).
  Workers write only `.harness/task-status.json` in their own worktree.
- Workflow scripts have no filesystem or network access. `agent()` accepts `isolation: 'worktree'` (auto-created,
  auto-removed if unchanged), `model`, `effort`, `schema` and `agentType`. Concurrency is capped at min(16, CPUs−2).
  A script can't pause for the user: escalate by returning early and relaunching with `resumeFromRunId`.
- The hand-run loop is in `docs/handoffs/subproject-2-orchestrator-runbook.md`: create a worktree per task,
  clone `.build` with APFS `cp -c` (and drop `ModuleCache`), run one worker per task, check the report against
  the checklist, run fix rounds with `SendMessage` to the same worker, merge `--no-ff` in id order, run the push
  tier on the merged main, then clean up.
  Measured costs: 9–35 min per worker, 20–35 min of wall time per wave of 3, 45–70 s per push tier, and 10–40k
  tokens per fix round.
- `swiftgate` already manages per-worktree DerivedData and simulator clones (`gc`, `ScratchWorktrees`,
  `SimulatorClones`).

## Decisions

- D1 Loop shape: the `/swift-harness:build` skill runs the deterministic steps between waves as `swiftgate`
  commands (create worktrees and seed `.build`/DerivedData, merge, push-tier gate, ledger status). A per-wave
  `build-wave.js` workflow runs `pipeline(tasks, worker → gate → review)`. Ledger and index writes stay in the
  main session, as the orchestrator guard requires. **Amended by D5:** the workflow unit is one task, not one wave.
- D2 Conflicts: a textual merge conflict, or a red push tier on merged main, spawns one opus fixer on main with
  the conflict and both task reports. That's one attempt: green goes on; still red halts and asks.
- D3 Review is preset-controlled: `full` (verifier + test-quality agents per task, the default) or `gate`
  (the task's `swiftgate` tier only, the interview preset).
- D4 Interview approval: a new `sketch` design tier covering frame questions (the interview's clarifying
  questions) → drafter only (no research lane, probes, claim checker or Artifact) → one in-chat
  `AskUserQuestion` approval → plan → build. The human approval gate stays.
- D5 Scheduling is dependency-driven. A task starts once all its `deps` are merged and a slot is free
  (`max_parallel`), so waves remain only the `plan-lint` and report view. Because a workflow can't merge, the unit
  of work is a per-task `build-task.js` (worker → task gate → review) launched in the background. The skill is
  the event loop: on each task's completion notice it merges that branch, runs the push tier on merged main
  (D2 on red), sets the ledger status, and launches newly ready tasks.
- D6 Presets are named tables in `.swiftgate.toml`, `[build.presets.<name>]`, selected with
  `/swift-harness:build --preset <name>`. The knobs: `max_parallel`, `review` (D3), `task_gate`, worker model,
  `time_budget_min`, hooks, `design_tier`. Bootstrap stamps `default` and `interview`.
- D7 Time budget: at budget − N min no new task starts. In-flight tasks finish or are abandoned at the hard
  cutoff. Merged main is always green and demoable, and the report lists the tasks that didn't get built.
- D8 Validation is out of this design. Sub-projects 3 and 4 give an agent the *ability* to validate (simulator
  QA, likely driving `agent-device` per the Foundation map; research still in progress) and to profile. They
  aren't workflow or skill work. The executor ends with `swiftgate check --tier ready` and a named `validate`
  stage that runs whatever 3 and 4 provide once they exist, and is a no-op until then. This relaxes the
  Foundation map's "5 depends on 1–4" to "5 depends on 1–2; the validate stage consumes 3–4"; the spec must
  record that correction.
- D9 Warm builds: the skill creates each worktree with a new `swiftgate worktree create <plan> <task>`, which runs
  `git worktree add` on the ledger's `worktree` name, APFS-clones `.build` and per-worktree DerivedData, and
  drops `ModuleCache`. Workers run in that path. The design doesn't use `agent({isolation: 'worktree'})`.
- D10 Worker model: the decomposer tags each task `model: sonnet|opus` by the runbook rule (sonnet for models,
  views and fixtures; opus for concurrency, locks and cross-module interfaces). A preset can force one model.
  This adds a ledger task field, and `plan-lint` must accept it.
- D11 Task gate in the interview preset: workers loop on `check --tier fast`, the executor runs `push` once per
  merge on main, and `ready` runs once at the end. The `default` preset honours each task's ledger `gate`.
- D12 Rehearsal: a pre-built TCA starter app under `evals/` plus 3 practice READMEs of rising size.
  `swiftgate stats` reports per-phase wall time against the 45-min budget. It doubles as the executor's eval
  suite. The evals peer session owns `evals/`, so coordinate with it before adding there.
- D13 One command: `/swift-harness:ship <spec-file> --preset <name>` chains design (at the preset's
  `design_tier`) → plan → build, so the user runs a single command. During the interview the user explains the
  harness while it runs.
- D14 A `design-conflict` during a build blocks only the tasks whose `covers` intersect the report's ids (a new
  `blocked` status); the rest keep running. The user is asked once. The full `--amend` flow is left for
  untimed presets.
- The Foundation map correction (from D8) is confirmed by the user: sub-project 5 depends on 1–2 and uses 3–4
  through the `validate` stage.

## Open questions

- Can a worktree that `agent({isolation: 'worktree'})` creates be seeded with `.build`/DerivedData before
  the worker's first build, or does the worker clone it as its first step?
