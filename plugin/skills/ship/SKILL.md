---
name: ship
description: This skill should be used to take a spec file all the way to merged, green code in a swift-harness repository with one command. It checks the machine and a clean, warm main, then runs /swift-harness:design at the preset's design tier with the spec as the goal (or, at a preset whose design tier is none, writes and confirms a spec page and lands a surface commit on main instead), /swift-harness:plan, and /swift-harness:build with the same preset, and ends with the ledger page and the build's wall time. It stops at the first halt and says where to resume. Use when the user says "ship this spec", "build this README end to end", "/swift-harness:ship", or hands over a spec that already states what to build and wants it built under a preset such as interview.
---

# Ship

`/swift-harness:ship <spec-file> [--preset <name>]` runs 3 existing skills in order: design, plan and
build. Invoking it is the user's opt-in to all 3, and to the agents each one spends. This skill adds
a preflight and a report. Every other step is the named skill, run as that skill says.

A preset whose `design_tier` is `none` skips the design skill. In its place this skill writes a
1-page spec page in plan state, has `swiftgate` check and confirm it, and lands a behaviour-free
surface commit on `main` (steps 3 and 4). Only such a preset selects that path: there is no flag
for it. Every other tier runs step 2 and skips steps 3 and 4.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Run every command from the main checkout's toplevel.

## Names

| Name | Value |
|---|---|
| `<spec-file>` | the argument: a repo-relative file that states what to build, such as a README |
| `<preset>` | `--preset <name>`; else the `profile` key of `[harness]` in `.swiftgate.toml`; else `default` |
| `<design_tier>` | the `design_tier` key of `[build.presets.<preset>]` in `.swiftgate.toml`: a design tier, or `none` |
| `<merge_gate>` | the `merge_gate` key of the same table |
| `<session>` | the `Session id: <id>` line of the SessionStart context |
| `<plan>` | the plan the design skill reports, `<YYYY-MM-DD>-<slug>`; at `none`, `<today as YYYY-MM-DD>-<slug>`, with `<slug>` lowercase letters and digits joined by single hyphens, from the spec's subject |
| `<plans>` | `$(git rev-parse --path-format=absolute --git-common-dir)/swift-harness/plans` |
| `<page>` | `<plans>/<plan>/spec-page.md`, the spec page, as an absolute path |
| `<surface>` | the surface commit's full sha, `git rev-parse HEAD` just after committing it |
| `<run id>` | a gate run's id: the word after `run` on the gate's first line |
| `<run>` | the build run id the build skill reports |

## Stop and resume

The first halt in any step stops the whole run. Let that step's skill ask and record its answer as
it says. When the halt ends the step, stop: run no later step, and tell the user the step that
stopped, the reason as that skill gave it, and the commands that finish the run from there, in
order. For example, after a design halt:

1. `/swift-harness:design <spec-file> --tier <design_tier>`, which picks up the plan where it
   stopped;
2. `/swift-harness:plan <plan>`;
3. `/swift-harness:build <plan> --preset <preset>`.

At `none`, `<plans>/<plan>/plan.json` says where the run stopped. Resume from the first row that
matches, after the preflight:

| `plan.json` | Resume at |
|---|---|
| no `approval` | step 3, item 2: fix the page, then check and confirm it |
| `approval`, no `surfaceCommit` | step 4; when `surface/<plan>` already holds the surface commit, item 4 with that sha |
| `surfaceCommit` | step 5, `/swift-harness:plan <plan>`, then step 6 |

Never skip a step the preset runs, and never work around a halt by hand.

## 1. Preflight

Each check must pass before any design work starts. On a failure, report it and stop.

1. **Preset.** Read `.swiftgate.toml`. When it has no `[build.presets.<preset>]` table, stop and
   list the preset names it does define. Keep `<design_tier>` and `<merge_gate>`.
2. **Machine.** `"$SG" doctor --session <session>`, with `<session>` from the `Session id: <id>`
   line of the SessionStart context. Without that line, run `"$SG" doctor`, which judges the
   newest session record instead. Any non-zero exit: quote its findings and stop.
   `doctor.plugin-changed` means the plugin changed after this session started, and this session
   still runs the skills and agent prompts it loaded then: stop, and tell the user to start a
   fresh session.
3. **Clean main.** `git branch --show-current` prints `main`, and `git status --porcelain` prints
   nothing. Otherwise stop, and ask the user to commit, stash or switch first. Never do it for them.
4. **Warm build.** `"$SG" worktree warm-check --json`. Exit 1 means the main checkout has no warm
   `.build` or DerivedData to clone, so every task worktree would start cold and spend minutes
   compiling. Stop, name the `missing` entries, and tell the user to warm it by building once in
   the main checkout: `swift build --package-path <dir>` for each package `.swiftgate.toml` names.
   Then run ship again. Exit 2: report the message and stop.
5. **Green main.** `"$SG" check --tier <merge_gate>`, where `<merge_gate>` is the preset's
   `merge_gate` key. Not GREEN: quote the findings as `rule: message` and stop. Every merge gate
   in the build runs this tier on `main`. A finding that is already there turns each of them red,
   and the build blames the task it just merged.

## 2. Design

At `none`, skip this step and go to step 3.

Run `/swift-harness:design <spec-file> --tier <design_tier>`. The spec file's contents are the
goal. The frame questions are where the user's clarifying questions about the spec go, so ask the
ones the spec leaves open there. At `sketch` the design skill follows its sketch path.

The step ends when the design skill reports the design `approved` and merged into `main`. Keep
`<plan>`. If it merged through a pull request, run `git switch main && git pull --ff-only` so plan
and build see it.

## 3. Spec page

Only at `none`. The page replaces the design doc as the plan's source.

1. Claim the plan as a spec-page plan. Exit 1 names the session that holds it: stop, and tell the
   user. Exit 2: quote the message and stop.

   ```bash
   "$SG" plan claim <plan> --spec-page --session <session> --json
   ```

2. Read the spec file, then write `<page>` yourself with the Write tool: the plan-state guard lets
   only the plan's lock holder write it, never a subagent. Use the format in the sprint skill's
   [spec page reference](../sprint/references/spec-page.md), at `<page>` instead of the sprint
   path. That means at most 400 words, 1 acceptance test per slice, and each slice's `Spec:` quoting the
   spec file's acceptance line word for word, or `none`. Add `Tier: T2.` or `Tier: T3.` to a
   slice whose test needs it. Each slice becomes a coverage item for the plan.
3. Check the page. Exit 1: fix each finding on the page and run it again. Exit 2: quote the
   message and stop.

   ```bash
   "$SG" spec-page check <page> --spec <spec-file> --json
   ```

4. When `confirm` is `required`, ask once with `AskUserQuestion`: show the slices and each test,
   name the slices marked `Spec: none`, and offer **build this page** (Recommended) and **change
   it**. Apply any change, then run item 3 again; don't ask a second time. Then `<by>` is `user`.
   When `confirm` is `skippable`, go on without asking, with `--by spec-quotes`: every slice
   quotes the spec.
5. Confirm it. `swiftgate` refuses `--by spec-quotes` unless the page is skippable, and any RED
   page. Exit 1: quote `rule: message`, fix what it names and run it again. Exit 2: stop.

   ```bash
   "$SG" plan confirm <plan> --by <by> --spec <spec-file> --session <session> --json
   ```

## 4. Surface

Only at `none`. Every task builds on 1 surface commit, recorded on the plan.

1. `git switch -c surface/<plan> main`.
2. Write every surface item the page lists as a behaviour-free stub, as the sprint skill's
   surface step says. `"$SG" surface-check --help` lists the bodies it allows. No test, no trap,
   no sample data. A `surface-check` finding takes no `swiftgate:allow`: turn the body back into
   a stub.
3. Commit it alone, as the branch's only commit. Keep `<surface>`.
4. `"$SG" surface-check <surface>`. Exit 1: turn each body it names back into a stub,
   `git commit --amend`, and run it again with the new sha.
5. Run the preset's merge gate at the surface, in the foreground, with its output in a file.
   Keep its `<run id>`. Not GREEN: fix, amend the commit and run it again.

   ```bash
   "$SG" check --tier <merge_gate> > "$TMPDIR/ship-surface-gate.txt"; head -1 "$TMPDIR/ship-surface-gate.txt"
   ```

6. Land the surface. It fast-forwards `main` to `<surface>` and records it as the plan's
   `surfaceCommit`, so run it while this checkout is still on `surface/<plan>`. Exit 1: quote
   `rule: message`; fix what it names and run it again, or stop when it says so. Exit 2: stop.

   ```bash
   "$SG" plan surface <plan> <surface> --gate <run id> --preset <preset> --session <session> --json
   ```

7. `git switch main`, then `git branch -d surface/<plan>`.

## 5. Plan

Run `/swift-harness:plan <plan>`. The step ends when the plan's index status is `planned`.

## 6. Build

Run `/swift-harness:build <plan> --preset <preset>`. The build skill starts the run, merges each
task, runs the final gate and finishes the run. Keep `<run>`. A halt the user answers inside the
build, such as a retry, doesn't end this step. Stop only when the build skill stops.

## 7. Report

1. Publish the ledger page a last time: `"$SG" design-render --ledger <plan> --json`, then the
   Artifact tool with its `output`, to the URL the plan and build skills used. When this session
   has no Artifact tool, don't publish: report the rendered page's path,
   `.harness/design-render/<plan>-ledger.html`, in its place and go on. The page is a view, never
   a gate.
2. `"$SG" stats --build <run> --plan <plan>` for each task's wall time and the total against the
   preset's budget.

End with the ledger page link or its path, then the design doc and its tier, or at `none` the spec page path
and `<surface>`. List the tasks done, the unfinished
ones with their status, and each halt with the user's answer. Give the final gate's verdict and run
id, and the wall time against `time_budget_min`. When the index stays `building`, name the resume command.
