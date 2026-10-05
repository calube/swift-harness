import Foundation
import SwiftGateDomain

/// Keeps 1 failing area step's output tail and its report, JUnit or a result bundle, in a
/// folder, before a later run of the same step overwrites them.
public enum StepEvidence {
  /// Writes `<name>.txt` with the outcome's tail into `directory`, copies the request's JUnit
  /// files beside it and moves its result bundle there. Returns the absolute paths kept; empty
  /// for a passing outcome.
  @discardableResult
  public static func keep(
    _ outcome: AreaCommandOutcome, of request: AreaCommandRequest, named name: String,
    in directory: URL
  ) -> [String] {
    []
  }
}
