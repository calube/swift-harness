import Foundation
import SwiftGateDomain

/// The time box of the `swiftgate run` going on in a clone, read from each plan's launch clock.
public enum ActiveRunTimeBox {
  /// The box that has started and not ended at `now`; of several, the latest launched. `nil`
  /// when no plan's clock holds one. A clock that can't be read is skipped: a gate with no box
  /// runs to its measured bounds.
  public static func find(layout: BrownfieldStateLayout, now: Date) -> RunTimeBox? {
    let plans =
      (try? FileManager.default.contentsOfDirectory(
        at: layout.plansDirectory, includingPropertiesForKeys: nil)) ?? []
    return
      plans
      .compactMap { plan -> RunTimeBox? in
        guard let data = try? Data(contentsOf: plan.appending(path: RunClock.fileName)) else {
          return nil
        }
        return try? RunClock.decode(data).runTimeBox
      }
      .filter { $0.startedAt <= now && now < $0.deadlines.endsAt }
      .max { $0.startedAt < $1.startedAt }
  }
}
