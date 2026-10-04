# View limit on memo share links

## Requirements

- req-limit-field: A share can be created with an optional view limit from 1 to 1000; a share created without one behaves as today
- req-limit-validation: Creating a share with a view limit outside 1 to 1000 fails with INVALID_ARGUMENT
- req-count-on-resolve: Each successful resolve of a share token adds 1 to that share's view count, and an invalid, expired or revoked token counts nothing
- req-exhausted-not-found: Once a share's view count reaches its limit the token returns NOT_FOUND, and 2 racing resolves for the last view never both succeed
- req-list-counts: Listing a memo's shares returns each share's view count and its view limit when it has one
- req-panel-choice: The web share panel offers no limit, 1 view, 10 views or 100 views next to the expiry choice and sends the choice on create
- req-panel-text: Each listed share in the panel shows "N of M views" with a limit and "N views" without one, from English locale strings
- req-migrations: SQLite, MySQL and PostgreSQL each get a migration adding the view limit and view count, LATEST.sql matches, and existing shares keep working with no limit and a view count of 0

## Areas

- memos (Go, root `.`; warm test about 40 s with `DRIVER=sqlite`, build-only at slice)
- web (node, root `web`; warm test about 35 s, build-only at slice)

## Assumptions

- "Resolve" means the public `GetSharedMemo` RPC. Attachment downloads through `/file/...?share_token=` neither count a view nor check the limit, so a read-once link still loads the attachments of the 1 view it allowed; they keep checking expiry only, as today.
- A view counts only when `GetSharedMemo` would otherwise succeed: the handler checks the memo and access first, and increments last, in 1 conditional UPDATE (`view_limit IS NULL OR view_count < view_limit`, and unexpired), so 2 racing resolves for the last view can't both succeed.
- A share whose count reached its limit stays listed for its owner with its "N of M views" text; the panel doesn't hide it, and the owner can revoke it.
- The proto gets `optional int32 view_limit = 4` (OPTIONAL) and `int32 view_count = 5` (OUTPUT_ONLY) on `MemoShare`; a `view_count` sent on create is ignored.
- The store migration is the first calendar migration: `store/migration/{sqlite,mysql,postgres}/26.10/00__add_memo_share_view_limit.sql`, adding `view_limit` (nullable integer) and `view_count` (integer, not null, default 0).
- Go tests run with `DRIVER=sqlite`; the memos area's test command was set to `DRIVER=sqlite go test -json ./...` because the default run starts MySQL and PostgreSQL containers this machine lacks. MySQL and PostgreSQL migrations are written but not run.
- The web area's commands run `pnpm install --frozen-lockfile --prefer-offline` first, since each fresh worktree has no `node_modules`.
- The contract task landed as commit 6fc0cb61 before import, but the ledger listed it pending and dependent packs needed its return; it went through `ledger set` in-progress then done, with a return checked by `build check-return` against a slice run in its own worktree.
- `judge diff-risk` gives no level because the clone's config has no `[judge]` section, so every task's classified review runs at `medium`; the orchestrator reviewed the contract diff itself.
- Halt on `share-view-limit-web`: its workflow return failed `build check-return` (`build-return.surface-commit-off-branch`: the return's `surfaceCommit` held the sha wrapped in literal quotes, `"\"7c3becaa\""`). Following the recommended option, it went on without it, so the task stays blocked on branch `spec/share-view-limit-web` (commits 7c3becaa, a0030881, slice GREEN) and doesn't merge.
- Design-conflict halt on `share-view-limit-store` (on_design_conflict = block): `store/test/migrator_guardrail_test.go`, outside its write set, has a `calver-newer` case at schema 26.9.1 that the first 26.10 migration makes older than latest, so it fails. Its dependent `share-view-limit-api` was blocked too. Following the recommended option, the build stopped. The store work is on branch `spec/share-view-limit-store` (commit 8daa17c7). The fix is to add that file to the task's write set and change the case to 26.11.1.
- Baseline failures at the start commit, not caused by the run: `scripts` `TestEntrypointDoesNotLoopWhenTargetUIDIsRoot` (killed on this machine) and 3 web vitest cases in 1 activity-stats test file.

### share-view-limit-contract
Declare the view-limit fields and the atomic view-consume store method, with no behaviour.
- Deps: none · Gate: slice · estLines: 120
- Why: requirements 1 to 5 cross the store, the API and the web client, so all build against 1 declared shape.
- Scope:
  - `MemoShare.view_limit` and `MemoShare.view_count` in `proto/api/v1/memo_service.proto`, regenerated with `buf generate`
  - `store.MemoShare.ViewLimit *int32` and `ViewCount int32`, the `store.ConsumeMemoShareView` type, `Store.ConsumeMemoShareView` and the `Driver.ConsumeMemoShareView` method
  - driver stubs returning a not-implemented error
- Acceptance:
  - every touched area builds; slice is GREEN
- Out of scope:
  - migrations, SQL, API validation and UI
- Covers: req-limit-field
- Writes: proto/api/v1/memo_service.proto, proto/gen/, web/src/types/proto/, store/memo_share.go, store/driver.go, store/db/sqlite/memo_share.go, store/db/mysql/memo_share.go, store/db/postgres/memo_share.go

### share-view-limit-store
Persist the view limit and count in every driver, and count views atomically.
- Deps: share-view-limit-contract · Gate: slice · estLines: 320
- Why: requirements 2 and 3 ("each time a share token resolves … view count goes up by 1"; "two resolves racing for the last view must not both succeed") and the constraint that every driver gets a migration.
- Scope:
  - a `26.10/00__add_memo_share_view_limit.sql` migration for sqlite, mysql and postgres adding `view_limit` (nullable) and `view_count` (not null, default 0) to `memo_share`
  - the same columns in each driver's `LATEST.sql`
  - each driver's `CreateMemoShare` writes `view_limit`; `ListMemoShares` and `GetMemoShare` read both columns
  - each driver's `ConsumeMemoShareView` runs 1 conditional `UPDATE memo_share SET view_count = view_count + 1 WHERE uid = ? AND (expires_ts IS NULL OR expires_ts >= now) AND (view_limit IS NULL OR view_count < view_limit)`, returns the updated share when 1 row changed, and nil with no error when none did
- Acceptance:
  - in `store/test/memo_share_test.go`, run with `DRIVER=sqlite`: a share with limit 2 consumes twice, then the third consume returns nil; a share without a limit keeps consuming; an expired share and an unknown uid consume nothing; listed shares carry the count and limit; 2 concurrent consumes of a share with 1 view left give exactly 1 success
  - the migrator tests that compare drivers and `LATEST.sql` pass; slice is GREEN
- Out of scope:
  - API validation and the RPC handlers
- Covers: req-count-on-resolve, req-exhausted-not-found, req-migrations, req-list-counts
- Writes: store/memo_share.go, store/db/sqlite/memo_share.go, store/db/mysql/memo_share.go, store/db/postgres/memo_share.go, store/migration/sqlite/, store/migration/mysql/, store/migration/postgres/, store/test/memo_share_test.go, store/test/migrator_test.go
- Does: read `store/migration/README.md` and `store/migrator.go` for the calendar migration naming; if a migrator test pins the latest schema version, update it in `store/test/migrator_test.go`.
- Tests: store/test/memo_share_test.go

### share-view-limit-api
Validate the view limit on create, return counts on list, and consume a view on each successful resolve.
- Deps: share-view-limit-store · Gate: slice · estLines: 220
- Why: requirements 1 to 4: limits from 1 to 1000, `INVALID_ARGUMENT` outside it, `NOT_FOUND` once used up, and the count and limit on list.
- Scope:
  - `CreateMemoShare` rejects a `view_limit` outside 1 to 1000 with `codes.InvalidArgument` and stores a valid one
  - `convertMemoShareFromStore` sets `view_limit` when present and `view_count`
  - `getActiveMemoShare` also returns `NOT_FOUND` for a share whose count reached its limit
  - `GetSharedMemo` calls `Store.ConsumeMemoShareView` after every other check passes and before it returns; a nil result returns `NOT_FOUND` with the same "not found" message an expired link gives
- Acceptance:
  - in `server/api/v1/test/memo_share_service_test.go`: limits 0, -1 and 1001 fail with `INVALID_ARGUMENT`; 1 and 1000 succeed; a limit-2 share resolves twice and then returns `NOT_FOUND`; a share without a limit keeps resolving; `ListMemoShares` returns the count and limit; slice is GREEN
- Out of scope:
  - the fileserver's attachment access, which keeps checking expiry only
- Covers: req-limit-field, req-limit-validation, req-count-on-resolve, req-exhausted-not-found, req-list-counts
- Writes: server/api/v1/memo_share_service.go, server/api/v1/test/memo_share_service_test.go
- Tests: server/api/v1/test/memo_share_service_test.go

### share-view-limit-web
Add the view-limit choice and the view-count text to the share panel.
- Deps: share-view-limit-contract · Gate: slice · estLines: 200
- Why: requirement 5: a view-limit choice next to the expiry choice, and "N of M views" or "N views" for each listed share.
- Scope:
  - `useCreateMemoShare` takes an optional `viewLimit` and sets it on the created `MemoShare`
  - `MemoSharePanel` gains a second `Select` beside the expiry one with no limit, 1 view, 10 views and 100 views, default no limit
  - each `ShareLinkRow` shows the view-count text beside the expiry text, through an exported formatter in the panel file
  - new keys under `memo.share` in `web/src/locales/en.json` only
- Acceptance:
  - `web/tests/memo-share-panel.test.tsx` checks the text for a share with limit 10 and count 3 ("3 of 10 views") and for a share without a limit and count 4 ("4 views"), failing first; `pnpm lint` passes; slice is GREEN
- Out of scope:
  - other locales, which fall back to English
- Covers: req-panel-choice, req-panel-text
- Writes: web/src/components/MemoDetailSidebar/MemoSharePanel.tsx, web/src/hooks/useMemoShareQueries.ts, web/src/locales/en.json, web/tests/memo-share-panel.test.tsx
- Tests: web/tests/memo-share-panel.test.tsx
