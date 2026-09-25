import Dependencies

struct Dice {
  @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator
  func roll() -> Int {
    withRandomNumberGenerator { rng in Int.random(in: 1...6, using: &rng) }
  }
  func deal(_ cards: [Int], rng: inout some RandomNumberGenerator) -> [Int] {
    cards.shuffled(using: &rng)
  }
  let note = "Int.random(in:) without using: is banned"
}
