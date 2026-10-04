# View limit on memo share links

Memo share links can already expire at a set time. Owners also want a link that stops working after it has
been opened a set number of times, for example a link meant to be read once.

## What to build

1. A share link can carry an optional view limit, a whole number from 1 to 1000. A share created without one
   behaves exactly as today. A limit outside 1 to 1000 is rejected with `INVALID_ARGUMENT`.
2. Each time a share token resolves to its memo, that share's view count goes up by 1. Only a successful
   resolve counts: an invalid, expired or revoked token counts nothing.
3. Once a share's view count reaches its limit, the token stops resolving and returns `NOT_FOUND`, the same
   answer an expired link gives. Two resolves racing for the last view must not both succeed.
4. Listing a memo's shares returns each share's view count and its limit, when it has one.
5. The share panel in the web client gains a view-limit choice next to the expiry choice: no limit, 1 view,
   10 views or 100 views. Each listed share shows "N of M views" when it has a limit, and "N views" when it
   doesn't. New strings go in the English locale; other locales may fall back to English.

## Constraints

- The store change needs a migration for every driver the repository supports (SQLite, MySQL and
  PostgreSQL), and the latest schema files must match.
- The API change is a new optional field on the share message. Regenerate the Go and TypeScript code from the
  protos with the repository's own `buf generate`; never hand-edit generated files.
- Existing shares keep working after the migration, with no limit and a view count of 0.

## Tests

- A Go store test, run with `DRIVER=sqlite`, that creates a share with a limit of 2, resolves it twice, and
  sees the third resolve fail; and one that shows a share without a limit keeps resolving.
- A Go API test for the limit validation and for `NOT_FOUND` once the limit is used up.
- A vitest test for the panel's view-count text, with and without a limit.

Go tests in this repository run with `DRIVER=sqlite`; MySQL and PostgreSQL need containers this machine
doesn't have, so their migrations are written but not run here.
