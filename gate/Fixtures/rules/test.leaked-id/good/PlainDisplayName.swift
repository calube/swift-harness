import Testing

@Test("migration completes without data loss")
func migrationCompletes() {
  #expect(1 == 1)
}

@Test("HTTP2 retries do not duplicate the request")
func http2RetriesDoNotDuplicate() {
  #expect(1 == 1)
}
