# swift-harness: fast modes (surface commits, sprint, design-free ship)

<!-- RESUME
Status: DRAFT 2026-09-27, for the user's review. Nothing here is approved; no worker starts on it until the user
answers §7 and approves.
Why: interview trial run 2 (docs/handoffs/2026-09-27-interview-trial-run-2.md) and the ship speed research. Design
and plan take 13–14 min before any code; only 27–40% of a run is model coding.
Covers the research's changes 5 (a design-free ship path), 6 (a sprint skill) and 7 (surface commits and
`swiftgate surface-check`). Changes 1–4, 8–10 are plan tasks in docs/plans/2026-09-26-build-executor-plan.md "Speed".
Decision record: [ADR 0003](../adrs/0003-ship-may-skip-the-design-step.md), proposed.
User decision 2026-09-27: sprint first, built for correctness. Building the harness is not the timed session: every
harness change here goes through design approval, plan tasks, surface-first workers, the push + prove merge gate and
mutate on main. Speed is what the shipped mode gives a consumer, never a shortcut in building it.
Read first: this header, then §2, then §4 and §7 (open questions).
-->

## 1. Purpose

Get from a spec to green, merged code fast enough for a timed session, without a mode that trades away correctness.
Three changes, in build order:

1. **Surface commits.** A task's or a session's first commit holds only the new API with stub bodies. A new
   `swiftgate surface-check` proves the commit has no behaviour, so every later test is proven against 1 base.
2. **Sprint.** A single-session skill: the main session builds slice by slice, test-first, with no worktrees,
   subagents or fixers, and 1 `ready` gate at the end.
3. **Design-free ship.** A preset can replace design and plan with a 1-page spec the user confirms once, then
   build it as parallel slices off 1 surface commit.

Build order, by the user's decision: surface commits, then sprint. Design-free ship waits for sprint's rehearsal
results.

### Non-goals

- A mode tuned to 1 kind of app. Every rule here applies to any spec; no preset, rule or prompt names an app shape.
- Lowering the quality floor (§6). The fast modes move checks later or run them once; they never drop them.
- Sub-projects 3 and 4 (simulator QA, profiling). The user designs those in their own sessions.

## 2. Decision map

| Decision | Proposed | Section |
|---|---|---|
| Surface commits are checked, not trusted | `swiftgate surface-check` fails any added body that isn't a stub | §3 |
| One proof base per build | every test in a build proves at the surface commit | §3.3 |
| Sprint is its own skill | `/swift-harness:sprint <spec>`; the main session builds; fast tier inner loop | §4 |
| Ship may skip design | `design_tier = "none"` in a preset; a 1-page spec plus 1 confirm replaces design and plan | §5, [ADR 0003](../adrs/0003-ship-may-skip-the-design-step.md) |
| The quality floor is fixed | test-first, escape-hatch reasons, green merge gates and a final `ready` gate in every mode | §6 |

## 3. Surface commits

### 3.1 What a surface commit holds

Every new type, case, stored property, initializer, method signature, `State` and `Action` member the later tests
need, and a stub view for each new screen that compiles. Existing behaviour is unchanged: nothing reads a new
parameter or field, and an existing call path returns what it returned before.

### 3.2 `swiftgate surface-check <commit>`

A SwiftSyntax pass over the commit's diff against its first parent.

| Added or changed code | Allowed body |
|---|---|
| Function, initializer, accessor, closure | empty; 1 `return` of a literal, `nil`, `[]`, `[:]`, `.init()` or an enum case with no payload; a call that forwards to code already on the parent |
| Reducer body | returns `.none` for every action, and never mutates state |
| SwiftUI `body` | 1 of `EmptyView()`, `Text` with a literal, or a container of those |
| Test files | none: a surface commit adds no tests |

Anything else is a finding `surface-check.behaviour` (major) naming the declaration. `fatalError` and `preconditionFailure`
are findings too: a stub that traps fails every test for a reason other than the missing behaviour. The commit must
build, and the parent's tests must still pass at it.

### 3.3 One proof base

Parallel branches that each carry their own surface can't be proven together: at 1 branch's surface, the other
branches' tests don't compile. The first speed wave hit this at its merge gate and needed a merge of every surface as
the base.

The build records the surface commit on the run (`surfaceCommit`, which already exists per task) and passes it to
every `prove` as `--proof-base`. A worker no longer rewrites finished code into stubs to make a base: trial run 2's
list worker spent 8 commits doing that.

## 4. Sprint

`/swift-harness:sprint <spec-file> [--preset <name>]`. For a spec that 1 model can build in the time available,
and for change requests on a build that's already merged.

### 4.1 Flow

1. **Spec page.** The session writes a 1-page spec from the spec file (§5.2 format) and asks the user to confirm
   it once.
2. **Branch.** `swiftgate sprint start` creates branch `sprint/<slug>` from a green `main` and records the run.
3. **Surface.** The session commits the surface (§3); `swiftgate sprint surface` runs `surface-check` on it and
   records the sha.
4. **Slices.** For each slice in the page's order: a failing test, the code, `check --tier fast` as the inner loop
   (1–7 s in trial runs), then `check --tier push` at the slice boundary, a commit, and `swiftgate sprint slice
   <n> --gate <run id>`.
5. **Finish.** `check --tier ready --base main --proof-base <surface>` once, then `swiftgate sprint finish --gate
   <run id>`, which fast-forwards `main` to the branch.

No worktrees, workers, fixers or merge queue. It can't go faster than 1 model's pace.

### 4.2 What makes it correct

The skill is prose, and prose gets skipped under time pressure. So every step that matters is a `swiftgate sprint`
command that checks it, and the skill can't advance without it.

| Rule | Checked by |
|---|---|
| Steps run in order: start, surface, slices in the page's order, finish | a closed state machine in `SwiftGateDomain`; any other transition exits 1 and names the step it expected |
| A slice's gate ran at that slice's commit | the gate run's `headCommit` equals the branch HEAD the command sees |
| Every slice passed `push` before the next starts | `sprint slice` refuses a RED, BLOCKED or stale run |
| The surface has no behaviour | `sprint surface` runs `surface-check` and refuses on any finding |
| Every new test fails on an assertion without its code | the final `ready` gate's prove at the surface base; `sprint finish` refuses unless it's GREEN at HEAD |
| `main` only moves to a green sprint | `sprint finish` fast-forwards and refuses when `main` moved since `start` |
| A crash loses nothing | state lives in the git common dir with the other plan state; `sprint status` names the next step |

A change request after finish is a new sprint on the same spec page: its own branch, surface and slices, proven
against its own surface.

### 4.3 Testing sprint itself

- The state machine: every legal transition passes, and every illegal 1 fails with the expected step, in domain tests.
- Each command against a temp repo with real commits: a stale `headCommit`, a RED run, a moved `main` and a surface
  with behaviour each refuse. Remove each check, confirm its test goes red, and restore it.
- The skill: a contract test that every `swiftgate` command and flag the skill names exists, as the other skills
  have.
- 2 attended rehearsals on different practice prompts before the user relies on it.

## 5. Design-free ship

### 5.1 Flow

With `design_tier = "none"`, ship runs:

1. the spec page (§5.2), confirmed once by the user;
2. the surface commit and `surface-check` (§3) on `main`;
3. `/swift-harness:plan` decomposing the spec page's slices into ledger tasks, each with a write set disjoint from
   the others and `surfaceCommit` set to the 1 surface;
4. `/swift-harness:build` as today, with the preset's gates.

### 5.2 The spec page

One Markdown file in plan state, at most 400 words: goal, module kinds and their boundaries, the surface (types and
screens), the slices with 1 acceptance test each, and what's out of scope. It replaces the design doc as the
plan's source, so `plan-lint`'s coverage rule reads its acceptance tests instead of a design's test plan.

### 5.3 What's lost

No research lane, probes, evidence check or reviewer panel. [ADR 0003](../adrs/0003-ship-may-skip-the-design-step.md) records the trade and why the floor in §6 is
enough for a spec that already says what to build.

## 6. The quality floor

No preset, profile or mode may turn these off:

- Test-first: a new test fails on an assertion before its code exists.
- Escape hatches carry a same-line `swiftgate:allow` reason.
- Every merge into `main` passes the preset's merge gate GREEN.
- The build or sprint ends with 1 `ready` gate: prove, reach, stress and mutate over everything it added.
- A surface commit passes `surface-check`.

## 7. Open questions for the user

1. **Order.** Answered 2026-09-27: sprint first, built for correctness.
2. **Ledger in sprint.** §4.2 proposes a small sprint state file rather than the plan ledger: it resumes after a
   crash and checks every step, without plan-lint, waves or worker packs. Is that enough, or should sprint also
   render a ledger page you can watch?
3. **Stub list.** Is §3.2's allowed-body list right? In particular: may a stub return a fixed sample value (for
   example a preview's data), or does that count as behaviour?
4. **Profile default.** May a repo's profile make `design_tier = "none"` its default, or must each run ask for it?
5. **Confirm step.** One confirm of the spec page, or none when the spec file already lists acceptance tests?

## 8. Testing the harness

- `surface-check`: fixtures from real commits, 1 per allowed body and 1 per rejected shape, captured with the
  command recorded in the fixtures README.
- Sprint and design-free ship: timed trial runs on a rotating practice set of varied app shapes, never the same
  prompt twice in a row, recorded with `stats --build`. No preset or rule assumes 1 prompt.

## 9. Corrections to earlier specs

| Spec | Was | Now |
|---|---|---|
| Build executor §3.1 (ship) | "Never skip a step" | a preset with `design_tier = "none"` replaces design with the spec page (§5) |
| Build executor §5.1 | `design_tier` is a design tier | adds `none` |
| Sub-project 2 plan-lint coverage | reads the design's test plan | reads the spec page's acceptance tests when the plan has no design |
