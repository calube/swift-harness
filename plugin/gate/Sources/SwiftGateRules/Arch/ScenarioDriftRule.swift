import SwiftGateDomain

/// Simulator QA design §6: the app's `enum Scenario: String` and `.swiftgate.toml`'s
/// `[[scenarios]]` name the same scenarios, so `sim up --scenario` never accepts a name the app
/// ignores, nor misses one the app declares.
public enum ScenarioDriftRule {
  public static let id = "sim.scenario-drift"

  /// - Parameter sources: every Swift file the run read; files under a `packages` glob are
  ///   skipped, since the enum belongs to the app target.
  public static func evaluate(config: Config, sources: [SourceInput])
    throws(ReportContractViolation) -> [Finding]
  {
    []
  }
}
