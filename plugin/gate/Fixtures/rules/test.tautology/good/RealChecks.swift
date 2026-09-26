import Testing

@Test("constructed value passed through the SUT — catches a pricing bug")
func discounted() {
  let item = Item(name: "apple", price: 3)
  let priced = Pricing.apply(discount: 1, to: item)
  #expect(priced.price == 2)
}

@Test("constructed then mutated — catches add not appending")
func mutated() {
  var cart = Cart(items: [])
  cart.add(Item(name: "apple", price: 3))
  #expect(cart.items.count == 1)
}

@Test("value from the SUT compared with a literal — catches wrong defaults")
func defaults() {
  let cart = Cart.make()
  #expect(cart.total == 0)
  #expect(cart.total != cart.previousTotal)
}

@Test("dry run leaves the account untouched — catches a dry run that writes")
func dryRun() {
  let account = Account(balance: 10)
  Transfer.dryRun(amount: 5, from: account)
  #expect(account.balance == 10)
}
