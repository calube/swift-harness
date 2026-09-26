import Dependencies
import Foundation

struct Stamp {
  @Dependency(\.date.now) var now
  // Calling Date() here would make tests depend on the wall clock.
  let hint = "never call Date() or Date.now in Core"
  func epoch() -> Date { Date(timeIntervalSince1970: 0) }
  func make() -> Date { now }
}
