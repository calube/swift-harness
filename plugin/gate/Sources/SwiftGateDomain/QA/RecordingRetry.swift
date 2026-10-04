import Foundation

/// How long a final pass waits for the Mac's 1 simulator recording when a recording outside the
/// harness holds it: another try every `interval`, until `bound` has passed since the first.
public enum RecordingRetry {
  public static let interval: Duration = .seconds(15)
  public static let bound: Duration = .seconds(300)

  public enum Decision: Sendable, Equatable {
    case retry(after: Duration)
    /// The flow runs without video, which reads `unverified`.
    case giveUp
  }

  /// What to do after a busy `record start`, `elapsed` after the first one. The last try lands
  /// on the bound itself.
  public static func decision(elapsed: Duration) -> Decision {
    elapsed >= bound ? .giveUp : .retry(after: min(interval, bound - elapsed))
  }
}

/// A kind of final-pass evidence. Closed: the report names it and the run viewer reads it.
public enum QAEvidenceKind: String, Sendable, Equatable, Codable, CaseIterable {
  case video
  case sheet
  case appLog
  case network
  case trace
  case osLog
  case container
  /// A kept XCUITest's activities, which its steps come from.
  case activities
}

/// Final-pass evidence 1 flow row didn't leave, and why. It never changes the row's result: a
/// row passes or fails on its assertions alone.
public struct QAEvidenceGap: Sendable, Equatable, Codable {
  public static let videoUnverifiedRuleID = "qa.video-unverified"
  public static let evidenceUnsavedRuleID = "qa.evidence-unsaved"

  public let row: Int
  public let kind: QAEvidenceKind
  public let reason: String

  public init(row: Int, kind: QAEvidenceKind, reason: String) {
    self.row = row
    self.kind = kind
    self.reason = reason
  }

  /// `qa.video-unverified` for a missing video, `qa.evidence-unsaved` for anything else; both
  /// nits.
  public var ruleID: String {
    kind == .video ? Self.videoUnverifiedRuleID : Self.evidenceUnsavedRuleID
  }
}

/// Why a final pass left a flow without its video or its contact sheet. Closed: the `qa.flow`
/// event carries it, and events hold closed values, never tool output.
public enum QARecordingGapReason: String, Sendable, Equatable, Codable, CaseIterable {
  /// A recording outside the harness held the Mac past ``RecordingRetry/bound``.
  case recorderBusy
  /// Another final pass held the `sim-record` slot past the wait.
  case recordLockTimedOut
  /// `record start` or `record stop` failed for another reason.
  case recordFailed
  /// `record contact-sheet` failed on the video.
  case sheetFailed
  /// A kept XCUITest left no screen recording in its result bundle.
  case noVideoAttachment
}

/// 1 missing video or sheet: its reason, and the detail the report names.
public struct QARecordingGap: Sendable, Equatable {
  public let reason: QARecordingGapReason
  public let detail: String

  public init(reason: QARecordingGapReason, detail: String) {
    self.reason = reason
    self.detail = detail
  }
}

/// What a final pass's recording of 1 flow left.
public struct QAFlowRecording: Sendable, Equatable {
  /// Run-relative; `nil` when no video was made.
  public var video: String?
  /// Run-relative; `nil` when no contact sheet was made.
  public var sheet: String?
  /// When the video's first frame came, on the batch's clock; `nil` with no video.
  public var videoStartMs: Int?
  public var videoGap: QARecordingGap?
  public var sheetGap: QARecordingGap?

  public init(
    video: String? = nil, sheet: String? = nil, videoStartMs: Int? = nil,
    videoGap: QARecordingGap? = nil, sheetGap: QARecordingGap? = nil
  ) {
    self.video = video
    self.sheet = sheet
    self.videoStartMs = videoStartMs
    self.videoGap = videoGap
    self.sheetGap = sheetGap
  }

  /// The report's gaps for row `row`.
  public func gaps(row: Int) -> [QAEvidenceGap] {
    [(QAEvidenceKind.video, videoGap), (.sheet, sheetGap)].compactMap { kind, gap in
      gap.map { QAEvidenceGap(row: row, kind: kind, reason: $0.detail) }
    }
  }
}

extension QAFlowRecord {
  /// This record with the recording's video, sheet and gap reasons, and, when there is a video,
  /// each step's `offsetMs` moved from the batch's start onto the video's clock.
  public func recorded(_ recording: QAFlowRecording) -> QAFlowRecord {
    let shift = recording.video == nil ? 0 : recording.videoStartMs ?? 0
    return QAFlowRecord(
      source: source,
      steps: steps.map { step in
        QAFlowStep(
          n: step.n, label: step.label, offsetMs: max(0, step.offsetMs - shift), ok: step.ok)
      },
      video: recording.video, sheet: recording.sheet,
      videoUnverified: recording.videoGap?.reason, sheetUnverified: recording.sheetGap?.reason,
      flow: flow, test: test)
  }
}
