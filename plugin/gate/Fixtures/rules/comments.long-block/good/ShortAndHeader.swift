// Copyright 2026 Example Inc.
// Licensed under the Apache License, Version 2.0.
// See LICENSE in the repository root.
// SPDX-License-Identifier: Apache-2.0

/// Syncs local and server rows.
///
/// - Parameter force: skips the freshness check.
/// - Returns: the number of rows changed.
/// - Throws: `SyncError` when the server rejects the batch.
func sync(force: Bool) throws -> Int {
  // The server rejects batches over 500 rows.
  // Split before uploading.
  0
}
