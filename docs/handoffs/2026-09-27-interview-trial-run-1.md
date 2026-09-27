# Handoff: interview trial run 1 findings

<!-- RESUME
State (2026-09-27): `/swift-harness:ship specs/1-list-detail.md --preset interview` ran in interview-rehearsal-1 and the user stopped it 13 minutes into the 38-minute build budget. Design (sketch) and plan finished. The build merged 2 of 4 tasks, then a worker hung on a permission prompt no one could approve. This doc lists the 18 findings in 6 groups.
Done and merged to main: groups A to D, plus E and F except E2. Both calibration records are fresh, and push is GREEN.
Not bugs: the ledger page's Mermaid block (the Artifact viewer renders `pre.mermaid` itself) and its 0% overhead (the trial ledger's waves sum to its critical path, 800 estimated lines). The shared-file task split in E is ordered by a dependency, which plan-lint allows. The notice escaping is a Claude Code bug: the skills now read replies from files, and a feedback draft covers it.
Open: E2. No `fast` or `push` gate compiles an iOS-only UI target. Fixing it needs a simulator build step in the gate, which is the user's call.
Peers own plugin/: the sub-project 2 orchestrator and swift-harness-df. Message them before any merge into main.
Evidence stays in interview-rehearsal-1 on purpose: main at 4bda12f, the stalled worktree for post-detail-feature-core, plan 2026-09-27-posts-list-detail at index status building, build run 20260927T161534Z-64950f3b.
-->

## The run

- Spec: `specs/1-list-detail.md` in interview-rehearsal-1, a 45-minute posts list and detail exercise.
- Preset `interview`: `design_tier = "sketch"`, `review = "gate"`, `task_gate = "fast"`,
  `merge_gate = "push"`, `time_budget_min = 38`, `on_design_conflict = "block"`.
- Preflight passed: `doctor` GREEN, clean `main`, `warm-check` warm.
- Design: 8 frame answers, 1 drafter run plus 1 lint round, approved at designSha
  `3c877dadf66eafdd481a20c7f31452a21d02a21d`, merged without a PR.
- Plan: 4 tasks in 3 waves. `plan-lint` GREEN with no findings. Ledger page:
  <https://claude.ai/artifact/JpNRN9SUidR9orwHdpZMLP>.
- Build: `api-client-user-comments-endpoints` and `posts-list-feature-core` merged.
  `post-detail-feature-core` hung and now sits `blocked`. `posts-list-detail-views` never started.

## Group A: a red main reaches the build unchecked

The user flagged this bug. It is the first fix.

**What happened.** The sketch path tolerates `docs-lint.requirement-uncited` on the new design doc.
It then merges the design into `main` with `git merge --no-ff`, and no gate runs on that merge. The
pre-commit hooks run the comment and commit-message checks, not `docs-lint`, and a local merge fires
no pre-push hook. So `main` held 9 gating `requirement-uncited` findings before the build began.

The first merge gate, `check --tier push` in run `20260927T161813Z-ff9756f2`, came back RED on those
9 findings alone. T0 and T1 were GREEN with 23 tests passing. The build skill routes a red gate to
`build merge --undo` and the fixer. Neither can fix a design doc outside the task's write set, so the
user kept the merge by hand. The list worker hit the same RED in its own push check.

**Causes.**

1. The skill and the gate disagree. The design skill tolerates a finding that the `push` tier gates
   as `major`. A tolerance that lives in skill prose and not in the gate can't hold.
2. The design skill's Approved step merges into `main` without running any `swiftgate check`.
3. Neither `build start` nor the ship preflight checks that `main` is GREEN at the merge-gate tier.
   A red `main` from before the build then looks like the first task's fault.
4. `build merge` reports `mainCheck: "no-merge-yet"` on the first merge. The merge gate has no
   baseline, so it can't tell a finding that was there before from a new one.

**Fix ideas.** Count a ledger task's `covers` entry as a citation for `requirement-uncited`: the
ledger names every requirement once a plan exists. Run the merge-gate tier on the design branch
before the Approved merge. Add a "main is GREEN" check to the ship preflight and to `build start`.

Related findings:

- `docs-lint` counts only tracked files for `broken-relative-link`. The publish step runs it before
  the proposed commit stages anything, so new router rows fail until `git add`.
- At sketch, `docs-lint` prints RED for a state the skill accepts. A gate that reads RED for an
  accepted state invites the reader to ignore it.

## Group B: a background worker waits forever on a permission prompt

The user flagged this bug too.

**What happened.** The `post-detail-feature-core` worker ran in workflow `wf_c2fa1afc-d7f`. At
16:23:18Z it issued a Bash call that never ran: no child process, no tool result, no transcript
change for 5 minutes and more. The orchestrator got no notice. The user saw the idle workflow and
asked why. `/workflows` showed no way to approve the call, so the user stopped the run.

The call was a red/green proof. It copied `PostDetailFeature.swift` to the session scratchpad under
`/private/tmp`, outside the worktree. Then it patched the source, ran `swift test` and copied the
file back. A write outside the worktree most likely raised a permission prompt that a background
agent can't show.

**Fix ideas.**

1. The build-worker prompt forbids writes outside the worktree. It proves red/green through
   `swiftgate` or `git stash` inside the worktree.
2. The plugin grants a worker the Bash access it needs inside its worktree, so it never prompts.
3. `build-task.js` or the build skill notices a stalled worker. For example, it could flag a
   transcript that hasn't changed for N minutes, then fail the task so the halt path takes over.

The missing prompt is also a Claude Code bug, and a feedback draft covers it.

## Group C: sketch evidence

- The frame writes `answer` claims with status `new`. At sketch no claim checker runs, so they never
  reach `supported`. The drafter pack carries only `supported` claims, so it holds none of them.
- Then `design-lint` flags `citation-not-supported` on every Decision bullet that cites the user's
  own choices. The drafter has to tag the user's decisions `[UNVERIFIED]`.
- The first draft ran 1560 prose words against a 1200-word budget. The drafter pack doesn't state
  the budget. Five prose findings came from the word "concurrently" in the recorded answer text.
- Every non-Decision `[UNVERIFIED]` bullet must reappear in Risks. At sketch every Perf & scale
  bullet is `[UNVERIFIED]`, so the drafter copied all 7 into a single long Risks bullet.

Fix idea: at sketch, an `answer` claim that `evidence check` finds `quote-ok` counts as
`supported`. Exempt Perf & scale from the Risks rule at sketch, as Decision bullets already are.

## Group D: context packs leave out the design's decisions

- `context-pack --role decomposer` carries Requirements, Module kinds, Test plan, the module graph
  and `.swiftgate.toml`. It leaves out Decision, Architecture and Risks, and it doesn't name the
  preset the build will run under. The orchestrator pointed the decomposer at the doc by hand.
- `context-pack --role worker` carries the ledger task, Requirements and Test plan only. The
  workflow args take no note, so the orchestrator can't add the missing sections.
  The build skill never passes `--claims`, yet the pack prints a note that it has no claims slice.

## Group E: build checks

- Both core tasks write `AppFeature.swift` and `AppFeatureTests.swift`. `plan-lint` accepts the
  overlap because a dependency orders the 2 tasks. The critical path came out 3 tasks deep.
- `posts-list-feature-core` edited `AppUI/AppView.swift` outside its write set to keep AppUI
  compiling. It said so in its notes. `build check-return` returned GREEN with no warning.
- The worker reports that the host gate compiles AppUI out. Under `task_gate = "fast"` and
  `merge_gate = "push"`, no gate builds the iOS UI target until the final `ready` check.

## Group F: minor

- `design-scope` recommended `deep` for a 45-minute spec. It counts an interface and live pair and a
  Core and UI pair as 4 modules.
- `design-lint` reports `mmdc-unavailable`, and `doctor` doesn't mention mmdc.
- Agent and workflow notices HTML-escape their text, so `->` arrives as `-&gt;`. A design doc or
  return written from the notice would be corrupt. This is a Claude Code issue. The orchestrator read
  the transcript or the task output file instead.
- The ledger page emits a Mermaid block but loads no Mermaid script, so the DAG shows as raw text.
  Its "0% predicted overhead" also looks wrong for 3 waves.
