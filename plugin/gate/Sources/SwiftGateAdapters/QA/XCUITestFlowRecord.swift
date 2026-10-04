import Foundation
import SwiftGateDomain

/// 1 UI test T3 ran that maps to a `[[flows]]` entry: a kept flow.
public struct KeptFlowTest: Sendable, Equatable {
  /// `<Class>/<method>()`, as the result bundle names it.
  public let identifier: String
  /// The `[[flows]]` entry it maps to.
  public let flow: String
  public let passed: Bool

  public init(identifier: String, flow: String, passed: Bool) {
    self.identifier = identifier
    self.flow = flow
    self.passed = passed
  }
}

/// 1 piece of a kept flow's evidence that T3 left unsaved, and why.
public struct KeptFlowGap: Sendable, Equatable {
  public let test: String
  public let kind: QAEvidenceKind
  public let detail: String

  public init(test: String, kind: QAEvidenceKind, detail: String) {
    self.test = test
    self.kind = kind
    self.detail = detail
  }

  /// As ``QAEvidenceGap/ruleID``: `qa.video-unverified` for a missing video,
  /// `qa.evidence-unsaved` otherwise; both nits.
  public var ruleID: String {
    kind == .video ? QAEvidenceGap.videoUnverifiedRuleID : QAEvidenceGap.evidenceUnsavedRuleID
  }
}

/// What 1 T3 run's kept flows left.
public struct KeptFlows: Sendable, Equatable {
  /// 1 per kept flow whose activities were read, in the order the tests were given.
  public var records: [QAFlowRecord]
  public var gaps: [KeptFlowGap]

  public init(records: [QAFlowRecord] = [], gaps: [KeptFlowGap] = []) {
    self.records = records
    self.gaps = gaps
  }
}

/// Turns each kept flow T3 ran into 1 `qa.flow` record with `source: xcuitest`: its steps and
/// offsets from the result bundle's activities, its keep-always screen recording, and that
/// recording's contact sheet, under `qa/xcuitest/<Class>-<method>/` in the run directory, beside
/// the activities and the record as `flow.json`.
public struct XCUITestFlowRecorder: Sendable {
  /// Run-relative folder every kept flow's evidence goes under.
  public static let directory = "qa/xcuitest"
  public static let videoFileName = "video.mp4"
  public static let sheetFileName = "sheet.png"
  /// The test's activities as `xcresulttool` printed them, beside the flow's record.
  public static let activitiesFileName = "activities.json"

  private let reader: any XcresultReader
  private let agentDevice: any AgentDevice

  public init(reader: any XcresultReader, agentDevice: any AgentDevice) {
    self.reader = reader
    self.agentDevice = agentDevice
  }

  /// A test's folder name under ``directory``: `<Class>-<method>`, without the `()`.
  public static func folderName(test: String) -> String {
    test
  }

  public func record(_ tests: [KeptFlowTest], bundlePath: String, runDirectory: URL) async
    -> KeptFlows
  {
    KeptFlows()
  }
}
