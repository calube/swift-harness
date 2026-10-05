# swift-harness: fast modes (surface commits, sprint, design-free ship)

**Status: Built.** `swiftgate surface-check`, `/swift-harness:sprint` with `swiftgate sprint
start|surface|slice|finish|status`, and the design-free ship path (`design_tier = "none"`, `spec-page check`,
`plan confirm`, `plan surface`) all ship. The bootstrap template stamps no preset at `none`, so a repository that
wants that path writes its own preset.

**In brief.** Fast modes cut the time from a spec to green, merged code in a timed, single-session build, and keep
the quality floor. In timed trial runs, design and plan took 13 to 14 minutes before any code. A surface commit
holds only new API with stub bodies, and `swiftgate surface-check` rejects any body with behaviour, so every test
proves against 1 base. `/swift-harness:sprint` builds slice by slice on 1 branch, and its `swiftgate sprint`
commands refuse any step out of order. A preset with `design_tier = "none"` swaps the design step for a 1-page
spec page and a surface commit. All 3 shipped.

<!-- RESUME
Status: APPROVED 2026-09-27 by the user, after answering every open question (§7).
Plan: built (surface-check, then sprint, then design-free ship); the plan now lives only in the
tag `harness-freeze-2026-10-05`.
Why: timed trial run 2 (its handoff now lives only in the tag `harness-freeze-2026-10-05`) and the ship speed research. Design
and plan take 13–14 min before any code; only 27–40% of a run is model coding.
Covers the research's changes 5 (a design-free ship path), 6 (a sprint skill) and 7 (surface commits and
`swiftgate surface-check`). The build executor plan carried changes 1–4, 8–10 as tasks in its "Speed" section.
Decision record: [ADR 0003](../adrs/0003-ship-may-skip-the-design-step.md), accepted.
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
results. (All 3 have since shipped.)

### Non-goals

- A mode tuned to 1 kind of app. Every rule here applies to any spec; no preset, rule or prompt names an app shape.
- Lowering the quality floor (§6). The fast modes move checks later or run them once; they never drop them.
- Simulator QA and profiling. Each has its own design.

## 2. Decision map

| Decision | Proposed | Section |
|---|---|---|
| Surface commits are checked, not trusted | `swiftgate surface-check` fails any added body that isn't a stub | §3 |
| One proof base per build | every test in a build proves at the surface commit, or at the extra stub commit that added its missing API (approved by the user 2026-09-28) | §3.3 |
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
| Function, initializer, accessor, closure | empty; 1 `return` of an empty default (`nil`, `[]`, `[:]`, `0`, `false`, `""`, `.init()`) or an enum case with no payload; a call that forwards to code already on the parent |
| Initializer | only assigns its own parameters, or §7 empty defaults, to `self`'s stored properties (`self.x = x`); any other expression is behaviour |
| Function, accessor, closure yielding a value | 1 initializer call whose arguments are each a §7 empty default or a parameter passed through unchanged (`Foo(items: [], name: name)`); an argument with literal content, a call or an operator is behaviour |
| Function, initializer, accessor, closure (orchestrator decision 2026-09-27, approved by the user 2026-09-28) | only `throw` of an error value, with no other statement: a payload-free case (`SomeError.notImplemented`, `.notImplemented`), an initializer call or an enum case each as this table allows them (`CancellationError()`, `.failed(reason)`); a thrown call to a non-initializer, or literal content, is behaviour |
| Function, accessor, closure yielding a value (orchestrator decision 2026-09-27, approved by the user 2026-09-28) | 1 enum case the parent or the same file declares, constructed with each associated value a §7 empty default or a parameter passed through (`.exited(0)`, `.loaded([])`, `.loaded(items)`); literal content (`.exited(1)`), a call, an operator or a static function that isn't a case is behaviour |
| Function, accessor, closure yielding a value (orchestrator decision 2026-09-27, approved by the user 2026-09-28) | a parameter or a property of `self` returned unchanged (`return runsImpact`, `return value`, `return self.steps`); an operator, a call or a member chain past 1 `self.` access (`self.a.b`, `a.b`) is behaviour |
| Existing array literal (command and registration lists) | gains only bare type references or `Type.self` elements; any other change to an existing body is behaviour |
| Existing `Package.swift` (user decision 2026-09-28) | its `dependencies`, `products` and `targets` lists gain only elements: `.package(path:)`, `.package(url:…)`, `.product(name:package:)`, a target or product declaration, or a target name string; removing or changing an element, a platform, a setting or the tools version, or adding a statement, is behaviour, named `package`. A new manifest is new code (§3.1) |
| Reducer body | returns `.none` for every action, and never mutates state |
| SwiftUI `body` | `EmptyView()`, or a container of `EmptyView()` |
| `#Preview` and preview fixtures | none with non-empty sample data |
| Test files | none: a surface commit adds no tests |

Anything else is a finding `surface-check.behaviour` (major) naming the declaration. `fatalError` and `preconditionFailure`
are findings too: a stub that traps fails every test for a reason other than the missing behaviour. The commit must
build, and the parent's tests must still pass at it.

### 3.3 One proof base

Parallel branches that each carry their own surface can't be proven together: at 1 branch's surface, the other
branches' tests don't compile. The first speed wave hit this at its merge gate and needed a merge of every surface as
the base.

A build from a spec page (§5) records its 1 surface once, as `surfaceCommit` in the plan's `plan.json`, not on each
ledger task, so no copy can disagree. `build proof-bases` lists it first, and every `prove` gets it as `--proof-base`.
A worker no longer rewrites finished code into stubs to make a base: trial run 2's list worker spent 8 commits doing
that. A worker whose test needs API the plan surface lacks commits that API alone as a stub that passes
`surface-check`, and returns it as its task return's `surfaceCommit`. The final gate proves at the plan surface, then
at each task's stub in merge order. `build check-return` refuses a task that declares a target or product the surface
lacks.

A sprint slice can find that its test needs an API the surface lacks (orchestrator decision 2026-09-28, approved by
the user 2026-09-28). The recorded surface stays as it is: the slice commits the missing API alone as an extra stub
that passes `surface-check`. The sprint's final `ready` gate then proves at the surface and at every extra stub,
oldest first, with 1 `--proof-base` each.

## 4. Sprint

`/swift-harness:sprint <spec-file> [--preset <name>]`. For a spec that 1 model can build in the time available,
and for change requests on a build that's already merged.

### 4.1 Flow

1. **Spec page.** The session writes a 1-page spec from the spec file (§5.2 format). When every slice maps to an
   acceptance test the spec file lists, it goes on; otherwise it asks the user to confirm the page once.
2. **Branch.** `swiftgate sprint start` creates branch `sprint/<slug>` from a green `main` and records the run.
3. **Surface.** The session commits the surface (§3); `swiftgate sprint surface` runs `surface-check` on it and
   records the sha.
4. **Slices.** For each slice in the page's order: a failing test, the code, `check --tier fast` as the inner loop
   (1–7 s in trial runs), then `check --tier push --base <surface>` at the slice boundary, a commit, and
   `swiftgate sprint slice <n> --gate <run id>`. Measuring from the surface keeps a stub a later slice fills out of
   this slice's diff coverage; the finish gate measures from `main`, so it still covers every changed line once.
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
| A slice's gate measured its diff from the surface | the run's history line records the sha `--base` resolved to; `sprint slice` refuses any other base, or none, with `sprint.gate-base` |
| The surface has no behaviour | `sprint surface` runs `surface-check` and refuses on any finding |
| A slice declares no target or product the surface lacks | `sprint slice` reads each `Package.swift` changed since the surface and refuses, with `sprint.target-outside-surface`, a non-test target or product HEAD declares and the surface doesn't, a new package, or a manifest it can't read at either commit; at the surface a new target has no sources, so `prove` could build no test in its package |
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

1. the spec page (§5.2): `swiftgate plan claim <slug> --spec-page` seeds the plan, the main session writes the page,
   `swiftgate spec-page check` judges it, and `swiftgate plan confirm` records its sha. The user confirms it once
   unless the check prints `confirm: skippable`, which it does only when every slice's `Spec:` quote appears in the
   spec file;
2. the surface commit (§3), written on `surface/<slug>` cut from `main`, with a `fast` gate run there, as sprint gates
   its surface: a push-tier gate can't pass a surface that adds a module and no test.
   `swiftgate plan surface` runs `surface-check`, checks the gate ran GREEN at `fast` or above at the surface, fast-forwards `main` to
   it and records it as the plan's `surfaceCommit` (§3.3);
3. `/swift-harness:plan` decomposing the spec page's slices into ledger tasks. The decomposer reads the surface's
   files, and a task may own the stubs it fills. Write sets are disjoint within a wave, as `plan-schedule` splits
   them; a task may still depend on an earlier one;
4. `/swift-harness:build` as today, with the preset's gates.

### 5.2 The spec page

One Markdown file in plan state, `<plans>/<slug>/spec-page.md`, at most 400 words: goal, module kinds and their
boundaries, the surface (types and screens), the slices with 1 acceptance test each, and what's out of scope. It
uses the sprint page's format. It replaces the design doc as the plan's source, so `plan-lint`'s coverage rule reads
its acceptance tests instead of a design's test plan. Each slice is 1 coverage item, `slice-<n>-<kebab test name>`,
at T1 unless the slice adds `Tier: T2.` or `Tier: T3.` before its `Spec:`.

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

## 7. Decisions from the user (2026-09-27)

| Question | Answer |
|---|---|
| Order | sprint first, built for correctness |
| Sprint state | a sprint state file only (§4.2); no plan, ledger or ledger page |
| Sample data in stubs | no: a stub returns only an empty default (`nil`, `[]`, `[:]`, `0`, `false`, `""`, `.init()`); non-empty sample data, previews included, is behaviour |
| Profile default | yes: a profile picks a preset, and a preset with `design_tier = "none"` makes design-free ship the default |
| Confirming the spec page | skipped when every slice maps to an acceptance test the spec file already lists; otherwise 1 confirm |

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
