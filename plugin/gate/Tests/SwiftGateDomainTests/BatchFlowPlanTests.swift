import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// How `qa run` drives a flow file as a batch, and reads the batch's results back in the flow
/// file's terms. The results come from `Fixtures/AgentDevice/batch/`, captured from the driven
/// counter flow.
@Suite("batch flow plan")
struct BatchFlowPlanTests {
  static func counterSteps() throws -> [FlowStep] {
    try FlowSteps.parse(try Fixture.data("QA/counter.flow.json"))
  }

  /// `data.results`, or a failure's `error.details.partialResults`, of a captured batch.
  static func results(_ name: String) throws -> [BatchStepOutcome] {
    let object = try #require(
      try JSONSerialization.jsonObject(with: try Fixture.data("AgentDevice/batch/\(name).stdout"))
        as? [String: Any])
    let list: [Any]
    if let data = object["data"] as? [String: Any] {
      list = try #require(data["results"] as? [Any])
    } else {
      let error = try #require(object["error"] as? [String: Any])
      let details = try #require(error["details"] as? [String: Any])
      list = try #require(details["partialResults"] as? [Any])
    }
    return try list.map { item in
      let step = try #require(item as? [String: Any])
      return BatchStepOutcome(
        index: try #require(step["step"] as? Int),
        command: try #require(step["command"] as? String),
        ok: try #require(step["ok"] as? Bool), durationMs: try #require(step["durationMs"] as? Int))
    }
  }

  /// `data.results` of a batch `Fixtures/QA/short-state/` captured from a recorded `qa run`.
  static func shortStateResults(_ name: String) throws -> [BatchStepOutcome] {
    let object = try #require(
      try JSONSerialization.jsonObject(
        with: try Fixture.data("QA/short-state/\(name).batch.json")) as? [String: Any])
    let data = try #require(object["data"] as? [String: Any])
    return try #require(data["results"] as? [[String: Any]]).map { step in
      BatchStepOutcome(
        index: try #require(step["step"] as? Int),
        command: try #require(step["command"] as? String),
        ok: try #require(step["ok"] as? Bool), durationMs: try #require(step["durationMs"] as? Int))
    }
  }

  static let recordedReadsVideo =
    "/SCRATCH/app/.harness/runs/20261005T211436Z-8e3deac1/qa/"
    + "01-slice-1-reset-after-increments-shows-zero.flow/video.mp4"

  @Test(
    "a batch that records takes 1 snapshot after each of its 3 back-to-back checks, with no screenshot or settle snapshot on the flow's clock, as the captured recorded run drove it — catches 1.1 s of qa run's captures between checks of a state that lasts 1 s"
  )
  func recordingBatchTakesOneSnapshotPerCheck() throws {
    let steps = try FlowSteps.parse(try Fixture.data("QA/short-state/reads.flow.json"))

    let plan = BatchFlowPlan.make(
      steps: steps, screenshots: ["/SCRATCH/1.png", "/SCRATCH/2.png", "/SCRATCH/3.png"],
      recordTo: Self.recordedReadsVideo)

    #expect(
      try FlowJSON.parse(plan.drivenJSON())
        == FlowJSON.parse(try Fixture.data("QA/short-state/recorded-reads.steps.json")))
    #expect(plan.evidence.map(\.snapshot) == [4, 6, 8])
    #expect(plan.evidence.map(\.screenshot) == [nil, nil, nil])
    #expect(plan.evidence.map(\.settle) == [nil, nil, nil])
    #expect(plan.evidence.map(\.screenshotPath) == ["/SCRATCH/1.png", "/SCRATCH/2.png", "/SCRATCH/3.png"])
  }

  @Test(
    "each recorded check's frame is the video's moment its snapshot began: the captured run's snapshots began 417, 812 and 1209 ms into the video — catches a check's PNG taken from a frame before the check passed or after the screen moved on"
  )
  func frameTimesFollowTheVideoClock() throws {
    let steps = try FlowSteps.parse(try Fixture.data("QA/short-state/reads.flow.json"))
    let plan = BatchFlowPlan.make(
      steps: steps, screenshots: ["/SCRATCH/1.png", "/SCRATCH/2.png", "/SCRATCH/3.png"],
      recordTo: Self.recordedReadsVideo)

    let times = plan.frameTimes(results: try Self.shortStateResults("recorded-reads"))

    #expect(times == [2: 417, 3: 812, 4: 1209])
    let unrecorded = BatchFlowPlan.make(
      steps: steps, screenshots: ["/SCRATCH/1.png", "/SCRATCH/2.png", "/SCRATCH/3.png"])
    #expect(unrecorded.frameTimes(results: try Self.shortStateResults("recorded-reads")) == [:])
  }

  @Test(
    "the counter flow gets a snapshot, a screenshot and a settle snapshot after each assertion, every written step kept as written — catches an asserted step that leaves sim verify no tree"
  )
  func drivesEvidenceAfterAssertions() throws {
    let steps = try Self.counterSteps()

    let plan = BatchFlowPlan.make(
      steps: steps, screenshots: ["/SCRATCH/1.png", "/SCRATCH/2.png"])

    #expect(BatchFlowPlan.assertionCount(steps) == 2)
    #expect(
      try FlowJSON.parse(plan.drivenJSON())
        == FlowJSON.parse(try Fixture.data("AgentDevice/batch/pass.steps.json")))
    #expect(plan.evidence.map(\.after) == [1, 3])
    #expect(plan.evidence.map(\.assert) == [nil, "1"])
    #expect(plan.evidence.map(\.snapshot) == [2, 7])
    #expect(plan.evidence.map(\.screenshot) == [3, 8])
    #expect(plan.evidence.map(\.settle) == [4, 9])
    #expect(plan.origin == [1, nil, nil, nil, 2, 3, nil, nil, nil, 4])
  }

  @Test(
    "a failing driven step is named by the flow file's number, and a failed capture by the step it follows — catches a failing step named by the driven file's numbering"
  )
  func stopsInFlowTerms() throws {
    let plan = BatchFlowPlan.make(
      steps: try Self.counterSteps(), screenshots: ["/SCRATCH/1.png", "/SCRATCH/2.png"])

    #expect(plan.stop(atDrivenIndex: 6, command: "is") == .step(n: 3, command: "is"))
    #expect(
      plan.stop(atDrivenIndex: 8, command: "screenshot")
        == .evidence(after: 3, command: "screenshot"))
  }

  @Test(
    "the captured passing batch records each written step once with its offset from the batch's start and the time the captures after it took, and no capture as a step — catches offsets that skip the captures' time"
  )
  func recordsPassingBatch() throws {
    let plan = BatchFlowPlan.make(
      steps: try Self.counterSteps(), screenshots: ["/SCRATCH/1.png", "/SCRATCH/2.png"])

    let record = plan.record(results: try Self.results("pass"), failedAt: nil)

    #expect(
      record
        == QAFlowRecord(
          source: .batch,
          steps: [
            QAFlowStep(
              n: 1, label: "wait selector id=\"counter.value\"", offsetMs: 0, ok: true,
              captureMs: 1281),
            QAFlowStep(
              n: 2, label: "press id=\"counter.increment\"", offsetMs: 1707, ok: true),
            QAFlowStep(
              n: 3, label: "is text id=\"counter.value\" \"1\"", offsetMs: 2908, ok: true,
              captureMs: 1153),
            QAFlowStep(n: 4, label: "snapshot", offsetMs: 4488, ok: true),
          ]))
    #expect(record.video == nil)
    #expect(record.sheet == nil)
  }

  @Test(
    "the captured failing batch records the steps up to the failing one, which is not ok, and none after — catches a failed flow whose record shows every step passing"
  )
  func recordsFailingBatch() throws {
    let plan = BatchFlowPlan.make(
      steps: try Self.counterSteps(), screenshots: ["/SCRATCH/3.png", "/SCRATCH/4.png"])

    let record = plan.record(results: try Self.results("fail"), failedAt: 6)

    #expect(record.steps.map(\.n) == [1, 2, 3])
    #expect(record.steps.map(\.ok) == [true, true, false])
    #expect(record.steps.map(\.offsetMs) == [0, 1536, 2287])
  }

  @Test(
    "the captured failing counter batch, which opens nothing, puts the time before its failing `is` in captures and the flow's own steps with no launch, and a failed capture gets no delay — catches a launch claimed for a flow that never opened the app"
  )
  func delayWithoutOpen() throws {
    let plan = BatchFlowPlan.make(
      steps: try Self.counterSteps(), screenshots: ["/SCRATCH/3.png", "/SCRATCH/4.png"])
    let results = try Self.results("fail")

    let delay = try #require(plan.delay(results: results, failedAt: 6))

    #expect(
      delay == QAFlowDelay(step: 3, beforeMs: 2287, openMs: 0, captureMs: 1149, launch: nil))
    #expect(
      delay.sentence
        == "step 3 began 2.3 s into the batch: 1.1 s in captures qa run added, 1.1 s in the flow's other steps"
    )
    #expect(plan.record(results: results, failedAt: 6).launch == nil)
    #expect(plan.delay(results: results, failedAt: 3) == nil, "a failed screenshot isn't a step")
  }
}
