# swift-harness: ship speed research, coverage and remaining changes

<!-- RESUME
Status: PROPOSED 2026-09-27; §3 and §4 need the user's approval before they get plan tasks.
Why: the ship speed research after interview trial run 2 ranked 10 harness changes and a few side findings. This doc
maps every one of them to the design, ADR and plan task that carries it, and proposes the 2 that nothing covers yet.
Read first: §2 (the map), then §3 and §4.
-->

## 1. Purpose

Show that every change the ship speed research recommends has a home in a design, an ADR or a plan task. Propose
the changes that don't. The research found the gates right and the process around them too heavy: only 27–40% of
each trial run was model coding.

## 2. Coverage map

| # | Research change | Carried by | State |
|---|---|---|---|
| 1 | per-task prove and mutate become a preset key | [ADR 0004](../adrs/0004-proof-and-mutation-may-run-once-in-the-final-gate.md), build executor §5.1, plan task `speed-task-proof-final` | merged |
| 2 | a gate stops at its first RED stage | plan task `speed-fail-fast-gates` | merged |
| 3 | the worker pack carries the standards for its module kinds | plan task `speed-worker-pack-standards` | merged |
| 4 | impact, diff coverage and an app compile in the task gate | plan task `speed-task-gate-impact-coverage-app-build`; `check-return` enforces it in `speed-check-return-requires-task-gate-steps` | merged; enforcement queued |
| 5 | a design-free ship path | fast modes design §5, [ADR 0003](../adrs/0003-ship-may-skip-the-design-step.md) | designed; plan tasks wait for sprint's rehearsals |
| 6 | a sprint skill | fast modes design §4, plan tasks `sprint-state-machine`, `sprint-commands`, `sprint-skill` | queued |
| 7 | surface commits and `swiftgate surface-check` | fast modes design §3, plan task `surface-check-command` | queued; the slice-shaped decomposer waits with change 5 |
| 8 | every gate run records HEAD; `worktree remove` keeps reports | plan task `speed-fixer-return-and-gate-provenance` | merged |
| 9 | `check-return --fix` accepts `review: null` | plan task `speed-fixer-return-and-gate-provenance` | merged |
| 10 | the budget cutoff never drops a task the app needs to compile | plan task `speed-budget-keeps-app-compiling` | queued |
| — | a running session keeps the agent prompts it loaded (finding 6) | the sub-project 2 hardening documents it; §4 proposes a check | proposed |
| — | views that only compile for iOS escape every host tier (finding 7) | §3 | proposed |
| — | a module added mid-session trips the resolved-file pin | §5: measured, no change | closed |

Outside the harness, and so not designed here: the warm starter repo and its morning checks, bringing in a
consumer's assets, and the validation protocol (a rotating set of varied practice prompts, measured per run). The
architecture advice for small apps is already the standards' engine-module section.

## 3. Views compile on the host

**Problem.** A UI module whose sources sit wholly inside `#if os(iOS)` (or `#if canImport(UIKit)`) builds as an
empty module on the macOS host. `check --tier fast`, push and T1 then never type-check its views. Only the app
build (a task gate step since change 4) or T3 finds its compile errors. Sprint's inner loop and slice gates run
neither, so a broken view first shows up in the final `ready` gate.

**Proposal.** A T0 arch rule, `arch.ui-host-compiled`, flags a source file whose every
top-level declaration sits inside a platform-only `#if` branch with no `#else`, in a module whose
`ModuleRole` is `ui`. The fix it names: guard only the
iOS-only modifiers or types, so the rest compiles on the host. The standards' UI section gains that rule, and
bootstrap's templates never wrap a UI module this way. Severity: major, since the defect it catches is a RED final
gate. A file that can't compile on the host at all carries `// swiftgate:allow arch.ui-host-compiled — <reason>`.

**Tests.** A fixture module wrapped whole fails, naming the file. One that guards only a modifier passes. `#if
os(iOS) … #else … #endif` passes. Each case uses real source parsed with SwiftSyntax.

## 4. A session that runs stale prompts

**Problem.** Claude Code reads a plugin's skills and agent prompts when a session starts. After a plugin change, a
running session still follows the old text, and nothing says so. In trial run 2 the fixer ran a pre-change
prompt and omitted a field its return contract had just gained.

**Proposal.** The plugin's `SessionStart` hook records the plugin version and a hash of its `skills/`, `agents/`
and `workflows/` trees, keyed by the hook input's `session_id`, under `.harness/sessions/`. `swiftgate doctor`
compares the newest record with the tree on disk. The ship, build and sprint preflights run doctor, so a mismatch
stops them with `doctor.plugin-changed`: "the plugin changed after this session started; start a fresh session."
Hashing runs once per session start, never in the per-tool-call hooks, so the 50 ms hook budget is untouched.
Limit: with several sessions in 1 checkout, the newest record can belong to a fresh session while an older one
still runs stale text; a preflight that knows its own session id should pass it to doctor instead.

**Tests.** A record whose hash differs from the tree is a doctor issue naming both. A matching record passes. No
record at all is a note, never an issue, so a repo bootstrapped before the hook still passes.

## 5. Adding a module mid-session (measured, no change)

The research asked whether adding a package mid-session makes `Package.resolved` stale, which the resolved-file pin
rejects (`swiftgate.resolved-file-stale`). Measured on Swift 6.2.3: a zero-dependency package, and a package whose
only dependency is a local `path:` package, both pass `swift test --only-use-versions-from-resolved-file` with no
`Package.resolved` at all (6 s for the second, cold). Neither needs a resolved file, and no guard blocks
`.swiftgate.toml` edits, so a session can add modules without a harness change. Only a new remote dependency needs
`swift package resolve`, which the rule's message already names.

## 6. Open questions for the user

| Question | Proposed answer |
|---|---|
| Approve §3 and §4 for plan tasks? | yes, as 2 tasks in the next hardening wave |
| `arch.ui-host-compiled` severity | major |
| Should §4's mismatch stop ship, or only warn? | stop: a stale prompt breaks the contracts every later step relies on |
