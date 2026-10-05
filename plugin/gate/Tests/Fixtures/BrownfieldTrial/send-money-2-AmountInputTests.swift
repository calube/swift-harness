import AppCore
import Foundation
import Testing

struct AmountInputTests {
  private func keyed(_ text: String) -> AmountInput {
    var input = AmountInput()
    for character in text {
      if character == "." {
        input.press(.decimalPoint)
      } else if let digit = character.wholeNumberValue {
        input.press(.digit(digit))
      }
    }
    return input
  }

  @Test("a third decimal digit is ignored — catches an uncapped fraction")
  func thirdDecimalDigitIgnored() {
    let input = keyed("1.234")
    #expect(input.text == "1.23")
    #expect(input.amount == Decimal(string: "1.23"))
  }

  @Test("a second decimal point is ignored — catches repeated points")
  func secondDecimalPointIgnored() {
    let input = keyed("1.2.5")
    #expect(input.text == "1.25")
  }

  @Test("007 reads 7 — catches leading zeros kept")
  func leadingZerosDropped() {
    let input = keyed("007")
    #expect(input.text == "7")
    #expect(input.amount == 7)
  }

  @Test("zeros stay a single zero before a point — catches stripping the zero in 0.5")
  func zeroBeforePoint() {
    #expect(keyed("00.5").text == "0.5")
    #expect(keyed("0").amount == 0)
  }

  @Test("delete removes the last key and does nothing when empty — catches a crash or no-op delete")
  func deleteRemovesLast() {
    var input = keyed("12.5")
    input.press(.delete)
    #expect(input.text == "12.")
    input.press(.delete)
    input.press(.delete)
    #expect(input.text == "1")
    input.press(.delete)
    input.press(.delete)
    #expect(input.text.isEmpty)
    #expect(input.amount == 0)
  }

  @Test("a leading decimal point reads 0. and shows $0.00 — catches an empty-text point")
  func leadingDecimalPoint() {
    let input = keyed(".")
    #expect(input.text == "0.")
    #expect(input.formatted == "$0.00")
    #expect(keyed(".5").amount == Decimal(string: "0.5"))
  }

  @Test("formatting shows dollars with 2 fraction digits — catches missing padding or grouping")
  func formatting() {
    #expect(AmountInput().formatted == "$0.00")
    #expect(keyed("12.5").formatted == "$12.50")
    #expect(keyed("7").formatted == "$7.00")
    #expect(keyed("1234.56").formatted == "$1,234.56")
  }

  @Test("continue needs more than zero and at most the balance — catches off-by-one limits")
  func canContinueBounds() {
    let balance = Decimal(string: "250.00")!
    #expect(!AmountInput.canContinue(amount: 0, balance: balance))
    #expect(AmountInput.canContinue(amount: Decimal(string: "0.01")!, balance: balance))
    #expect(AmountInput.canContinue(amount: balance, balance: balance))
    #expect(!AmountInput.canContinue(amount: Decimal(string: "250.01")!, balance: balance))
  }
}
