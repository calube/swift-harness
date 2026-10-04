import Foundation

/// 1 node of a UI test's activity tree, as `xcresulttool get test-results activities` lists it.
public struct XcresultActivity: Sendable, Equatable {
  public let title: String
  /// Seconds since 1970; `nil` when the node carries none.
  public let startTime: Double?
  /// `isAssociatedWithFailure`.
  public let failed: Bool
  public let children: [XcresultActivity]

  public init(title: String, startTime: Double?, failed: Bool, children: [XcresultActivity] = []) {
    self.title = title
    self.startTime = startTime
    self.failed = failed
    self.children = children
  }
}

/// 1 UI test's activities (Xcode 26.2, schema 0.1.0): 1 tree per run of the test.
public struct XcresultActivities: Sendable, Equatable {
  public let testIdentifier: String
  /// The top-level activities of each run, in run order.
  public let runs: [[XcresultActivity]]

  public init(testIdentifier: String, runs: [[XcresultActivity]]) {
    self.testIdentifier = testIdentifier
    self.runs = runs
  }

  public static func parse(_ data: Data) throws(XcresultParseError) -> XcresultActivities {
    XcresultActivities(testIdentifier: "", runs: [])
  }
}

/// 1 exported attachment, as `xcresulttool export attachments` lists it in `manifest.json`.
public struct XcresultAttachment: Sendable, Equatable {
  public let testIdentifier: String
  /// The file's name in the export directory.
  public let exportedFileName: String
  /// `suggestedHumanReadableName`, such as `Screen Recording <date>.mp4`.
  public let name: String
  /// Seconds since 1970; for a screen recording, its first frame.
  public let timestamp: Double?

  public init(testIdentifier: String, exportedFileName: String, name: String, timestamp: Double?) {
    self.testIdentifier = testIdentifier
    self.exportedFileName = exportedFileName
    self.name = name
    self.timestamp = timestamp
  }

  /// Every attachment of every test the manifest lists.
  public static func parseManifest(_ data: Data) throws(XcresultParseError) -> [XcresultAttachment]
  {
    []
  }
}

/// A kept flow's `qa.flow` record from what its XCUITest left in the result bundle.
public enum XCUITestFlow {
  /// The screen recording a keep-always test plan attaches to `test`; `nil` when the test kept
  /// none.
  public static func video(of test: String, in attachments: [XcresultAttachment])
    -> XcresultAttachment?
  {
    nil
  }

  /// The test's last run as flow steps: each top-level activity in order, without XCTest's own
  /// framing (`Start Test at …`, `Set Up`, `Tear Down`) unless a failure is filed under it, up to
  /// and including the first step a failure is filed under.
  ///
  /// - Parameters:
  ///   - videoStart: the recording's first frame; offsets count from it, else from the run's first
  ///     activity.
  ///   - passed: whether the test passed; a failed test whose activities name no failing step
  ///     marks its last step not ok.
  public static func steps(_ activities: XcresultActivities, videoStart: Double?, passed: Bool)
    -> [QAFlowStep]
  {
    []
  }
}
