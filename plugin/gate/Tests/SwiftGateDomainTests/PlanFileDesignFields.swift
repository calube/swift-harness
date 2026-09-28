import SwiftGateDomain

/// A design plan's fields read off the plan, for tests that expect a design plan. A spec-page
/// plan has none, so `design` reads as `""` and an expectation of a real design fails on it.
extension PlanFile {
  var design: String { designSource?.design ?? "" }
}
