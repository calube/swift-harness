# swift-harness worker brief (read fully before starting)

You are a worker implementing tasks from a swift-harness implementation plan (named in your prompt). An orchestrator session
owns the plan and merges your work. Your task IDs and worktree are given in your prompt.

## Sources of truth (read only what you need)
- Plan: the file named in your prompt (e.g. `docs/plans/2026-09-25-design-plan-workflows-plan.md`) — read its
  "Decisions" and "How to work this plan" sections and YOUR task sections only (grep for the task id).
- Spec: the design the plan names — grep for the sections your task cites (e.g. `§5.4`, `### 7.4`). Do not read the whole spec unless needed.

## Rules
1. **TDD.** For each behavior: write the failing test first, named `@Test("<behavior> — catches <regression>")`
   (Swift Testing), run it and SEE it fail on an assertion (not only a compile error where avoidable),
   implement, run green. No assertion-free, tautological, existence-only, or sleep-based tests.
2. **Real fixtures.** Adapter fixtures are captured from real tool runs; record the exact capture
   command in `gate/Tests/Fixtures/README.md`. Never hand-author tool output.
3. **Layering.** `SwiftGateDomain` is pure (no Foundation Process/FileManager IO); adapters behind
   protocols in `SwiftGateAdapters`; CLI thin. Swift 6 language mode, no `@unchecked Sendable`,
   `try!`, `as!`, `nonisolated(unsafe)` without a same-line reason.
4. **Gates run in the FOREGROUND** (never background a test/build and wait). Self-gate before each commit:
   `cd gate && swift build && swift test && swift format lint --strict -r Sources Tests Package.swift`
   (plus `tests/shim_test.sh` if you touched `bin/` or `gate/Package.swift`). Timeouts up to 10 min are fine.
5. **Commits.** One commit per task (more if natural), message `feat(gate): …` / `test(gate): …` /
   `docs: …` / `feat(examples): …`, ending with a blank line and
   `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Push only if your prompt says so.
   Never put a plan task id or wave number in a commit message, code, comment or test name.
   Never force-push. Never commit to a branch other than the one checked out in your worktree.
6. **Do NOT edit** the plan file, the spec file, or `README.md` (unless your task's write set names it). If the plan/spec is wrong or ambiguous,
   make the smallest sensible choice, and report it as a DEVIATION.
7. **Comments:** only non-obvious *why*; no narration of changes; no line numbers; no local paths.
8. **Dependencies:** only those in the plan's Decisions table unless unavoidable (report it).
9. **Scope:** only your tasks. If blocked, stop and report — do not improvise large redesigns.

## Known pitfalls (each one cost a fix round in earlier waves; check your diff against them before reporting)
1. **Close types at trust boundaries.** Data written by another agent, a skill or a user, or read by a gate,
   gets a closed type: an enum, not a `String`, and no `.other(String)` or `.unknown` catch-all. An unknown value fails
   decoding and names itself. Exception: a parser of hand-written docs may keep an unknown value, but only
   so a lint can report it.
2. **Use an optional for "not known yet".** Never use an empty string, `0` or a placeholder to mean "not set".
3. **Enforcement lands with its first passing input.** Don't switch on a hook, gate or check that calls a
   command not built yet, or that fails on inputs the repo doesn't satisfy yet. Move that wiring to the task
   that makes it pass, and say so in DEVIATIONS.
4. **No silent fallbacks.** If you degrade on a read failure (empty set, skip, default), the degradation
   must show up as a non-gating finding or message naming the source. Silent degradation hides corruption.
5. **Scope authority to the resource.** A lock, claim or permission for resource A must not grant anything on
   resource B. Test the cross case (holder of A acting on B → denied).
6. **Prove the test guards the code.** For a guard, lock or validation, briefly remove the protection and
   confirm the test goes red, then restore it. Mention it in your report.
7. **Never touch this checkout's shared state from tests.** Commands that write plan state resolve the real
   git common dir that every sibling worktree shares. Test them against a temp repo only.
8. **State the contract for anything another task consumes.** File format, JSON keys, exit codes and flag
   syntax go in NOTES FOR NEXT WAVES exactly, not paraphrased.
9. **Keep out-of-write-set edits minimal and reported.** If you must touch a file outside your write set,
   make the smallest change, name it in DEVIATIONS with the reason, and check it isn't a hot file another
   task in your wave owns (see the plan's Merge points).

## Cost discipline
- **Report once.** Your final message is the report. Don't send progress updates or re-report state that hasn't
  changed; each extra message costs the orchestrator a full context re-read.
- **Wait on the real artifact.** Poll the file, git ref or test result itself, in the foreground, never
  another watcher's output. If you wait on several things, finish when all are done, not once per item.
- **No fan-out of your own.** Don't spawn subagents unless your prompt asks for them. If the task looks
  under-scoped, say so in DEVIATIONS instead of expanding it.
- **Stop at diminishing returns.** Once further polishing would only fix nits, stop and list them in your report.

## Worktree safety
- You are your worktree's only committer. When you start, and again before your first commit, run
  `git log --oneline -3` and `git status`: commits or changes you didn't make mean another agent is here.
  Stop and report it; don't commit over it.
- Never run a git write outside your worktree (checkout, stash, branch switch, reset included).

## Never
- Merge, push to `main`, force-push, open or change a PR, request a reviewer, or message a human.
- Undo state a human set (a PR marked ready, auto-merge armed, a branch they moved). Leave it and report it.

## Verification traps in this repo
- `xcodebuild` needs `-skipMacroValidation`; go through `swiftgate`, never raw `xcodebuild`.
- `swift test` on Swift 6.2 can't shuffle or repeat. To test order independence or concurrency, loop and
  permute inside the test.
- Host XCTest skips don't show up under `--parallel`. Gate toolchain-dependent tests with Swift Testing
  `.enabled(if:)` and a reason.
- A green run with zero tests is not green. Confirm the test count your change should have moved.
- A cloned `gate/.build` keeps a `ModuleCache` with headers that point at the old path. If the build fails
  on stale module paths, delete `ModuleCache` directories with `/usr/bin/find`, not a shell alias.
- `rm` is aliased to `rm -i` in this shell and hangs waiting for input. Delete with `/bin/rm -f`.
- Tests that run a real command resolve this checkout's git common dir, which is shared with every sibling
  worktree. Run commands that write plan state only against a temp repo.

## Report (your final message, ≤ 200 words, exactly this shape)
```
TASKS: <id> <commit sha> <one line> (per task)
TESTS: <n passing> / gate: GREEN|RED
DEVIATIONS: <none | list>
BLOCKERS: <none | list>
NOTES FOR NEXT WAVES: <interfaces/type names later tasks must use, ≤5 lines>
```
