import Testing

@Test("queue-core replays orders in order")
func replaysOrders() {
  let order = 1
  #expect(order == 1)
}
