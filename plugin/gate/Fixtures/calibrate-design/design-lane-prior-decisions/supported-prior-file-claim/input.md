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
{"id": "ev-grdb-insert-in-write-transaction", "lane": "packages", "text": "GRDB's DatabaseWriter.swift documents that it executes database operations in a transaction.", "citation": {"kind": "file", "loc": ".build/checkouts/GRDB.swift/GRDB/Core/DatabaseWriter.swift:L88-L88", "pin": "GRDB.swift@7.4.1", "quote": "/// Executes database operations in a transaction."}, "status": "supported"}
```

## Lane brief

- What did earlier work establish about inserting many books at once with GRDB?
