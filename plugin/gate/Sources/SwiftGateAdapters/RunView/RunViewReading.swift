import Foundation
import SwiftGateDomain

/// Reads what ``RunViewBuilder`` folds for 1 build run.
public protocol RunViewReading: Sendable {
  /// Every store's events of `buildRun`, its build join, its plan's ledger, requirements and
  /// briefs. A file that doesn't read is a damage row, never a silent gap.
  func read(buildRun: String) throws -> RunViewInput
}
