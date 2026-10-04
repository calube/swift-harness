import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// How T3's kept flows become `qa.flow` records: the result bundle's activities and attachments
/// come from `Fixtures/Xcresult/activities/`, and the contact sheet from the captured
/// `record contact-sheet` call.
@Suite("XCUITest flow recorder")
struct XCUITestFlowRecorderTests {
  static let counterTest = "CounterFlowUITests/testIncrementAndDecrementUpdateTheDisplayedCount()"
  static let factTest = "CounterFlowUITests/testFixedFactScenarioShowsItsFactWithoutNetwork()"

  private static func temporaryRoot() throws -> URL {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-kept-flows-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// A device whose `record contact-sheet` answers with the captured call and writes the sheet.
  private static func device(home: URL) throws -> any AgentDevice {
    LiveAgentDevice(
      runner: try CapturedFinalPass.runner(batch: "record/recorded-pass", home: home))
  }

  @Test(
    "a passing kept flow saves its screen recording and contact sheet under the run with run-relative paths, and writes its record — catches a kept flow left without its video"
  )
  func passKeepsVideoAndSheet() async throws {
    let root = try Self.temporaryRoot()
    defer { TestTemporaryDirectory.remove(root) }
    let run = root.appending(path: "run", directoryHint: .isDirectory)
    let recorder = XCUITestFlowRecorder(
      reader: FakeXcresultReader(keptFlows: "pass"),
      agentDevice: try Self.device(home: root.appending(path: "home")))

    let kept = await recorder.record(
      [KeptFlowTest(identifier: Self.counterTest, flow: "counter", passed: true)],
      bundlePath: "/bundle.xcresult", runDirectory: run)

    let folder = "qa/xcuitest/CounterFlowUITests-testIncrementAndDecrementUpdateTheDisplayedCount"
    let record = try #require(kept.records.first)
    #expect(kept.records.count == 1)
    #expect(kept.gaps.isEmpty)
    #expect(record.source == .xcuitest)
    #expect(record.flow == "counter")
    #expect(record.test == Self.counterTest)
    #expect(record.video == "\(folder)/video.mp4")
    #expect(record.sheet == "\(folder)/sheet.png")
    #expect(record.videoUnverified == nil && record.sheetUnverified == nil)
    #expect(record.steps.allSatisfy { $0.ok } && !record.steps.isEmpty)
    let files = FileManager.default
    #expect(files.fileExists(atPath: run.appending(path: "\(folder)/video.mp4").path))
    #expect(files.fileExists(atPath: run.appending(path: "\(folder)/sheet.png").path))
    #expect(files.fileExists(atPath: run.appending(path: "\(folder)/activities.json").path))
    #expect(!files.fileExists(atPath: run.appending(path: "\(folder)/attachments").path))
    let written = try JSONDecoder().decode(
      QAFlowRecord.self, from: try Data(contentsOf: run.appending(path: "\(folder)/flow.json")))
    #expect(written == record)
  }

  @Test(
    "a kept flow whose test kept no screen recording leaves video absent, reads unverified, makes no sheet, and adds a qa.video-unverified note — catches a missing video passing silently"
  )
  func noVideoAddsNote() async throws {
    let root = try Self.temporaryRoot()
    defer { TestTemporaryDirectory.remove(root) }
    let device = FakeAgentDevice()
    let recorder = XCUITestFlowRecorder(
      reader: FakeXcresultReader(keptFlows: "no-video"), agentDevice: device)

    let kept = await recorder.record(
      [KeptFlowTest(identifier: Self.factTest, flow: "counter", passed: true)],
      bundlePath: "/bundle.xcresult", runDirectory: root)

    let record = try #require(kept.records.first)
    #expect(record.video == nil && record.sheet == nil)
    #expect(record.videoUnverified == .noVideoAttachment)
    #expect(!record.steps.isEmpty)
    #expect(kept.gaps.map(\.ruleID) == [QAEvidenceGap.videoUnverifiedRuleID])
    #expect(kept.gaps.map(\.test) == [Self.factTest])
    #expect(device.calls.isEmpty)
  }

  @Test(
    "a contact sheet that fails keeps the video and marks the sheet unverified — catches a sheet failure dropping the flow"
  )
  func sheetFailureKeepsVideo() async throws {
    let root = try Self.temporaryRoot()
    defer { TestTemporaryDirectory.remove(root) }
    let recorder = XCUITestFlowRecorder(
      reader: FakeXcresultReader(keptFlows: "pass"),
      agentDevice: LiveAgentDevice(
        runner: try CapturedFinalPass.runner(
          batch: "record/recorded-pass", home: root.appending(path: "home"),
          failing: ["record contact-sheet"])))

    let kept = await recorder.record(
      [KeptFlowTest(identifier: Self.counterTest, flow: "counter", passed: true)],
      bundlePath: "/bundle.xcresult", runDirectory: root.appending(path: "run"))

    let record = try #require(kept.records.first)
    #expect(record.video != nil && record.sheet == nil)
    #expect(record.sheetUnverified == .sheetFailed)
    #expect(kept.gaps.map(\.kind) == [.sheet])
  }

  @Test(
    "a test whose activities can't be read leaves no record and a qa.evidence-unsaved note — catches an empty flow record standing in for one"
  )
  func unreadableActivities() async throws {
    let root = try Self.temporaryRoot()
    defer { TestTemporaryDirectory.remove(root) }
    let recorder = XCUITestFlowRecorder(
      reader: FakeXcresultReader(keptFlows: "pass"), agentDevice: FakeAgentDevice())

    let kept = await recorder.record(
      [KeptFlowTest(identifier: "CounterFlowUITests/testMissing()", flow: "counter", passed: true)],
      bundlePath: "/bundle.xcresult", runDirectory: root)

    #expect(kept.records.isEmpty)
    #expect(kept.gaps.map(\.ruleID) == [QAEvidenceGap.evidenceUnsavedRuleID])
    #expect(kept.gaps.map(\.kind) == [.activities])
  }

  @Test("a test's folder is its class and method without the parentheses")
  func folderName() {
    #expect(
      XCUITestFlowRecorder.folderName(test: Self.counterTest)
        == "CounterFlowUITests-testIncrementAndDecrementUpdateTheDisplayedCount")
  }
}
