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
    /// Whether a `record start` the Mac refuses as busy is retried per ``RecordingRetry``;
    /// without it the flow runs unrecorded at once.
    public var retriesBusyRecorder: Bool

    public init(
      agentDevice: any AgentDevice, lock: any CountingLock, clock: SimHoldClock,
      lockWait: Duration = FinalPassRecorder.lockWait, retriesBusyRecorder: Bool = true
    ) {
      self.agentDevice = agentDevice
      self.lock = lock
      self.clock = clock
      self.lockWait = lockWait
      self.retriesBusyRecorder = retriesBusyRecorder
    }
  }

  private let dependencies: Dependencies

  public init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  /// This recorder for a run that records only when it costs the flow nothing: it takes the
  /// `sim-record` slot only when the slot is free, and never waits out a busy Mac recorder.
  public func withoutWaiting() -> FinalPassRecorder {
    var dependencies = dependencies
    dependencies.lockWait = .zero
    dependencies.retriesBusyRecorder = false
    return FinalPassRecorder(dependencies: dependencies)
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
    let device = dependencies.agentDevice
    let clock = dependencies.clock
    func unrecorded(_ reason: QARecordingGapReason, _ detail: String) async -> (
      outcome: BatchFlowOutcome, recording: QAFlowRecording
    ) {
      (
        await batch(nil),
        QAFlowRecording(videoGap: QARecordingGap(reason: reason, detail: detail))
      )
    }

    let lease: LockLease
    do {
      lease = try await dependencies.lock.acquire(timeout: dependencies.lockWait)
    } catch {
      let detail =
        switch error {
        case .timedOut(let waited, _):
          "another run's recording held the \(Self.lockName) slot past \(waited)"
        case .cancelled, .io: "the \(Self.lockName) slot couldn't be taken: \(error)"
        }
      return await unrecorded(.recordLockTimedOut, detail)
    }
    // Released as soon as the recording stops; this covers every other way out.
    defer { lease.release() }

    let video = directory.appending(path: Self.videoFileName)
    let first = clock.now()
    var outcome: BatchFlowOutcome
    while true {
      outcome = await batch(video.path)
      guard case .recordStart(let failure) = outcome.stop else { break }
      guard failure.reason == .appleSimulatorRecordingBusy else {
        lease.release()
        return await unrecorded(.recordFailed, "record start failed: \(failure.message)")
      }
      guard dependencies.retriesBusyRecorder else {
        lease.release()
        return await unrecorded(.recorderBusy, "the Mac's recorder was busy: \(failure.message)")
      }
      switch RecordingRetry.decision(elapsed: clock.now() - first) {
      case .retry(let wait):
        do {
          try await clock.sleep(wait)
        } catch {
          lease.release()
          return await unrecorded(.recorderBusy, "waiting for the Mac's recorder was cancelled")
        }
      case .giveUp:
        lease.release()
        return await unrecorded(
          .recorderBusy,
          "a recording outside the harness held the Mac for 5 minutes: \(failure.message)")
      }
    }

    // The recording outlives a batch that stopped at a step, so it is stopped on every path.
    do {
      _ = try await device.recordStop(on: target)
    } catch {
      return (
        outcome,
        QAFlowRecording(
          videoGap: QARecordingGap(reason: .recordFailed, detail: "record stop: \(error.message)"))
      )
    }
    lease.release()
    guard FileManager.default.fileExists(atPath: video.path) else {
      return (
        outcome,
        QAFlowRecording(
          videoGap: QARecordingGap(
            reason: .recordFailed,
            detail: "record stop left no video at \(relativeDirectory)/\(Self.videoFileName)"))
      )
    }

    var recording = QAFlowRecording(
      video: "\(relativeDirectory)/\(Self.videoFileName)", videoStartMs: outcome.videoStartMs ?? 0)
    let sheet = directory.appending(path: Self.sheetFileName)
    do {
      _ = try await device.contactSheet(video: video.path, to: sheet.path)
      if FileManager.default.fileExists(atPath: sheet.path) {
        recording.sheet = "\(relativeDirectory)/\(Self.sheetFileName)"
      } else {
        recording.sheetGap = QARecordingGap(
          reason: .sheetFailed, detail: "record contact-sheet wrote no \(Self.sheetFileName)")
      }
    } catch {
      recording.sheetGap = QARecordingGap(reason: .sheetFailed, detail: error.message)
    }
    return (outcome, recording)
  }
}
