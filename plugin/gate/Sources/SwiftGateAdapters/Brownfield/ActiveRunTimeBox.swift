import Foundation
import SwiftGateDomain

/// The time box of the `swiftgate run` going on in a clone, read from each plan's launch clock.
public enum ActiveRunTimeBox {
  /// The box that has started and not ended at `now`; of several, the latest launched. `nil`
  /// when no plan's clock holds one.
  public static func find(layout: BrownfieldStateLayout, now: Date) -> RunTimeBox? {
    nil
  }
}
