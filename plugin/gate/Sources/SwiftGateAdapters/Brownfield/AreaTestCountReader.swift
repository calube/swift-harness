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
    if let junit = request.junitPath, let report = JUnitReportFiles.read(at: junit),
      let counts = AreaOutcomeReading.junitCounts(report)
    {
      return counts
    }
    guard let bundle = request.resultBundlePath, FileManager.default.fileExists(atPath: bundle),
      let contents = try? await xcresults.read(bundlePath: bundle),
      let report = XcresultTestReport.junit(fromTests: contents.testResults)
    else { return nil }
    return AreaOutcomeReading.junitCounts(report)
  }
}
