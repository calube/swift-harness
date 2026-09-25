import Foundation

struct Dice {
  func roll() -> Int { Int.random(in: 1...6) }
  func coin() -> Bool { Bool.random() }
  func deal(_ cards: [Int]) -> [Int] { cards.shuffled() }
  func pick(_ cards: [Int]) -> Int? { cards.randomElement() }
  func raw() -> UInt64 {
    var generator = SystemRandomNumberGenerator()
    return generator.next()
  }
  func legacy() -> UInt32 { arc4random_uniform(6) }
}
