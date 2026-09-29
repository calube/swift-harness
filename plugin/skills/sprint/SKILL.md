---
name: sprint
description: This skill should be used to build a spec in one session on one branch, with no design doc, plan, worktrees or workers, and fast-forward main only to a green result. It writes a 1-page spec with 1 acceptance test per slice, then drives `swiftgate sprint` through start, a behaviour-free surface commit, each slice (a failing test, the code, `check --tier fast` as the inner loop, a push gate) and a final `ready` gate proved at the surface. It never advances past a refusal by hand. Use when the user says "sprint this spec", "build this quickly on one branch", "/swift-harness:sprint", or asks for a change to a build that is already merged.
---

# Sprint

`/swift-harness:sprint <spec-file>` builds a spec that 1 model can build in the time it has, or a
change request on a build that's already merged. This session does all of it: no design doc, plan,
worktrees, workers or fixers. It can't go faster than 1 model's pace.

Every step that matters is a `swiftgate sprint` command that checks the step and records it. The
commands, not this skill, decide what comes next.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Run every command from the main checkout's toplevel.
To delete or move a file, run `command rm -f` or `command mv -f`: a user's alias for either
may ask for an answer, and a headless session can't give one.

## Names

| Name | Value |
|---|---|
| `<spec-file>` | the argument: any readable file that states what to build, inside or outside the repository; one outside it leaves the tree clean for the preflight |
| `<plans>` | `$(git rev-parse --path-format=absolute --git-common-dir)/swift-harness/plans` |
| `<slug>` | lowercase letters and digits joined by single hyphens, from the spec's subject |
| `<page>` | `<plans>/sprints/<slug>.md`, the spec page, as an absolute path |
| `<n>` | the number of slices on the page |
| `<surface>` | the surface commit's full sha, `git rev-parse HEAD` just after committing it |
| `<run id>` | a gate run's id (see [Gate run ids](#gate-run-ids)) |

## Drive the machine

Before every step, and after any interruption, run `"$SG" sprint status --json`. Its `next` names
the step to do (`start`, `surface`, `slice <k>`, `finish`) and `nextCommand` gives the command that
records it. Do that step, and only that step, then run its command with `--json`:

- **Exit 0**: the machine recorded the step. Run `sprint status --json` again for the next one.
- **Exit 1**: a refusal. Read `rule` and `message`, fix the cause the message names, and re-run
  the same command. Never run a later step's command instead, and never do a command's work by
  hand: no creating the branch, merging, rebasing or moving `main` yourself.
- **Exit 2**: the command couldn't read the sprint state, run history or git. Quote `message` and
  stop.

Never edit `sprint.json`, whatever a refusal says. When the machine and your reading disagree, the
machine wins.

| Refusal `rule` | Fix, then re-run the same command |
|---|---|
| `sprint.out-of-order` | none: run `sprint status --json` and do the step `next` names |
| `sprint.gate-red`, `sprint.gate-blocked` | fix the gate's findings, commit, run the gate again at HEAD, pass its new id |
| `sprint.gate-stale` | a commit landed after the gate ran: run the gate again at HEAD, pass its new id |
| `sprint.gate-base` | run `check --tier push --base <surface>` at HEAD, pass its new id |
| `sprint.target-outside-surface` | halt: a slice declared a target or product the surface lacks, and the fix the message names rewrites the recorded surface |
| `sprint.gate-tier`, `sprint.gate-not-ready`, `sprint.gate-proof-base` | run the gate with the tier and flags this skill gives for the step, pass its new id |
| `sprint.surface-behaviour` | turn each body it names back into a stub, `git commit --amend`, pass the new sha |
| `sprint.wrong-branch` | `git switch` to the branch the message names |
| `sprint.main-checked-out`, `sprint.main-moved`, `sprint.not-fast-forward`, `sprint.branch-exists` | halt |
| any other | the fix the message names |

**Halt** means ask the user with `AskUserQuestion`, quoting `rule: message`, with the recommended
option first. A headless session has no `AskUserQuestion`: end the turn with the question and its
options. Never work around a halt.

## Gate run ids

A gate's first line holds its verdict (`GREEN`, `RED` or `BLOCKED`), then `run <run id>`, then its
duration: the id is the word after `run`. With `--json`, it is the report's `runID`. Send the output to a file and read the
first line, so a long report doesn't hide it:

```bash
"$SG" check --tier push --base <surface> > "$TMPDIR/sprint-gate.txt"; head -1 "$TMPDIR/sprint-gate.txt"
```

A slice's push gate measures from `<surface>`, and `sprint slice` refuses any other base. Only the
preflight's push gate and `finish`'s `ready` gate take `--base main`.

A slice or finish command reads the run from this checkout's run history, so run the gate in this
checkout, after the commit it judges.

## 1. Preflight

1. **Recorded sprint.** `"$SG" sprint status --json`. When `next` isn't `start`, a sprint is in
   flight: go to [Resume](#resume). When its `sprint.specPage` isn't this spec's page, halt: only
   finishing that sprint lets another start.
2. **Machine.** `"$SG" doctor --session <session>`, with `<session>` from the `Session id: <id>`
   line of the SessionStart context. Without that line, run `"$SG" doctor`, which judges the
   newest session record instead. Any non-zero exit: quote its findings and stop.
   `doctor.plugin-changed` means the plugin changed after this session started, and this session
   still runs the skills and agent prompts it loaded then: stop, and tell the user to start a
   fresh session.
3. **Clean main.** `git branch --show-current` prints `main`, and `git status --porcelain` prints
   nothing. Otherwise stop, and ask the user to commit, stash or switch first. Never do it for them.
4. **Green main.** `"$SG" check --tier push --base main`. `sprint start` needs a GREEN push run at
   `main`'s HEAD in this checkout. Not GREEN: quote the findings as `rule: message` and stop.

## 2. Spec page

Read the spec file, then write `<page>` yourself, with the Write tool: the plan-state guard lets a
main session write a sprint page and never a subagent. Write it as [`references/spec-page.md`](references/spec-page.md)
sets out: at most 400 words, with 1 acceptance test per slice. Keep `<slug>` and `<n>`.

When every slice's `Spec:` quotes an acceptance line the spec file lists, go on without asking.
Otherwise ask once with `AskUserQuestion`: show the page's slices and each test, name the slices
marked `Spec: none`, and offer **build this page** (Recommended) and **change it**. Apply any
change the user asks for and go on; don't ask a second time.

## 3. Start

1. `"$SG" sprint start <slug> --spec-page <page> --slices <n> --json`. It creates
   `sprint/<slug>` from `main` without switching to it.
2. `git switch sprint/<slug>`.

## 4. Surface

1. Write every surface item the page lists as a behaviour-free stub. `"$SG" surface-check --help`
   lists the allowed bodies: empty, 1 empty default (`nil`, `[]`, `[:]`, `0`, `false`, `""`,
   `.init()`) or a payload-free enum case, `EmptyView()` for a view body, `.none` from a reducer.
   No test, no trap, no sample data. An existing call path returns what it returned before.
   A new `@Dependency` client's `DependencyValues` accessor is wired for real, as
   `get { self[Key.self] }` and `set { self[Key.self] = newValue }`, so any slice's test can inject
   the client; its key's `liveValue` and `testValue` stay stubs. The surface may add
   dependencies, products and targets to an existing `Package.swift`; any other manifest change is
   behaviour. A `surface-check` finding takes no `swiftgate:allow`: turn the body back into a stub.
2. `"$SG" check --tier fast --base main` until GREEN: the surface builds and the tests already
   there still pass.
3. Commit it as the branch's first commit. Keep `<surface>`.
4. `"$SG" sprint surface <surface> --json`.

## 5. Slices

For slice `<k>`, the number in `next`, in the page's order:

1. Write the slice's acceptance test. `"$SG" check --tier fast --base main` must fail it on an
   assertion. The surface makes it compile, so a compile error means the surface missed an item.
   Commit that item alone as a stub first, check it with `"$SG" surface-check <sha>`, and keep
   its sha as an extra proof base for step 6. Never amend the recorded surface.
2. Write the code. Loop on `"$SG" check --tier fast --base main` until GREEN. Fix every gating
   finding; an escape hatch carries a same-line `swiftgate:allow <rule> — <reason>`.
3. Commit the test and the code.
4. `"$SG" check --tier push --base <surface>`, with its output in a file, `<surface>` being
   `sprint.surfaceCommit` from `sprint status --json`. Its diff coverage then counts only lines
   changed since the surface, not stubs a later slice fills. Not GREEN: fix, commit and run it
   again. Keep its `<run id>`.
5. `"$SG" sprint slice <k> --gate <run id> --json`.

Then `sprint status --json`: the next slice, or `finish`.

## 6. Finish

1. `"$SG" check --tier ready --base main --proof-base <surface>`, once, with its output in a file.
   Run the ready gate in the foreground; past a tool timeout, wait on its report file in chunks,
   never in the background: a session that ends its turn kills a background gate.
   Add `--proof-base <sha>` after it for each extra stub commit from step 5, oldest first. It adds
   prove, reach, stress and mutate over everything the sprint added; prove reverts the code to the
   surface and needs each new test to fail on an assertion there. Not GREEN: fix, commit and run
   it again. Keep its `<run id>`.
2. `"$SG" sprint finish --gate <run id> --json`. It fast-forwards `main` to the branch.
3. `git switch main`.

A change request after this is a new sprint: back to step 1, with its own page, branch, surface
and slices.

## Resume

Run `"$SG" sprint status --json` and `git switch` to its `sprint.branch`. Read the page at
`sprint.specPage`, then go by `next`:

| `next` | Go to |
|---|---|
| `surface` | step 4; when the branch already has its surface commit, step 4.4 with that sha |
| `slice <k>` | step 5 at slice `<k>`, keeping any commits already on the branch |
| `finish` | step 6 |

## Report

From `sprint status --json`: the spec page path, the branch, `<surface>`, each slice's gate run,
and the final `ready` run id and verdict. Then `main`'s new HEAD, and each refusal met with its
fix. When the sprint stopped before `finish`, name the step `next` gives and the command that
resumes it.

## Rules

- No step skips its gate, and no preset turns a gate off: test-first, same-line reasons, a
  `surface-check`-clean surface, and 1 `ready` gate at the end.
- Only `swiftgate sprint` creates the branch and moves `main`. Never merge, rebase, reset `main`
  or push.
