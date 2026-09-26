This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

Prompt: design doc `docs/library/designs/bulk-import.md`, researched at commit
4ada6b2c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a.

# Research lane pack: prior-decisions

## Frame answers

- Import a user's whole reading history, up to 10,000 books, in one step.

## Earlier designs

- `docs/library/designs/book-cache.md`, status `approved`: "Books are stored with GRDB in `library.sqlite`."

## Existing claims (`docs/library/designs/book-cache.evidence/claims.jsonl`, grep "batch insert")

```json
{"id": "ev-grdb-batch-insert-ten-thousand-rows-fast", "lane": "packages", "text": "GRDB inserts 10,000 rows in one transaction in under 50 ms.", "citation": {"kind": "file", "loc": ".build/checkouts/GRDB.swift/README.md:L410-L410", "pin": "GRDB.swift@7.4.1", "quote": "Batch inserts in a single transaction are fast."}, "status": "refuted"}
```

## Lane brief

- What did earlier work establish about inserting many books at once with GRDB?
