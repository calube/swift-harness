import Testing

@Test("throwing test — catches a decode failure")
func decode() throws {
  let cart = try Cart(json: "{}")
  #expect(cart.items.isEmpty)
}

@Test("catch records the issue — catches a save failure")
func save() {
  do {
    try Store().save(Cart())
  } catch {
    Issue.record(error)
  }
}

@Test("try? inside an assertion states the expectation — catches invalid input accepted")
func rejects() {
  #expect((try? Cart(json: "nope")) == nil)
}

func helperOutsideTests() {
  _ = try? Store().load()
}

@Test("cleanup in defer may fail quietly — catches a leftover temp directory breaking the next run")
func cleanup() throws {
  let directory = try TemporaryDirectory()
  defer { try? directory.remove() }
  #expect(try directory.isEmpty())
}
