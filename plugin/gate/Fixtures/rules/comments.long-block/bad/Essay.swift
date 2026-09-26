func sync() {
  // First we read the local store.
  // Then we diff it against the server snapshot.
  // Then we upload the local-only rows.
  // Finally we download the server-only rows.
  run()
}
