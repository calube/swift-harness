import Foundation

struct Item {
  let id = UUID()
  static func make() -> UUID { UUID.init() }
}
