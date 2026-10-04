import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A kept flow's steps and video from what its XCUITest left in the result bundle, read from
/// `Fixtures/Xcresult/activities/`, captured from real T3 runs of the SampleApp.
@Suite("XCUITest flow")
struct XCUITestFlowTests {
  static let counterTest = "CounterFlowUITests/testIncrementAndDecrementUpdateTheDisplayedCount()"
  static let factTest = "CounterFlowUITests/testFixedFactScenarioShowsItsFactWithoutNetwork()"

  static func activities(_ scenario: String, _ method: String) throws -> XcresultActivities {
    try XcresultActivities.parse(
      try Fixture.data("Xcresult/activities/\(scenario)/\(method).activities.json"))
  }

  static func attachments(_ scenario: String) throws -> [XcresultAttachment] {
    try XcresultAttachment.parseManifest(
      try Fixture.data("Xcresult/activities/\(scenario)/manifest.json"))
  }

  @Test(
    "the captured counter test yields its steps in order, offset from the screen recording's first frame — catches offsets from the test's start instead of the video's"
  )
  func counterStepsOnTheVideoClock() throws {
    let activities = try Self.activities("pass", "testIncrementAndDecrementUpdateTheDisplayedCount")
    let video = try #require(XCUITestFlow.video(of: Self.counterTest, in: try Self.attachments("pass")))

    let steps = XCUITestFlow.steps(activities, videoStart: video.timestamp, passed: true)

    #expect(activities.testIdentifier == Self.counterTest)
    #expect(video.exportedFileName.hasSuffix(".mp4"))
    #expect(
      steps.map(\.label) == [
        "Open com.example.SampleApp",
        "Waiting 10.0s for \"counter.value\" StaticText to exist",
        "Find the \"counter.value\" StaticText",
        "Tap \"counter.increment\" Button",
        "Tap \"counter.increment\" Button",
        "Find the \"counter.value\" StaticText",
        "Tap \"counter.decrement\" Button",
        "Find the \"counter.value\" StaticText",
      ])
    #expect(steps.map(\.n) == Array(1...8))
    #expect(steps.map(\.offsetMs) == [3, 2980, 4079, 4084, 4394, 4706, 4711, 5022])
    #expect(steps.allSatisfy { $0.ok })
  }

  @Test(
    "a failing test's record ends at the failure it filed, marked not ok, after the steps that passed — catches a failing kept flow reading all ok"
  )
  func failingStepNotOK() throws {
    let activities = try Self.activities("fail", "testIncrementAndDecrementUpdateTheDisplayedCount")
    let video = try #require(XCUITestFlow.video(of: Self.counterTest, in: try Self.attachments("fail")))

    let steps = XCUITestFlow.steps(activities, videoStart: video.timestamp, passed: false)

    let last = try #require(steps.last)
    #expect(last.label == "XCTAssertEqual failed: (\"1\") is not equal to (\"7\")")
    #expect(last.ok == false)
    #expect(last.offsetMs == 5151)
    #expect(steps.dropLast().allSatisfy { $0.ok })
    #expect(!steps.contains { $0.label == "Tear Down" })
  }

  @Test(
    "a test the plan kept no recording for has no video, and its steps count from its first activity — catches a missing video read as one"
  )
  func noVideo() throws {
    let attachments = try Self.attachments("no-video")
    #expect(XCUITestFlow.video(of: Self.factTest, in: attachments) == nil)
    #expect(XCUITestFlow.video(of: Self.counterTest, in: attachments) == nil)

    let steps = XCUITestFlow.steps(
      try Self.activities("no-video", "testFixedFactScenarioShowsItsFactWithoutNetwork"),
      videoStart: nil, passed: true)
    #expect(steps.first?.label == "Open com.example.SampleApp")
    #expect((steps.first?.offsetMs ?? 0) > 0)
    #expect(steps.map(\.offsetMs) == steps.map(\.offsetMs).sorted())
  }

  @Test(
    "a failed test whose activities file no failure under any step marks its last step not ok — catches a failed test's flow reading as passed"
  )
  func failedWithoutFailingActivity() {
    let activities = XcresultActivities(
      testIdentifier: "C/testA()",
      runs: [
        [
          XcresultActivity(title: "Set Up", startTime: 10, failed: false),
          XcresultActivity(title: "Tap \"a\" Button", startTime: 11, failed: false),
          XcresultActivity(title: "Tap \"b\" Button", startTime: 12, failed: false),
          XcresultActivity(title: "Tear Down", startTime: 13, failed: false),
        ]
      ])

    let steps = XCUITestFlow.steps(activities, videoStart: 10, passed: false)

    #expect(steps.map(\.ok) == [true, false])
    #expect(steps.map(\.offsetMs) == [1000, 2000])
  }

  @Test(
    "a step label keeps its first line and stays short, so the qa.flow payload guard keeps the event — catches a multi-line failure dropping the whole flow"
  )
  func labelsFitTheEventGuard() {
    let long = String(repeating: "x", count: 900)
    let activities = XcresultActivities(
      testIdentifier: "C/testA()",
      runs: [[XcresultActivity(title: "failed: \(long)\nsecond line", startTime: 1, failed: true)]])

    let label = XCUITestFlow.steps(activities, videoStart: 1, passed: false).first?.label ?? ""

    #expect(!label.contains("\n"))
    #expect(label.utf8.count < EventPayloadGuard.maxStringBytes)
    #expect(label.hasPrefix("failed: xxx"))
  }
}
