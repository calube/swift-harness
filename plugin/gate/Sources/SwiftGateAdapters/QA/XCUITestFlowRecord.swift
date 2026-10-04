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
    var name = test.hasSuffix("()") ? String(test.dropLast(2)) : test
    name = name.replacingOccurrences(of: "/", with: "-")
    return String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
  }

  public func record(_ tests: [KeptFlowTest], bundlePath: String, runDirectory: URL) async
    -> KeptFlows
  {
    var flows = KeptFlows()
    for test in tests {
      let (record, gaps) = await recordOne(test, bundlePath: bundlePath, runDirectory: runDirectory)
      if let record { flows.records.append(record) }
      flows.gaps += gaps
    }
    return flows
  }

  private func recordOne(_ test: KeptFlowTest, bundlePath: String, runDirectory: URL) async
    -> (QAFlowRecord?, [KeptFlowGap])
  {
    let relative = "\(Self.directory)/\(Self.folderName(test: test.identifier))"
    let folder = runDirectory.appending(path: relative, directoryHint: .isDirectory)
    let files = FileManager.default
    var gaps: [KeptFlowGap] = []
    func gap(_ kind: QAEvidenceKind, _ detail: String) {
      gaps.append(KeptFlowGap(test: test.identifier, kind: kind, detail: detail))
    }
    do {
      try files.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      gap(.activities, "\(relative) couldn't be made: \(error.localizedDescription)")
      return (nil, gaps)
    }

    let activities: XcresultActivities
    do {
      let data = try await reader.activities(bundlePath: bundlePath, testID: test.identifier)
      try? data.write(to: folder.appending(path: Self.activitiesFileName))
      activities = try XcresultActivities.parse(data)
    } catch let error as XcresultReadError {
      gap(.activities, error.message)
      return (nil, gaps)
    } catch {
      gap(.activities, "\(error)")
      return (nil, gaps)
    }

    var video: String?
    var videoStart: Double?
    var videoGap: QARecordingGapReason?
    var sheet: String?
    var sheetGap: QARecordingGapReason?
    let export = folder.appending(path: "attachments", directoryHint: .isDirectory)
    do throws(XcresultReadError) {
      let manifest = try await reader.exportAttachments(
        bundlePath: bundlePath, testID: test.identifier, to: export.path)
      let attachments = (try? XcresultAttachment.parseManifest(manifest)) ?? []
      if let found = XCUITestFlow.video(of: test.identifier, in: attachments) {
        let target = folder.appending(path: Self.videoFileName)
        try? files.removeItem(at: target)
        do {
          try files.moveItem(at: export.appending(path: found.exportedFileName), to: target)
          video = "\(relative)/\(Self.videoFileName)"
          videoStart = found.timestamp
        } catch {
          gap(.video, "the screen recording wasn't saved: \(error.localizedDescription)")
          videoGap = .noVideoAttachment
        }
      } else {
        gap(
          .video,
          "\(test.identifier) kept no screen recording: is the test plan's "
            + "uiTestingScreenshotsLifetime keepAlways?")
        videoGap = .noVideoAttachment
      }
    } catch {
      gap(.video, error.message)
      videoGap = .noVideoAttachment
    }
    try? files.removeItem(at: export)

    if let video {
      let sheetFile = folder.appending(path: Self.sheetFileName)
      do throws(AgentDeviceError) {
        _ = try await agentDevice.contactSheet(
          video: runDirectory.appending(path: video).path, to: sheetFile.path)
        if files.fileExists(atPath: sheetFile.path) {
          sheet = "\(relative)/\(Self.sheetFileName)"
        } else {
          gap(.sheet, "record contact-sheet wrote no \(Self.sheetFileName)")
          sheetGap = .sheetFailed
        }
      } catch {
        gap(.sheet, error.message)
        sheetGap = .sheetFailed
      }
    }

    let record = QAFlowRecord(
      source: .xcuitest,
      steps: XCUITestFlow.steps(activities, videoStart: videoStart, passed: test.passed),
      video: video, sheet: sheet, videoUnverified: videoGap, sheetUnverified: sheetGap,
      flow: test.flow, test: test.identifier)
    if let data = try? record.encoded() {
      try? data.write(to: folder.appending(path: QAFlowRecord.fileName))
    }
    return (record, gaps)
  }
}
