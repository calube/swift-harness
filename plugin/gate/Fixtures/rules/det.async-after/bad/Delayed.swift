import Foundation

struct Banner {
  func hideLater(_ hide: @escaping @Sendable () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { hide() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: hide)
  }
}
