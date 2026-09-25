import ConcurrencyExtras
import LogClient
import Testing

struct LogClientTests {
  @Test("disabled levels never build their attributes — catches logging cost paid when disabled")
  func disabledLevelSkipsAttributeConstruction() {
    let records = LockIsolated<[LogRecord]>([])
    let client = LogClient(
      isEnabled: { level, _ in level == .error },
      emit: { record in records.withValue { $0.append(record) } }
    )
    var attributeBuilds = 0
    func expensiveAttributes() -> [LogAttribute] {
      attributeBuilds += 1
      return [.public("k", "v")]
    }

    client.log(.debug, "dropped", category: "Test", expensiveAttributes())
    client.log(.error, "kept", category: "Test", expensiveAttributes())

    #expect(attributeBuilds == 1)
    #expect(records.value.map(\.message) == ["kept"])
  }

  @Test("a log call emits level, category, message and tagged attributes — catches lost log fields")
  func emitsFullRecord() {
    let records = LockIsolated<[LogRecord]>([])
    var client = LogClient.testValue
    client.emit = { record in records.withValue { $0.append(record) } }

    client.log(
      .error, "fact request failed", category: "Counter",
      [.public("attempt", 3), .private("email", "a@b.c")])

    #expect(
      records.value == [
        LogRecord(
          level: .error,
          category: "Counter",
          message: "fact request failed",
          attributes: [
            LogAttribute(key: "attempt", value: "3", privacy: .public),
            LogAttribute(key: "email", value: "a@b.c", privacy: .private),
          ]
        )
      ]
    )
  }

  @Test(
    "the test value accepts every level — catches an unimplemented logger failing unrelated tests")
  func testValueIsEnabledNoop() {
    #expect(LogClient.testValue.isEnabled(.debug, "Any"))
    LogClient.testValue.log(.fault, "anything", category: "Any")
  }
}
