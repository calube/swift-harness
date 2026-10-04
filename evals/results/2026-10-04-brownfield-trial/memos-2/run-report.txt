final: GREEN (gate run 20261004T105853Z-711cc047)

# Run report: spec

## Assumptions

- The view limit is `optional int32 view_limit = 4` and the count is `int32 view_count = 5` (output only) on `MemoShare`; the spec names 1 new optional field, and the count needs a field for the list to return it.
- The count rises with 1 conditional `UPDATE ... SET view_count = view_count + 1 WHERE uid = ? AND not expired AND (view_limit IS NULL OR view_count < view_limit)`, so 2 racing resolves for the last view cannot both succeed.
- GetSharedMemo consumes the view only after every other check passes (memo exists, active, readable, converts), so a resolve that fails for any reason counts nothing; losing the race for the last view returns NOT_FOUND.
- Attachment requests through `share_token` in the file server only check that the share is live (not expired, not exhausted) and do not count a view; only GetSharedMemo resolves the token to its memo.
- The migration is `store/migration/<driver>/26.10/00__add_memo_share_view_limit.sql` (schema 26.10.1), per store/migration/README.md naming for the current month; the migrator tests that pin the fresh-install version to 0.31.8 and use 26.9.1 as a "newer" schema move to the new version.
- The panel text is literal: "N views" and "N of M views" with no singular form, as the spec words it.
- Vite refuses every path under a `.git` directory and run worktrees live under the git dir, so the web test command runs vitest from a temp copy outside it (`.git/swift-harness/web-vitest.sh`); lint and build keep the repository's own commands.
- MySQL and PostgreSQL migrations and drivers are written but not run here, as the spec says; Go tests run with the default `DRIVER=sqlite`.
- `swiftgate context-pack` needs a `.swiftgate.toml` this brownfield clone lacks, so each worker pack was written by hand under `context-pack/` from this plan and the spec.
- `plan import` left no index entry, so the orchestrator set the index to `planned` with `swiftgate index set` before `build start`.
- Halt on share-view-limit-store and share-view-limit-web (workflow threw; workers returned gate-red, environment): the PreToolUse guard (`guard.plan-state`, and `guard.subagent-protected-path` for any write into `.git`) denies every subagent write in a brownfield task worktree, which `swiftgate worktree create` always places at `.git/swift-harness/plans/spec/worktrees/<task>`. A retry would hit the same denial, so the recommended option, go on without it, was taken: both stay blocked, and share-view-limit-api, which depends on the store task, never starts.

## Baseline failures

- memos test: the whole step
- web test: the whole step
- web test: the whole step

## Build-only areas

- memos (Go, root `.`; warm test 61 s, build-only at slice; 1 baseline failure seen in `scripts` TestEntrypointDoesNotLoopWhenTargetUIDIsRoot, which passes alone)
- web (root `web`; warm test about 35 s through the temp-copy wrapper, build-only at slice; baseline failures in tests/filtered-memo-stats.test.ts from the local time zone, and map tests that time out under full-suite load)

## Dropped steps

- none

## Review fallbacks

- none

## Plan branch

- swift-harness/spec at 137add49bed70206722d45627ec75e79bc064b28 holds every commit of the run; merging it is your call
