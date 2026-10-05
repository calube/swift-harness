import AccountClient
import Foundation
import Testing

struct AccountClientTests {
  @Test("the fake starts at $250.00 with 8 contacts — catches a wrong seed")
  func seed() async throws {
    let client = AccountClient.inMemory()

    #expect(try await client.balance() == Decimal(string: "250.00"))
    #expect(try await client.contacts().count == 8)
  }

  @Test("a send lowers the fake's balance by the exact amount — catches float drift and no debit")
  func sendDebits() async throws {
    let client = AccountClient.inMemory()
    let contact = Contact.samples[2]

    let payment = try await client.send(amount: Decimal(string: "0.10")!, to: contact)
    _ = try await client.send(amount: Decimal(string: "0.20")!, to: contact)

    #expect(payment.amount == Decimal(string: "0.10"))
    #expect(payment.contact == contact)
    #expect(try await client.balance() == Decimal(string: "249.70"))
  }

  @Test("a failing fake throws and keeps the balance — catches a debit on a failed send")
  func failingSendKeepsBalance() async throws {
    let client = AccountClient.inMemory(sendFailure: .always)

    await #expect(throws: AccountError.sendFailed) {
      try await client.send(amount: 10, to: Contact.samples[0])
    }
    #expect(try await client.balance() == 250)
  }

  @Test("a send above the balance throws — catches an overdraft")
  func overdraftRefused() async throws {
    let client = AccountClient.inMemory(balance: 5)

    await #expect(throws: AccountError.insufficientFunds) {
      try await client.send(amount: Decimal(string: "5.01")!, to: Contact.samples[0])
    }
    #expect(try await client.balance() == 5)
  }
}
