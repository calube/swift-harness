---
name: ship
description: This skill should be used to take a spec file all the way to merged, green code in a swift-harness repository with one command. It checks the machine and a clean, warm main, then runs /swift-harness:design at the preset's design tier with the spec as the goal, /swift-harness:plan, and /swift-harness:build with the same preset, and ends with the ledger page and the build's wall time. It stops at the first halt and says where to resume. Use when the user says "ship this spec", "build this README end to end", "/swift-harness:ship", or hands over a spec that already states what to build and wants it built under a preset such as interview.
---

# Ship

`/swift-harness:ship <spec-file> --preset <name>` runs 3 existing skills in order: design, plan and
build. Invoking it is the user's opt-in to all 3, and to the agents each one spends. This skill adds
a preflight and a report. Every other step is the named skill, run as that skill says.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Run every command from the main checkout's toplevel.

## Names

| Name | Value |
|---|---|
| `<spec-file>` | the argument: a repo-relative file that states what to build, such as a README |
| `<preset>` | `--preset <name>`, else `default` |
| `<design_tier>` | the `design_tier` key of `[build.presets.<preset>]` in `.swiftgate.toml` |
| `<plan>` | the plan the design skill reports, `<YYYY-MM-DD>-<slug>` |
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

Never skip a step or work around a halt by hand.

## 1. Preflight

Each check must pass before any design work starts. On a failure, report it and stop.

1. **Preset.** Read `.swiftgate.toml`. When it has no `[build.presets.<preset>]` table, stop and
   list the preset names it does define. Keep `<design_tier>`.
2. **Machine.** `"$SG" doctor`. Any non-zero exit: quote its findings and stop.
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

Run `/swift-harness:design <spec-file> --tier <design_tier>`. The spec file's contents are the
goal. The frame questions are where the user's clarifying questions about the spec go, so ask the
ones the spec leaves open there. At `sketch` the design skill follows its sketch path.

The step ends when the design skill reports the design `approved` and merged into `main`. Keep
`<plan>`. If it merged through a pull request, run `git switch main && git pull --ff-only` so plan
and build see it.

## 3. Plan

Run `/swift-harness:plan <plan>`. The step ends when the plan's index status is `planned`.

## 4. Build

Run `/swift-harness:build <plan> --preset <preset>`. The build skill starts the run, merges each
task, runs the final gate and finishes the run. Keep `<run>`. A halt the user answers inside the
build, such as a retry, doesn't end this step. Stop only when the build skill stops.

## 5. Report

1. Publish the ledger page a last time: `"$SG" design-render --ledger <plan> --json`, then the
   Artifact tool with its `output`, to the URL the plan and build skills used.
2. `"$SG" stats --build <run> --plan <plan>` for each task's wall time and the total against the
   preset's budget.

End with the ledger page link, then the design doc and its tier. List the tasks done, the unfinished
ones with their status, and each halt with the user's answer. Give the final gate's verdict and run
id, and the wall time against `time_budget_min`. When the index stays `building`, name the resume command.
