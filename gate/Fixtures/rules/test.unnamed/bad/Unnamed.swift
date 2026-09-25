import Testing

@Test func total() {
  #expect(Cart().total == 0)
}

@Test(.tags(.pricing)) func tagged() {
  #expect(Cart().total == 0)
}

@Test(arguments: [1, 2]) func parameterized(count: Int) {
  #expect(Cart(count: count).count == count)
}
