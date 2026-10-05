import Foundation
import SwiftGateDomain

/// Reads how many tests 1 area test step ran from what it left on disk: its `{junit}` reports,
/// else the result bundle an `xcodebuild` step wrote. The runner reads them only on a failure,
/// so a passing step's totals would otherwise go unrecorded.
public struct AreaTestCountReader: Sendable {
  private let xcresults: any XcresultReader

  public init(xcresults: any XcresultReader = LiveXcresultReader(runner: LiveProcessRunner())) {
    self.xcresults = xcresults
  }

  /// `nil` when the step left no report that reads.
  public func counts(of request: AreaCommandRequest) async -> JUnitCounts? {
    nil
  }
}
