import Testing

@Test("try? hides the failure — catches nothing when decode throws")
func decode() {
  let cart = try? Cart(json: "{}")
  #expect(cart?.items.isEmpty == true)
}

@Test("empty catch — catches nothing when save throws")
func save() {
  do {
    try Store().save(Cart())
  } catch {
  }
  #expect(Store().count == 1)
}

@Test("catch that only prints — catches nothing when load throws")
func load() {
  do {
    #expect(try Store().load().count == 1)
  } catch {
    print(error)
  }
}
