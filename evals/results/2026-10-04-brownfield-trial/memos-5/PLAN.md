# View limit on memo share links

## Requirements

- req-limit-field: A share can be created with an optional view limit from 1 to 1000; a share without one behaves as today, and a limit outside 1 to 1000 is rejected with INVALID_ARGUMENT
- req-count-views: Each successful resolve of a share token increments that share's view count by 1, and an invalid, expired or revoked token counts nothing
- req-limit-reached: Once a share's view count reaches its limit the token returns NOT_FOUND, and 2 racing resolves for the last view never both succeed
- req-list-counts: Listing a memo's shares returns each share's view count and, when set, its view limit
- req-panel-choice: The web share panel offers no limit, 1 view, 10 views or 100 views next to the expiry choice
- req-panel-text: Each listed share shows "N of M views" when it has a limit and "N views" when it doesn't, with the strings in the English locale
- req-migrations: SQLite, MySQL and PostgreSQL each get a migration adding the columns, every LATEST.sql matches, and existing shares get no limit and a view count of 0

## Areas

- memos (Go, root `.`; warm test 83.8 s, build-only)
- web (node, root `web`; warm test 84.1 s, build-only)

## Assumptions

- The proto gains `optional int32 view_limit = 4` (OPTIONAL) and `int32 view_count = 5` (OUTPUT_ONLY) on `MemoShare`; `view_count` is not optional, since every share has a count starting at 0.
- The store gains `ViewLimit *int32` and `ViewCount int32` on `store.MemoShare`, and a driver method `ConsumeMemoShareView(ctx, id) (bool, error)` that runs 1 conditional `UPDATE ... SET view_count = view_count + 1 WHERE id = ? AND (view_limit IS NULL OR view_count < view_limit)` and reports whether it claimed a view; the single conditional UPDATE is what keeps 2 racing resolves from both taking the last view.
- Only `GetSharedMemo` counts views. It consumes the view after every other check passes (token found, not expired, memo readable), so failed resolves count nothing; if the consume claims nothing it returns NOT_FOUND.
- Attachment downloads through `/file/...?share_token=` neither count views nor check the limit, so a 1-view link still shows its images on the page it opened; they keep the existing expiry check only.
- The new migration is `store/migration/{sqlite,mysql,postgres}/26.10/00__add_memo_share_view_limit.sql` (today is 2026-10-04), recording schema 26.10.1 per the migration README.
- A view count of 0 on an unlimited share shows "0 views". The spec allowed other locales to fall back to English, but the repository's `tests/locale-resources.test.ts` requires every locale to hold every English key, so the new strings go in every `web/src/locales/*.json` file.
- The web task's first merge turned the merge gate red on `locale-resources.test.ts`; the merge fixer added the keys to every locale, and the web task's write set was widened from `web/src/locales/en.json` to `web/src/locales/` to cover the fix.
- MySQL and PostgreSQL migrations are written but not run: those store tests need containers this machine lacks; Go tests run with `DRIVER=sqlite`.

### share-view-limit-contract
Declare the view-limit fields and the consume method every task compiles against, with no behaviour change.
- Deps: none · Gate: slice · estLines: 120
- Why: requirements 1 to 4 cross the proto, store, API and web; all of them build against 1 declared shape.
- Scope:
  - `proto/api/v1/memo_service.proto`: `view_limit` and `view_count` on `MemoShare`, regenerated with `buf generate`
  - `store/memo_share.go`: `ViewLimit`, `ViewCount` fields and `Store.ConsumeMemoShareView`
  - `store/driver.go`: `ConsumeMemoShareView` on `Driver`, stubbed in each driver returning an error
- Acceptance:
  - `go build ./...` and `pnpm run build` pass; slice is GREEN
- Out of scope:
  - migrations, SQL, validation, UI
- Covers: req-limit-field, req-list-counts
- Writes: proto/api/v1/memo_service.proto, proto/gen/, web/src/types/proto/, store/memo_share.go, store/driver.go, store/db/sqlite/memo_share.go, store/db/mysql/memo_share.go, store/db/postgres/memo_share.go

### share-view-limit-store
Store the view limit and count in every driver and claim views atomically.
- Deps: share-view-limit-contract · Gate: slice · estLines: 260
- Why: spec items 2 and 3 and the migration constraint: counts persist, the last view is claimed once, existing shares keep working.
- Scope:
  - a `26.10/00__add_memo_share_view_limit.sql` migration per driver adding `view_limit` (nullable integer) and `view_count` (integer, not null, default 0) to `memo_share`
  - each driver's `LATEST.sql` gains the same columns
  - each driver's create inserts `view_limit` when set; list and get select both columns
  - each driver implements `ConsumeMemoShareView` as 1 conditional UPDATE and returns whether 1 row changed
  - fix any store migration test that pins the latest schema version
- Acceptance:
  - store test (`DRIVER=sqlite`): a share with limit 2 is consumed twice and the third consume returns false; a share with no limit keeps consuming; list returns the count and limit
  - `DRIVER=sqlite go test ./store/...` passes; slice is GREEN
- Out of scope:
  - API validation and the web panel; running the MySQL and PostgreSQL tests
- Covers: req-count-views, req-limit-reached, req-migrations, req-list-counts
- Writes: store/db/sqlite/memo_share.go, store/db/mysql/memo_share.go, store/db/postgres/memo_share.go, store/migration/, store/test/memo_share_test.go, store/test/migrator_test.go, store/test/migrator_upgrade_test.go, store/test/migrator_stable_upgrade_test.go, store/test/migrator_guardrail_test.go, store/schema_version_test.go, store/memo_share_test.go
- Tests: store/test/memo_share_test.go

### share-view-limit-api
Validate the limit on create, count views on resolve and return them on list.
- Deps: share-view-limit-store · Gate: slice · estLines: 160
- Why: spec items 1 to 4: INVALID_ARGUMENT outside 1 to 1000, a counted successful resolve, NOT_FOUND once used up, counts in the list.
- Scope:
  - `CreateMemoShare` rejects a `view_limit` outside 1 to 1000 with INVALID_ARGUMENT and stores it
  - `GetSharedMemo` calls `Store.ConsumeMemoShareView` after the memo read checks pass; false returns NOT_FOUND "not found"
  - `convertMemoShareFromStore` sets `view_limit` and `view_count`
- Acceptance:
  - API tests: limits 0 and 1001 return INVALID_ARGUMENT; a share with limit 1 resolves once then returns NOT_FOUND; list shows the count and limit; an expired share's failed resolve leaves the count at 0
  - `DRIVER=sqlite go test ./server/api/v1/...` passes; slice is GREEN
- Out of scope:
  - the file server's share-token attachment access
- Covers: req-limit-field, req-count-views, req-limit-reached, req-list-counts
- Writes: server/api/v1/memo_share_service.go, server/api/v1/test/memo_share_service_test.go
- Tests: server/api/v1/test/memo_share_service_test.go

### share-view-limit-web
Add the view-limit choice and the view-count text to the share panel.
- Deps: share-view-limit-contract · Gate: slice · estLines: 140
- Why: spec item 5: a no limit / 1 / 10 / 100 views choice beside expiry, and "N of M views" or "N views" per listed share.
- Scope:
  - `useCreateMemoShare` takes an optional `viewLimit` and sends it
  - `MemoSharePanel` adds a second `Select` beside the expiry one, and each row shows the view-count text from an exported `formatViewCount(share, t)` helper
  - strings under `memo.share` in every `web/src/locales/*.json`, English in `en.json`
- Acceptance:
  - vitest test for the view-count text: a share with limit 10 and count 3 reads "3 of 10 views", one without a limit and count 3 reads "3 views"
  - `pnpm run lint` and `pnpm run test` pass; slice is GREEN
- Out of scope:
  - other locales; the public shared-memo page
- Covers: req-panel-choice, req-panel-text
- Writes: web/src/components/MemoDetailSidebar/MemoSharePanel.tsx, web/src/hooks/useMemoShareQueries.ts, web/src/locales/, web/tests/memo-share-panel.test.tsx
- Tests: web/tests/memo-share-panel.test.tsx
