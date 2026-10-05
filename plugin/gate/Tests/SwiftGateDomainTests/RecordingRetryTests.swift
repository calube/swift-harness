import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The final pass's pure parts: how long it waits for a busy recorder, the batch that starts
/// with `record start`, the record's move onto the video's clock, and the report's gaps.
@Suite("final pass recording")
struct RecordingRetryTests {
  @Test(
    "a busy recorder is retried every 15 s up to 5 minutes after the first try, then given up — catches a final pass that hangs on a recording the harness can't see, or gives up early"
  )
  func retriesWithinBound() {
    #expect(RecordingRetry.decision(elapsed: .zero) == .retry(after: .seconds(15)))
    #expect(RecordingRetry.decision(elapsed: .seconds(285)) == .retry(after: .seconds(15)))
    #expect(RecordingRetry.decision(elapsed: .seconds(290)) == .retry(after: .seconds(10)))
    #expect(RecordingRetry.decision(elapsed: .seconds(300)) == .giveUp)
    #expect(RecordingRetry.decision(elapsed: .seconds(301)) == .giveUp)
  }

  @Test(
    "a recorded plan starts with record start to the video path, its captures and stops shift by 1, and a failure at the first step is the record start — catches a recording failure read as a failing flow step"
  )
  func recordedPlanStartsWithRecord() throws {
    let steps = try FlowSteps.parse(try Fixture.data("QA/counter.flow.json"))

    let plan = BatchFlowPlan.make(
      steps: steps, screenshots: ["/SCRATCH/1.png", "/SCRATCH/2.png"],
      recordTo: "/SCRATCH/video.mp4")

    #expect(
      try FlowJSON.parse(plan.drivenJSON())
        == FlowJSON.parse(try Fixture.data("AgentDevice/record/recorded-pass.steps.json")))
    #expect(plan.recordTo == "/SCRATCH/video.mp4")
    #expect(plan.evidence.map(\.snapshot) == [3, 8])
    #expect(plan.stop(atDrivenIndex: 1, command: "record") == .recordStart)
    #expect(plan.stop(atDrivenIndex: 7, command: "is") == .step(n: 3, command: "is"))
  }

  @Test(
    "the captured recorded batch's steps move onto the video's clock: the record start's own time comes off every offset — catches offsets from the batch's start linked against a video that began later"
  )
  func recordedOffsetsOnVideoClock() throws {
    let steps = try FlowSteps.parse(try Fixture.data("QA/counter.flow.json"))
    let plan = BatchFlowPlan.make(
      steps: steps, screenshots: ["/SCRATCH/1.png", "/SCRATCH/2.png"],
      recordTo: "/SCRATCH/video.mp4")
    let results = try Self.results("recorded-pass")
    let batch = plan.record(results: results, failedAt: nil)
    let recordMs = try #require(results.first { $0.index == 1 }).durationMs

    let recorded = batch.recorded(
      QAFlowRecording(
        video: "qa/01-req-count.flow/video.mp4", sheet: "qa/01-req-count.flow/sheet.png",
        videoStartMs: recordMs))

    #expect(batch.steps.map(\.offsetMs) == [1441, 3162, 3998, 5550])
    #expect(recorded.steps.map(\.offsetMs) == [0, 1721, 2557, 4109])
    #expect(recorded.steps.map(\.n) == [1, 2, 3, 4])
    #expect(recorded.video == "qa/01-req-count.flow/video.mp4")
    #expect(recorded.sheet == "qa/01-req-count.flow/sheet.png")
    #expect(recorded.videoUnverified == nil)
  }

  @Test(
    "a recording that made no video keeps the batch's offsets and names its reason on the record, and a sheet that failed names its own — catches a missing video that reads as no final pass at all"
  )
  func missingVideoNamesReason() {
    let batch = QAFlowRecord(
      source: .batch,
      steps: [
        QAFlowStep(n: 1, label: "wait", offsetMs: 0, ok: true),
        QAFlowStep(n: 2, label: "press", offsetMs: 400, ok: true),
      ])

    let busy = batch.recorded(
      QAFlowRecording(
        videoGap: QARecordingGap(reason: .recorderBusy, detail: "busy for 5 minutes")))
    let noSheet = batch.recorded(
      QAFlowRecording(
        video: "qa/01-r.flow/video.mp4", videoStartMs: 100,
        sheetGap: QARecordingGap(reason: .sheetFailed, detail: "no frames")))

    #expect(busy.steps == batch.steps)
    #expect(busy.video == nil)
    #expect(busy.videoUnverified == .recorderBusy)
    #expect(busy.sheetUnverified == nil)
    #expect(noSheet.video == "qa/01-r.flow/video.mp4")
    #expect(noSheet.sheet == nil)
    #expect(noSheet.sheetUnverified == .sheetFailed)
    #expect(noSheet.steps.map(\.offsetMs) == [0, 300])
  }

  @Test(
    "a missing video is a qa.video-unverified nit and missing logs a qa.evidence-unsaved nit, each naming its row and why, and neither turns a passing run RED — catches a pass that waits on video, or a lost log nobody hears about"
  )
  func gapsAreNits() throws {
    let recording = QAFlowRecording(
      videoGap: QARecordingGap(reason: .recorderBusy, detail: "busy for 5 minutes"))
    let gaps =
      recording.gaps(row: 2) + [QAEvidenceGap(row: 2, kind: .network, reason: "dump failed")]
    let row = QARow(
      row: 2, requirement: "req-count", layer: .flow, check: "qa/count.flow.json",
      runsAfter: ["count-ui"], result: .pass, message: "batch passed")

    let report = QAReport(
      runID: "r1", plan: "p", after: nil, atBase: false, final: true, commit: "abc", rows: [row],
      gaps: gaps)

    #expect(gaps.map(\.kind) == [.video, .network])
    #expect(report.verdict == .green)
    #expect(report.final)
    #expect(report.findings.map(\.ruleID) == ["qa.video-unverified", "qa.evidence-unsaved"])
    #expect(report.findings.allSatisfy { !$0.severity.failsGate })
    #expect(report.findings.allSatisfy { $0.message.contains("row 2 (req-count") })
    #expect(report.findings.first?.message.contains("busy for 5 minutes") == true)
    let decoded = try QAReportJSON.decode(try QAReportJSON.encode(report))
    #expect(decoded == report)
  }

  @Test(
    "a recorded flow that starts by relaunching the app runs the open first and the record start second, so a failure at the open is the flow's step 1 and one at the record start is the recording's — catches a video whose first frame shows the app's previous launch"
  )
  func relaunchingPlanRecordsAfterOpen() throws {
    let steps = try FlowSteps.parse(
      try Fixture.data("AgentDevice/record/relaunched-pass.flow.json"))

    let plan = BatchFlowPlan.make(
      steps: steps, screenshots: ["/SCRATCH/1.png", "/SCRATCH/2.png"],
      recordTo: "/SCRATCH/relaunched.mp4")

    #expect(
      try FlowJSON.parse(plan.drivenJSON())
        == FlowJSON.parse(try Fixture.data("AgentDevice/record/relaunched-pass.steps.json")))
    #expect(plan.recordIndex == 2)
    #expect(plan.evidence.map(\.snapshot) == [4, 9])
    #expect(plan.stop(atDrivenIndex: 1, command: "open") == .step(n: 1, command: "open"))
    #expect(plan.stop(atDrivenIndex: 2, command: "record") == .recordStart)
    #expect(plan.stop(atDrivenIndex: 8, command: "is") == .step(n: 4, command: "is"))
  }

  @Test(
    "the captured relaunching batch's video starts when the record start after the open ends, so the open sits at the video's first frame and every later step keeps its place — catches a video clock that leaves out the relaunch's time"
  )
  func relaunchingOffsetsOnVideoClock() throws {
    let steps = try FlowSteps.parse(
      try Fixture.data("AgentDevice/record/relaunched-pass.flow.json"))
    let plan = BatchFlowPlan.make(
      steps: steps, screenshots: ["/SCRATCH/1.png", "/SCRATCH/2.png"],
      recordTo: "/SCRATCH/relaunched.mp4")
    let results = try Self.results("relaunched-pass")
    let batch = plan.record(results: results, failedAt: nil)

    let start = try #require(plan.videoStartMs(results: results))
    let recorded = batch.recorded(
      QAFlowRecording(video: "qa/01-req-count.flow/video.mp4", videoStartMs: start))

    #expect(start == 2069)
    #expect(batch.steps.map(\.offsetMs) == [0, 2069, 3797, 4503, 6063])
    #expect(recorded.steps.map(\.offsetMs) == [0, 0, 1728, 2434, 3994])
    #expect(recorded.steps.map(\.n) == [1, 2, 3, 4, 5])
    #expect(recorded.steps.map(\.ok) == [true, true, true, true, true])
  }

  /// `data.results` of a captured batch under `Fixtures/AgentDevice/record/`.
  static func results(_ name: String) throws -> [BatchStepOutcome] {
    let object = try #require(
      try JSONSerialization.jsonObject(
        with: try Fixture.data("AgentDevice/record/\(name).stdout")) as? [String: Any])
    let data = try #require(object["data"] as? [String: Any])
    let list = try #require(data["results"] as? [Any])
    return try list.map { item in
      let step = try #require(item as? [String: Any])
      return BatchStepOutcome(
        index: try #require(step["step"] as? Int),
        command: try #require(step["command"] as? String),
        ok: try #require(step["ok"] as? Bool), durationMs: try #require(step["durationMs"] as? Int))
    }
  }
}
