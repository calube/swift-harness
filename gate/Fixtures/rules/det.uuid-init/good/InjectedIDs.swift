import Dependencies
import Foundation

struct Item {
  @Dependency(\.uuid) var uuid
  let fixed = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
  let note = "UUID() is banned here"
  func make() -> UUID { uuid() }
}
