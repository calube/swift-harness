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
    let raw: RawActivities
    do {
      raw = try JSONDecoder().decode(RawActivities.self, from: data)
    } catch {
      throw XcresultParseError(detail: "activities: \(error)")
    }
    return XcresultActivities(
      testIdentifier: raw.testIdentifier,
      runs: raw.testRuns.map { ($0.activities ?? []).map(\.activity) })
  }

  private struct RawActivities: Decodable {
    let testIdentifier: String
    let testRuns: [RawRun]
  }

  private struct RawRun: Decodable {
    let activities: [RawNode]?
  }

  private struct RawNode: Decodable {
    let title: String
    let startTime: Double?
    let isAssociatedWithFailure: Bool
    let childActivities: [RawNode]?

    var activity: XcresultActivity {
      XcresultActivity(
        title: title, startTime: startTime, failed: isAssociatedWithFailure,
        children: (childActivities ?? []).map(\.activity))
    }
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
    let raw: [RawTest]
    do {
      raw = try JSONDecoder().decode([RawTest].self, from: data)
    } catch {
      throw XcresultParseError(detail: "attachments manifest: \(error)")
    }
    return raw.flatMap { test in
      test.attachments.map {
        XcresultAttachment(
          testIdentifier: test.testIdentifier, exportedFileName: $0.exportedFileName,
          name: $0.suggestedHumanReadableName, timestamp: $0.timestamp)
      }
    }
  }

  private struct RawTest: Decodable {
    let testIdentifier: String
    let attachments: [RawAttachment]
  }

  private struct RawAttachment: Decodable {
    let exportedFileName: String
    let suggestedHumanReadableName: String
    let timestamp: Double?
  }
}

/// A kept flow's `qa.flow` record from what its XCUITest left in the result bundle.
public enum XCUITestFlow {
  /// The screen recording a keep-always test plan attaches to `test`; `nil` when the test kept
  /// none.
  public static func video(of test: String, in attachments: [XcresultAttachment])
    -> XcresultAttachment?
  {
    attachments.first {
      $0.testIdentifier == test && $0.exportedFileName.lowercased().hasSuffix(".mp4")
    }
  }

  /// The longest label a step keeps, in characters, well under the event guard's limit.
  static let maxLabelLength = 200

  /// A title's first line, cut to ``maxLabelLength``: a failure's message may run long or span
  /// lines, and the `qa.flow` event guard drops a payload holding either.
  static func label(_ title: String) -> String {
    let line = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return line.count > maxLabelLength ? String(line.prefix(maxLabelLength)) + "…" : line
  }

  /// The activities XCTest adds around every test's body.
  static func isFraming(_ activity: XcresultActivity) -> Bool {
    activity.title.hasPrefix("Start Test at ") || activity.title == "Set Up"
      || activity.title == "Tear Down"
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
    guard let run = activities.runs.last else { return [] }
    let origin = videoStart ?? run.compactMap(\.startTime).first ?? 0
    var steps: [QAFlowStep] = []
    for activity in run where activity.failed || !isFraming(activity) {
      let offset = activity.startTime.map { max(0, Int((($0 - origin) * 1000).rounded())) }
      steps.append(
        QAFlowStep(
          n: steps.count + 1, label: label(activity.title),
          offsetMs: offset ?? steps.last?.offsetMs ?? 0, ok: !activity.failed))
      if activity.failed { return steps }
    }
    if !passed, let last = steps.popLast() {
      steps.append(QAFlowStep(n: last.n, label: last.label, offsetMs: last.offsetMs, ok: false))
    }
    return steps
  }
}
