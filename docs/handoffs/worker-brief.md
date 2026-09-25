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

## Report (your final message, ≤ 200 words, exactly this shape)
```
TASKS: <id> <commit sha> <one line> (per task)
TESTS: <n passing> / gate: GREEN|RED
DEVIATIONS: <none | list>
BLOCKERS: <none | list>
NOTES FOR NEXT WAVES: <interfaces/type names later tasks must use, ≤5 lines>
```
