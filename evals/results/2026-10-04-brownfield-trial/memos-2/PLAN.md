# View limit on memo share links

## Requirements

- req-limit-field: A share can be created with an optional view limit from 1 to 1000; a share without one behaves as today, and a limit outside 1 to 1000 is rejected with INVALID_ARGUMENT
- req-count-views: Each successful resolve of a share token raises that share's view count by 1, and an invalid, expired or revoked token counts nothing
- req-limit-exhausted: Once a share's view count reaches its limit the token returns NOT_FOUND, and 2 resolves racing for the last view never both succeed
- req-list-counts: Listing a memo's shares returns each share's view count and, when set, its view limit
- req-migration: SQLite, MySQL and PostgreSQL each get a migration adding the view limit and view count, each LATEST.sql matches it, and existing shares keep working with no limit and a view count of 0
- req-web-panel: The share panel offers no limit, 1, 10 or 100 views next to the expiry choice, and each listed share shows "N of M views" with a limit and "N views" without one, in the English locale

## Areas

- memos (Go, root `.`; warm test 61 s, build-only at slice; 1 baseline failure seen in `scripts` TestEntrypointDoesNotLoopWhenTargetUIDIsRoot, which passes alone)
- web (root `web`; warm test about 35 s through the temp-copy wrapper, build-only at slice; baseline failures in tests/filtered-memo-stats.test.ts from the local time zone, and map tests that time out under full-suite load)

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

### share-view-limit-contract
Add the proto fields, regenerated code, store fields and a stubbed consume method that every task compiles against.
- Deps: none · Gate: slice · estLines: 400
- Why: requirements 1 to 5 cross the store, API and web, so all three build against 1 declared shape.
- Scope:
  - `MemoShare.view_limit` and `MemoShare.view_count` in proto/api/v1/memo_service.proto, with `buf generate` outputs
  - `store.MemoShare.ViewLimit *int32`, `ViewCount int32`; `Store.ConsumeMemoShareView` and `Driver.ConsumeMemoShareView` with not-implemented driver stubs
- Acceptance:
  - go build and web build pass; slice is GREEN
- Out of scope:
  - any behaviour change
- Covers: req-limit-field
- Writes: proto/api/v1/memo_service.proto, proto/gen/, web/src/types/proto/, store/memo_share.go, store/driver.go, store/db/sqlite/memo_share.go, store/db/mysql/memo_share.go, store/db/postgres/memo_share.go

### share-view-limit-store
Persist the view limit and count in all 3 drivers and count views atomically.
- Deps: share-view-limit-contract · Gate: slice · estLines: 350
- Why: spec items 2 and 3 and the migration constraint: counts rise only on a successful resolve, stop at the limit, and existing shares keep working.
- Scope:
  - migrations `26.10/00__add_memo_share_view_limit.sql` for sqlite, mysql and postgres; `view_limit` and `view_count` in each LATEST.sql
  - create stores `view_limit`; list and get read both columns; `ConsumeMemoShareView(ctx, uid, nowTs)` runs 1 conditional UPDATE and returns the updated share, or nil when the share is missing, expired or used up
  - migrator tests that pin the fresh-install schema version and the "newer" calendar schema move to 26.10.1
- Acceptance:
  - store/test/memo_share_test.go: a share with limit 2 consumes twice then returns nil on the third; a share without a limit keeps consuming; an expired share counts nothing; concurrent consumes on limit 1 give exactly 1 success; fail first, then pass with `DRIVER=sqlite`
  - slice is GREEN
- Out of scope:
  - API validation and the web panel
- Covers: req-count-views, req-limit-exhausted, req-migration
- Writes: store/migration/sqlite/, store/migration/mysql/, store/migration/postgres/, store/memo_share.go, store/db/sqlite/memo_share.go, store/db/mysql/memo_share.go, store/db/postgres/memo_share.go, store/test/memo_share_test.go, store/test/migrator_test.go, store/test/migrator_guardrail_test.go
- Tests: store/test/memo_share_test.go

### share-view-limit-api
Validate the limit on create, count views on resolve, and return counts on list.
- Deps: share-view-limit-store · Gate: slice · estLines: 200
- Why: spec items 1 to 4: limit validation, NOT_FOUND once used up, and counts in the list.
- Scope:
  - CreateMemoShare rejects a view_limit outside 1 to 1000 with INVALID_ARGUMENT and stores it otherwise
  - GetSharedMemo treats a used-up share as NOT_FOUND and calls `Store.ConsumeMemoShareView` after all other checks; a nil result returns NOT_FOUND
  - convertMemoShareFromStore sets view_count and view_limit
  - fileserver treats a used-up share token as no share access, without counting
- Acceptance:
  - server/api/v1/test/memo_share_service_test.go: limits 0 and 1001 give INVALID_ARGUMENT; a limit-2 share resolves twice then NOT_FOUND; ListMemoShares returns view_count 2 and view_limit 2; fail first, then pass
  - slice is GREEN
- Out of scope:
  - the web panel
- Covers: req-limit-field, req-count-views, req-limit-exhausted, req-list-counts
- Writes: server/api/v1/memo_share_service.go, server/api/v1/test/memo_share_service_test.go, server/fileserver/fileserver.go, server/fileserver/fileserver_test.go
- Tests: server/api/v1/test/memo_share_service_test.go

### share-view-limit-web
Add the view-limit choice to the share panel and show each share's view count.
- Deps: share-view-limit-contract · Gate: slice · estLines: 180
- Why: spec item 5, the web share panel.
- Scope:
  - `useCreateMemoShare` accepts `viewLimit?: number` and sends it as `viewLimit`
  - MemoSharePanel gets a Select of no limit, 1, 10 and 100 views next to the expiry Select, and each row shows the view-count text
  - an exported pure `formatViewCount(share, t)` in web/src/components/MemoDetailSidebar/memoShareViewCount.ts gives "N of M views" or "N views"
  - English strings under `memo.share` in web/src/locales/en.json
- Acceptance:
  - web/tests/memo-share-view-count.test.ts covers both texts, fails first, then passes
  - pnpm lint passes; slice is GREEN
- Out of scope:
  - other locales, which fall back to English
- Covers: req-web-panel
- Writes: web/src/hooks/useMemoShareQueries.ts, web/src/components/MemoDetailSidebar/MemoSharePanel.tsx, web/src/components/MemoDetailSidebar/memoShareViewCount.ts, web/src/locales/en.json, web/tests/memo-share-view-count.test.ts
- Tests: web/tests/memo-share-view-count.test.ts
