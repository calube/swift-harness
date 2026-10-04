# View limit on memo share links

## Requirements

- req-view-limit-field: A share can be created with an optional view limit from 1 to 1000, a share created without one behaves as today, and a limit outside 1 to 1000 is rejected with INVALID_ARGUMENT
- req-view-count: Each successful resolve of a share token increments that share's view count by 1, and an invalid, expired or revoked token counts nothing
- req-limit-enforced: Once a share's view count reaches its limit the token returns NOT_FOUND, and 2 resolves racing for the last view never both succeed
- req-list-counts: Listing a memo's shares returns each share's view count and, when set, its limit
- req-web-panel: The share panel offers no limit, 1, 10 or 100 views next to the expiry choice, and each listed share shows "N of M views" with a limit and "N views" without one, with new strings in the English locale
- req-migration: SQLite, MySQL and PostgreSQL each get a migration and a matching LATEST.sql, and existing shares keep working with no limit and a view count of 0

## Areas

- memos (Go, root `.`; warm test 30.6 s, build-only: its tests and their proof run at merge)
- web (node, root `web`; warm test 22.8 s)

## Assumptions

- The contract commit already landed the proto fields (`optional int32 view_limit = 4`, output-only `int32 view_count = 5`) with regenerated Go, OpenAPI and TypeScript, the store fields `MemoShare.ViewLimit *int32` and `MemoShare.ViewCount int32`, and the `ConsumeMemoShareView(ctx, uid, now)` store and driver method, stubbed in each driver.
- Columns are `view_limit INTEGER DEFAULT NULL` and `view_count INTEGER NOT NULL DEFAULT 0`, added by migration `26.10/00__add_memo_share_view_limit.sql` for each driver, since the run's date is 2026-10 and the migration README names `YY.MM/NN`.
- Adding the first calendar migration moves the binary's schema version from 0.31.8 to 26.10.1; store tests that assert 0.31.8 as the current version, or 26.9.1 as a newer-than-binary schema, are updated to the new version as part of the store task.
- "Only a successful resolve counts" is read as: GetSharedMemo runs all its existing checks (token, expiry, memo state, read access, conversion) first and consumes the view last, through 1 conditional UPDATE (`view_limit IS NULL OR view_count < view_limit`, not expired); 0 rows updated means NOT_FOUND. That UPDATE is what stops 2 racing resolves from both taking the last view.
- Attachment downloads through the fileserver's `share_token` query parameter neither count views nor check the view limit: a read-once link's memo page loads its attachments right after the view that used up the limit, and must still show them. Expiry still applies there as today.
- Expiry in the consuming UPDATE keeps today's rule: a share is expired when now is greater than `expires_ts`.
- The web panel's view-limit select uses the values none, 1, 10 and 100; the count text uses i18n keys `memo.share.views-of-limit` ("{{count}} of {{limit}} views") and `memo.share.views` ("{{count}} views") in `en.json` only.
- MySQL and PostgreSQL migrations and drivers are written but not run here; the spec says their containers aren't available, so the store tests run with `DRIVER=sqlite` only.
- The memos area's test command is `DRIVER=sqlite go test -json ./...`, per the spec's note that Go tests run with `DRIVER=sqlite`; the discovered `go test -json ./...` tried MySQL and PostgreSQL containers.
- The contract task's return was stored without passing `build check-return`: the check asks for an `app-build` step that a slice gate in this non-app repository never records. The contract commit 1316c660 is on the plan branch and its slice gate was GREEN (run 20261004T124315Z-62ce9982).
- Halt on share-view-limit-web: `build check-return` failed with `build-return.gate-missing-step: gate run 20261004T124503Z-79e036f7 never ran the task gate's app-build step`. The slice gate records no steps at all, so no slice task can pass this check. Chose the recommended option, go on without it: the task stays blocked, and its commits 92640971 and 85f39893 stay on branch spec/share-view-limit-web.
- Halt on share-view-limit-store: `build check-return` failed the same way (`build-return.gate-missing-step`, gate run 20261004T124847Z-cc87cdd0). Chose the recommended option, go on without it: the task stays blocked, its commits f975b462 and 1151658c stay on branch spec/share-view-limit-store, and share-view-limit-api, which depends on it, never starts.

### share-view-limit-contract
Declare the view-limit proto fields, store fields and consume method every task compiles against, with no behaviour.
- Deps: none · Gate: slice · estLines: 70
- Why: requirements 1 to 4 cross the store, API and web, so all three build against 1 declared shape.
- Scope:
  - proto `MemoShare.view_limit` and `view_count`, regenerated Go, OpenAPI and TypeScript
  - `store.MemoShare.ViewLimit` and `ViewCount`, `Store.ConsumeMemoShareView`, `Driver.ConsumeMemoShareView` stubbed in sqlite, mysql and postgres
- Acceptance:
  - every touched area builds; slice is GREEN
- Out of scope:
  - schema changes and any counting or enforcement
- Covers: req-view-limit-field, req-list-counts
- Writes: proto/api/v1/memo_service.proto, proto/gen/, web/src/types/proto/, store/memo_share.go, store/driver.go, store/db/sqlite/memo_share.go, store/db/mysql/memo_share.go, store/db/postgres/memo_share.go

### share-view-limit-store
Store each share's view limit and count in every driver and consume views atomically.
- Deps: share-view-limit-contract · Gate: slice · estLines: 320
- Why: spec items 2 and 3 and the migration constraint: each resolve counts once, a used-up share stops resolving, racing resolves never both take the last view, and existing shares keep working.
- Scope:
  - `store/migration/{sqlite,mysql,postgres}/26.10/00__add_memo_share_view_limit.sql` adding `view_limit` (nullable) and `view_count` (NOT NULL DEFAULT 0) to `memo_share`
  - each driver's `LATEST.sql` gains the same 2 columns so fresh installs match the migrated schema
  - sqlite, mysql and postgres `memo_share.go`: create writes `view_limit` when set; list and get read `view_limit` and `view_count`; `ConsumeMemoShareView` replaces the stub with 1 conditional `UPDATE ... SET view_count = view_count + 1 WHERE uid = ? AND (expires_ts IS NULL OR expires_ts >= ?) AND (view_limit IS NULL OR view_count < view_limit)`, then returns the row when 1 row changed and nil otherwise (sqlite and postgres via `RETURNING`; mysql via the UPDATE then a SELECT in 1 transaction)
  - store tests that pin the schema version at 0.31.8, or treat 26.9.1 as newer than the binary, move to the new version 26.10.1
- Acceptance:
  - new tests in `store/test/memo_share_test.go`, run with `DRIVER=sqlite`, fail first and then pass: a share with limit 2 consumes twice and the third consume returns nil; a share with no limit keeps consuming and its count rises; an expired share consumes nothing; listing returns the count and limit; 2 goroutines racing for the last view of a limit-1 share yield exactly 1 success
  - `DRIVER=sqlite go test ./store/...` passes apart from baseline failures; slice is GREEN
- Out of scope:
  - API validation and GetSharedMemo, the fileserver, the web client
  - running the MySQL and PostgreSQL migrations
- Covers: req-view-count, req-limit-enforced, req-list-counts, req-migration
- Writes: store/migration/sqlite/, store/migration/mysql/, store/migration/postgres/, store/db/sqlite/memo_share.go, store/db/mysql/memo_share.go, store/db/postgres/memo_share.go, store/test/memo_share_test.go, store/test/migrator_test.go, store/test/migrator_guardrail_test.go, store/test/migrator_stable_upgrade_test.go
- Tests: store/test/memo_share_test.go

### share-view-limit-api
Validate the view limit on create, return count and limit on list, and consume a view on each successful resolve.
- Deps: share-view-limit-store · Gate: slice · estLines: 200
- Why: spec items 1 to 4: limits outside 1 to 1000 are INVALID_ARGUMENT, only a successful resolve counts, a used-up share answers NOT_FOUND like an expired one, and listing shows count and limit.
- Scope:
  - `CreateMemoShare` rejects a `view_limit` below 1 or above 1000 with `codes.InvalidArgument` and stores a valid one in `store.MemoShare.ViewLimit`
  - `convertMemoShareFromStore` sets `ViewCount` always and `ViewLimit` when the store share has one
  - `getActiveMemoShare` also answers NOT_FOUND when `ViewLimit` is set and `ViewCount >= *ViewLimit`
  - `GetSharedMemo` calls `Store.ConsumeMemoShareView(ctx, token, time.Now().Unix())` after every other check and the memo conversion succeed; a nil share answers `codes.NotFound` "not found", an error answers `codes.Internal`
- Acceptance:
  - new tests in `server/api/v1/test/memo_share_service_test.go` fail first and then pass: create with limit 0 and 1001 is INVALID_ARGUMENT and 1 and 1000 succeed; a limit-2 share resolves twice and the third resolve is NOT_FOUND; listing returns view count and limit; a share without a limit keeps resolving and counts; an expired or unknown token leaves the count at 0
  - `DRIVER=sqlite go test ./server/...` passes apart from baseline failures; slice is GREEN
- Out of scope:
  - the fileserver's `share_token` attachment path, which keeps its expiry-only check
  - the web client
- Covers: req-view-limit-field, req-view-count, req-limit-enforced, req-list-counts
- Writes: server/api/v1/memo_share_service.go, server/api/v1/test/memo_share_service_test.go
- Tests: server/api/v1/test/memo_share_service_test.go

### share-view-limit-web
Add the view-limit choice to the share panel and show each share's view count.
- Deps: share-view-limit-contract · Gate: slice · estLines: 160
- Why: spec item 5: a no limit, 1, 10 or 100 views choice next to the expiry choice, and "N of M views" or "N views" on each listed share.
- Scope:
  - `useCreateMemoShare` accepts an optional `viewLimit` and sets `MemoShare.viewLimit` when given
  - `MemoSharePanel.tsx` gains a view-limit `Select` beside the expiry one, with options none, 1, 10 and 100, and passes the choice to create
  - each `ShareLinkRow` shows the view-count text from an exported pure helper, `formatViewCount(share, t)`: `memo.share.views-of-limit` when `viewLimit` is set, else `memo.share.views`
  - `web/src/locales/en.json` gains `memo.share.views`, `memo.share.views-of-limit`, `memo.share.view-limit-none`, `memo.share.view-limit-1`, `memo.share.view-limit-10`, `memo.share.view-limit-100`
- Acceptance:
  - a new vitest test `web/tests/memo-share-panel-view-count.test.tsx` fails first and then passes: a share with `viewCount` 3 and `viewLimit` 10 reads "3 of 10 views", and one with `viewCount` 3 and no limit reads "3 views"
  - `pnpm run lint` and `pnpm run test` pass apart from baseline failures; slice is GREEN
- Out of scope:
  - locales other than English, which fall back to English
  - server behaviour
- Covers: req-web-panel
- Writes: web/src/components/MemoDetailSidebar/MemoSharePanel.tsx, web/src/hooks/useMemoShareQueries.ts, web/src/locales/en.json, web/tests/memo-share-panel-view-count.test.tsx
- Tests: web/tests/memo-share-panel-view-count.test.tsx
