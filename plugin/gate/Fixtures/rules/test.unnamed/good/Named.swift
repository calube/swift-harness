import Testing

@Test("empty cart total is zero — catches wrong default") func total() {
  #expect(Cart().total == 0)
}

@Test("tagged and named — catches wrong default", .tags(.pricing))
func tagged() {
  #expect(Cart().total == 0)
}

@Test("count survives init — catches dropped items", arguments: [1, 2])
func parameterized(count: Int) {
  #expect(Cart(count: count).count == count)
}
