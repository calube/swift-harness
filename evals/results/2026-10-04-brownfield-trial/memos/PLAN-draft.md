# View limit on memo share links

## Areas

- memos (Go, root `.`; warm test 19 s at `<base>`, under the 30 s slice budget, so not build-only)

## Assumptions

- The web client under `web/` is not a discovered area, so swiftgate gates only the Go area; the web task's acceptance runs `cd web && pnpm lint && pnpm test` by hand and the worker reports the output.
- Go tests run as `DRIVER=sqlite go test ./...`, set through `discover --apply`, as the spec states; MySQL and PostgreSQL migrations and driver code are written but not run.
- "A share token resolves to its memo" means a successful `GetSharedMemo` call. The view is counted at the end of that call, after every check passes, so an archived memo or a failed read context counts nothing.
- Attachment fetches through the file server's `share_token` query parameter neither count views nor check the view limit, so a 1-view link still loads its images on that 1 view. The file server keeps its expiry check only.
- The spec names "a new optional field"; the share message gains `optional int32 view_limit` and an output-only `int32 view_count`, since requirement 4 needs both in the list response.
- The race on the last view is closed in the store: 1 conditional `UPDATE ... SET view_count = view_count + 1 WHERE uid = ? AND (view_limit IS NULL OR view_count < view_limit)`, and the resolve succeeds only when it changed 1 row.
- The migration lives at `store/migration/{sqlite,mysql,postgres}/26.10/00__memo_share_view_limit.sql` (schema 26.10.1), adding `view_limit` nullable and `view_count` NOT NULL DEFAULT 0, so existing shares get no limit and 0 views.
- A request whose `view_limit` is set to a value outside 1 to 1000, including 0, is rejected with `INVALID_ARGUMENT`.
- The panel's text uses i18n keys `memo.share.view-limit-*` for the choice and `memo.share.views-of-limit` / `memo.share.views` for the count, English only.
- A baseline run of `DRIVER=sqlite go test ./...` at `<base>` saw `scripts` `TestEntrypointDoesNotLoopWhenTargetUIDIsRoot` killed under load; it is unrelated to this change and left alone.

### share-view-limit-contract
Declare the proto fields, store fields and the `ConsumeMemoShareView` store method every task compiles against.
- Deps: none · Gate: slice · estLines: 60
- Why: requirements 1 to 5 cross the store, the API and the web client, so all 3 build against 1 declared shape.
- Scope:
  - `MemoShare.view_limit` and `MemoShare.view_count` in `memo_service.proto`, regenerated with `buf generate`
  - `store.MemoShare.ViewLimit` and `ViewCount`, `store.ConsumeMemoShareView`, and the driver method stubbed in all 3 drivers
- Acceptance:
  - `go build ./...` passes; slice is GREEN (landed as commit 95b513f8)
- Out of scope:
  - any behaviour
- Writes: proto/api/v1/memo_service.proto, proto/gen/, web/src/types/proto/, store/memo_share.go, store/driver.go

### share-view-limit-store
Store each share's view limit and view count, and count views atomically in every driver.
- Deps: share-view-limit-contract · Gate: slice · estLines: 260
- Why: requirements 2 and 3, "each time a share token resolves its view count goes up by 1" and "two resolves racing for the last view must not both succeed", plus the migration constraint.
- Scope:
  - migrations `26.10/00__memo_share_view_limit.sql` for SQLite, MySQL and PostgreSQL, and the matching `LATEST.sql` columns
  - each driver's `CreateMemoShare` writes `view_limit`; `ListMemoShares` and `GetMemoShare` read `view_limit` and `view_count`
  - each driver's `ConsumeMemoShareView` runs 1 conditional `UPDATE` and returns true only when it changed 1 row
- Acceptance:
  - store tests with `DRIVER=sqlite`: a share with limit 2 consumes twice and the third consume returns false; a share without a limit consumes many times; list returns the limit and count; concurrent consumes of the last view succeed exactly once. Each fails first, then passes; slice is GREEN
- Out of scope:
  - the API validation and `GetSharedMemo` wiring; the web client
- Writes: store/migration/, store/db/sqlite/memo_share.go, store/db/mysql/memo_share.go, store/db/postgres/memo_share.go, store/test/memo_share_test.go
- Tests: store/test/memo_share_test.go
- Does: replace the contract's stub in each driver. Existing rows must read as `ViewLimit == nil`, `ViewCount == 0`. Keep fresh-install `LATEST.sql` equivalent to the migrations; `store/test/migrator_test.go` checks the drivers ship the same versions.

### share-view-limit-api
Validate the view limit on create, count views on resolve, and return limit and count in the share message.
- Deps: share-view-limit-store · Gate: slice · estLines: 180
- Why: requirements 1, 3 and 4: a limit outside 1 to 1000 is `INVALID_ARGUMENT`, a used-up share returns `NOT_FOUND`, and listing returns count and limit.
- Scope:
  - `CreateMemoShare` validates `view_limit` and passes it to the store
  - `GetSharedMemo` calls `Store.ConsumeMemoShareView` after every existing check and returns `NOT_FOUND` when it reports false
  - `convertMemoShareFromStore` sets `view_limit` when present and `view_count`
- Acceptance:
  - API tests in `server/api/v1/test/memo_share_service_test.go`: limits 0 and 1001 return `INVALID_ARGUMENT`; a limit of 2 resolves twice then returns `NOT_FOUND`; a share without a limit keeps resolving; list returns count and limit; an expired share counts no view. Each fails first, then passes; slice is GREEN
- Out of scope:
  - the file server's `share_token` attachment path, which stays as it is
- Writes: server/api/v1/memo_share_service.go, server/api/v1/test/memo_share_service_test.go
- Tests: server/api/v1/test/memo_share_service_test.go

### share-view-limit-web
Add the view-limit choice to the share panel and show each share's view count.
- Deps: share-view-limit-contract · Gate: slice · estLines: 150
- Why: requirement 5, a view-limit choice of no limit, 1, 10 or 100 views, and "N of M views" or "N views" on each listed share.
- Scope:
  - a view-limit `Select` beside the expiry `Select` in `MemoSharePanel.tsx`; `useCreateMemoShare` sends `viewLimit`
  - an exported `formatViewCount(share, t)` helper the row renders under the expiry line
  - new English strings in `web/src/locales/en.json`
- Acceptance:
  - `web/tests/memo-share-panel.test.tsx` checks the text with a limit ("3 of 10 views") and without one ("3 views"), fails first, then passes
  - `cd web && pnpm lint && pnpm test` pass; slice is GREEN
- Out of scope:
  - other locales, which fall back to English
- Writes: web/src/components/MemoDetailSidebar/MemoSharePanel.tsx, web/src/hooks/useMemoShareQueries.ts, web/src/locales/en.json, web/tests/memo-share-panel.test.tsx
- Tests: web/tests/memo-share-panel.test.tsx
