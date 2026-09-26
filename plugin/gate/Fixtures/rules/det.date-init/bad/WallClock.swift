import Foundation

struct Stamp {
  func make() -> Date { Date() }
  func makeExplicit() -> Date { Date.init() }
  var now: Date { Date.now }
  func later() -> Date { Date(timeIntervalSinceNow: 60) }
  func label() -> String { "created \(Foundation.Date())" }
}
