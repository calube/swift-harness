import Foundation

enum Probe_ev_string_has_prefix_exists {
  static func run() -> Bool {
    "swiftgate".hasPrefix("swift")
  }
}
