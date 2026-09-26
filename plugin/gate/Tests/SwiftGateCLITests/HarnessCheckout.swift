import Foundation
import SwiftGateTestSupport

extension Fixture {
  /// The contributor checkout around the plugin: `examples/`, `tests/` and the repository's own
  /// `.swiftgate.toml`. `checkoutRoot` is the plugin directory that holds `gate/`.
  static var harnessCheckout: URL { checkoutRoot.deletingLastPathComponent() }
}
