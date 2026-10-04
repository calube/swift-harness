import Foundation
import SwiftGateDomain

/// What a final pass adds around each flow's batch: a recording, and the logs beside it.
public struct QAFinalPass: Sendable {
  public var recorder: FinalPassRecorder
  public var evidence: EvidenceCollector

  public init(recorder: FinalPassRecorder, evidence: EvidenceCollector) {
    self.recorder = recorder
    self.evidence = evidence
  }
}

/// Records 1 flow's batch under the 1-slot `sim-record` lock, since the Mac may hold 1 simulator
/// recording at a time: the batch starts with `record start`, so the video and the steps share
/// the batch's clock, then `record stop` and `record contact-sheet` over the video.
public struct FinalPassRecorder: Sendable {
  /// The machine-wide lock's name; its capacity is 1.
  public static let lockName = "sim-record"
  /// How long a final pass waits for another final pass's recording before it runs its flow
  /// without video.
  public static let lockWait: Duration = .seconds(600)
  public static let videoFileName = "video.mp4"
  public static let sheetFileName = "sheet.png"

  public struct Dependencies: Sendable {
    public var agentDevice: any AgentDevice
    public var lock: any CountingLock
    public var clock: SimHoldClock
    public var lockWait: Duration

    public init(
      agentDevice: any AgentDevice, lock: any CountingLock, clock: SimHoldClock,
      lockWait: Duration = FinalPassRecorder.lockWait
    ) {
      self.agentDevice = agentDevice
      self.lock = lock
      self.clock = clock
      self.lockWait = lockWait
    }
  }

  private let dependencies: Dependencies

  public init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  /// Runs `batch` with a `record start` first, then `record stop` and the contact sheet. A
  /// `record start` the Mac refuses as busy is retried per ``RecordingRetry``; past its bound, or
  /// on any other refusal, `batch` runs without recording and the video reads `unverified`.
  ///
  /// - Parameters:
  ///   - batch: runs the flow's batch, with a `record start` to the given path first when it
  ///     isn't `nil`.
  ///   - directory: the flow's folder, which the video and the sheet go in.
  ///   - relativeDirectory: `directory` relative to the run directory.
  public func record(
    on target: AgentDeviceTarget, directory: URL, relativeDirectory: String,
    _ batch: @Sendable (_ recordTo: String?) async -> BatchFlowOutcome
  ) async -> (outcome: BatchFlowOutcome, recording: QAFlowRecording) {
    (await batch(nil), QAFlowRecording())
  }
}
