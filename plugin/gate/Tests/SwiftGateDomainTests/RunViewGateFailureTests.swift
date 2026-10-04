import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The captured build run under `Fixtures/RunView/build-run-1`, whose merge gate of
/// `counter-ui-reset-button` went RED on a snapshot test before its fixer turned it GREEN, with
/// that gate's `report.json` as the run's checkout held it.
private struct RedGateRun {
  static let directory = "RunView/build-run-1"
  static let redGate = "20261004T050310Z-ed998508"
  /// The scratch checkout the capture ran in, as the fixture's report names it.
  static let checkout = "/var/folders/xx/T/tmp.scratch/app"
  static let task = "counter-ui-reset-button"
  static let snapshotTest = "CounterUISnapshotTests.CounterViewSnapshotTests/counterWithFact"
  static let snapshotFile =
    "Packages/CounterFeature/Tests/CounterUISnapshotTests/CounterViewSnapshotTests.swift"

  let input: RunViewInput
  let report: RunReport

  init(roots: [String] = [RedGateRun.checkout]) throws {
    let ledger = try LedgerJSON.decode(try Fixture.data("\(Self.directory)/ledger.json"))
    let record = try BuildRunJSON.decode(try Fixture.data("\(Self.directory)/run.json"))
    let log = BuildEventJSON.decode(try Fixture.data("\(Self.directory)/ledger-events.jsonl"))
    var returns: [String: TaskReturn] = [:]
    for name in try Self.entries("returns") where name.hasSuffix(".json") {
      let taskReturn = try TaskReturnJSON.decode(
        try Fixture.data("\(Self.directory)/returns/\(name)"))
      returns[taskReturn.task] = taskReturn
    }
    var streams = try Self.entries("events").filter { $0.hasSuffix(".jsonl") }.map {
      "events/\($0)"
    }
    for store in try Self.entries("events/imported") where !store.hasPrefix(".") {
      streams += try Self.entries("events/imported/\(store)").filter { $0.hasSuffix(".jsonl") }
        .map { "events/imported/\(store)/\($0)" }
    }
    var events: [HarnessEvent] = []
    for stream in streams {
      events += try HarnessEventJSON.decode(try Fixture.data("\(Self.directory)/\(stream)")).events
    }
    report = try RecordedRunReport.decode(
      try Fixture.data("\(Self.directory)/runs/\(Self.redGate)/report.json")
    ).report
    input = RunViewInput(
      buildRun: record.runID, events: events.filter { $0.time >= record.startedAt },
      join: BuildJoin.Run(
        plan: record.plan, runID: record.runID,
        writeSets: Dictionary(uniqueKeysWithValues: ledger.tasks.map { ($0.id, $0.writeSet) }),
        returns: returns, events: log.events, record: record),
      ledger: ledger,
      gateReports: [
        Self.redGate: RunViewGateReport(
          report: report, location: ".harness/runs/\(Self.redGate)/report.json")
      ],
      checkoutRoots: roots)
  }

  private static func entries(_ relative: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      atPath: Fixture.directory.appending(path: "\(directory)/\(relative)").path
    ).sorted()
  }

  /// The captured red gate's events: its `gate.run` and each `test.result` under it.
  func redGateEvents() throws -> (run: HarnessEvent, tests: [HarnessEvent]) {
    let own = input.events.filter { $0.runID == Self.redGate }
    guard let run = own.first(where: { $0.kind == .gateRun }) else {
      throw RedGateRunError.noGateRun
    }
    return (run, own.filter { $0.kind == .testResult })
  }
}

private enum RedGateRunError: Error {
  case noGateRun
}

private func time(_ text: String) throws -> Date {
  try Date(text, strategy: .iso8601)
}

@Suite("run view gate failures")
struct RunViewGateFailureTests {
  @Test(
    "a RED merge gate carries its tier, its gating finding at file:line and its failing test at the assertion — catches the builder dropping a red gate's findings"
  )
  func redGateCarriesItsFailure() throws {
    let view = RunViewBuilder.build(try RedGateRun().input)
    let gate = try #require(view.gates.first { $0.runID == RedGateRun.redGate })
    let failure = try #require(gate.failure)
    #expect(failure.stage == .merge)
    #expect(failure.checkTier == .push)
    #expect(failure.tiers == [.t2])
    #expect(gate.tests.map { [$0.passed, $0.failed, $0.skipped] } == [33, 1, 0])
    #expect(failure.findings.count == 1)
    let finding = try #require(failure.findings.first)
    #expect(finding.rule == "t2.test-failed")
    #expect(finding.severity == .major)
    #expect(finding.file == RedGateRun.snapshotFile)
    #expect(finding.line == 21)
    #expect(finding.message.hasPrefix("CounterViewSnapshotTests/counterWithFact(): Issue recorded"))
    #expect(
      finding.message.contains(
        "Packages/CounterFeature/Tests/CounterUISnapshotTests/__Snapshots__/"))
    #expect(finding.moreThanOneLine == false)
    #expect(failure.moreFindings == 0)
    #expect(
      failure.failedTests == [
        RunView.FailedTest(
          test: RedGateRun.snapshotTest, tier: .t2, file: RedGateRun.snapshotFile, line: 21)
      ])
    #expect(failure.report == ".harness/runs/\(RedGateRun.redGate)/report.json")
    #expect(failure.command == "swiftgate events list --run \(RedGateRun.redGate)")
    #expect(view.gates.filter { $0.verdict == .green }.allSatisfy { $0.failure == nil })
  }

  @Test(
    "the captured RED merge gate's span and the merge it closes give its rule and failing test count as the reason — catches a red gate span with no failure reason"
  )
  func redGateSpanReason() throws {
    let view = RunViewBuilder.build(try RedGateRun().input)
    let reason = "t2.test-failed: 1 test fails on the merged branch."
    let red = view.spans.filter { $0.gateRun == RedGateRun.redGate && $0.outcome == .red }
    #expect(Set(red.map(\.phase)).isSuperset(of: [.gate, .merge]))
    #expect(red.allSatisfy { $0.failureReason == reason })
    #expect(view.spans.filter { $0.outcome == .ok }.allSatisfy { $0.failureReason == nil })
  }

  @Test(
    "a finding's absolute paths, home paths and newlines never reach the view's JSON, which passes the guard — catches a machine path published in a report"
  )
  func noMachinePathReachesTheJSON() throws {
    for roots in [[RedGateRun.checkout], []] {
      let view = RunViewBuilder.build(try RedGateRun(roots: roots).input)
      let json = String(decoding: try RunViewJSON.encode(view), as: UTF8.self)
      for leak in ["/var/folders", "/Users/", "tmp.scratch", "file://", "\\n"] {
        #expect(!json.contains(leak), "\(roots): \(leak)")
      }
      #expect(try RunViewGuard.rejection(of: view) == nil, "\(roots)")
      let message = try #require(
        view.gates.first { $0.runID == RedGateRun.redGate }?.failure?.findings.first?.message)
      #expect(message.contains("<path>"), "\(roots): \(message)")
    }
  }

  @Test(
    "a report over the caps carries the first 10 gating findings and 10 failing tests, counts the rest and cuts each message — catches an over-cap list reaching the page"
  )
  func capsTheLists() throws {
    let run = try RedGateRun()
    var input = run.input
    let captured = try #require(run.report.findings.first { $0.severity.failsGate })
    let nit = try #require(run.report.findings.first { !$0.severity.failsGate })
    let extra = RunView.maxFailureFindings + 4
    let report = try RunReport(
      runID: run.report.runID, durationMilliseconds: run.report.durationMilliseconds,
      tiers: run.report.tiers, findings: Array(repeating: captured, count: extra) + [nit])
    input.gateReports[RedGateRun.redGate]?.report = report
    let (gateRun, tests) = try run.redGateEvents()
    let failing = try #require(tests.first)
    guard case .testResult(let result) = failing.payload else {
      Issue.record("the red gate's first test event is not a test.result")
      return
    }
    for index in 0..<(RunView.maxFailedTests + 2) {
      let renamed = TestResultEvent(
        TestCaseResult(
          test: "\(result.test)\(index)", target: result.target, tier: result.tier,
          outcome: .failed, milliseconds: nil))
      input.events.append(
        HarnessEvent(
          eventID: "extra-test-\(index)", parentID: gateRun.eventID, time: failing.time,
          runID: RedGateRun.redGate, source: failing.source, payload: .testResult(renamed)))
    }

    let failure = try #require(
      RunViewBuilder.build(input).gates.first { $0.runID == RedGateRun.redGate }?.failure)
    #expect(failure.findings.count == RunView.maxFailureFindings)
    #expect(failure.moreFindings == extra - RunView.maxFailureFindings)
    #expect(failure.findings.allSatisfy { $0.severity.failsGate })
    #expect(failure.findings.allSatisfy { $0.truncated })
    #expect(
      failure.findings.allSatisfy { $0.message.utf8.count <= RunView.maxFailureMessageBytes })
    #expect(failure.failedTests.count == RunView.maxFailedTests)
    #expect(failure.moreFailedTests == 3)
  }

  @Test(
    "a red fix stage and a gate-red halt name the RED gate run inside and before them, and a question halt names none — catches a red stage or halt with no cause"
  )
  func stagesAndHaltsNameTheirGate() throws {
    var input = try RedGateRun().input
    let source = HarnessEventSource(route: nil)
    let spanID = "0123456789abcdef"
    input.events += [
      HarnessEvent(
        eventID: "fix-start", time: try time("2026-10-04T05:03:00Z"), source: source,
        payload: .spanStart(
          SpanStartEvent(
            spanID: spanID, parentSpan: nil, phase: .fix, buildRun: input.buildRun,
            task: RedGateRun.task, role: .buildWorker))),
      HarnessEvent(
        eventID: "fix-end", parentID: "fix-start", time: try time("2026-10-04T05:06:00Z"),
        source: source,
        payload: .spanEnd(SpanEndEvent(spanID: spanID, outcome: .red, milliseconds: 180_000))),
      HarnessEvent(
        eventID: "halt-gate-red", time: try time("2026-10-04T05:05:40Z"), source: source,
        payload: .buildHalt(
          BuildHaltEvent(buildRun: input.buildRun, task: RedGateRun.task, reason: .gateRed))),
    ]
    let view = RunViewBuilder.build(input)
    #expect(view.spans.first { $0.id == spanID }?.causeGateRun == RedGateRun.redGate)
    #expect(view.spans.filter { $0.id != spanID }.allSatisfy { $0.causeGateRun == nil })
    #expect(view.halts.first { $0.reason == .gateRed }?.gateRun == RedGateRun.redGate)
    #expect(view.halts.first { $0.reason == .question }.map { $0.gateRun == nil } == true)
  }

  @Test(
    "with no report.json the RED gate still names its tier and failing test from its events — catches a failure that vanishes with its report"
  )
  func failureWithoutItsReport() throws {
    var input = try RedGateRun().input
    input.gateReports = [:]
    let failure = try #require(
      RunViewBuilder.build(input).gates.first { $0.runID == RedGateRun.redGate }?.failure)
    #expect(failure.tiers == [.t2])
    #expect(failure.findings.isEmpty)
    #expect(failure.report == nil)
    #expect(failure.failedTests.map(\.test) == [RedGateRun.snapshotTest])
    #expect(failure.failedTests.first?.file == nil)
  }
}

extension RunView.FailureFinding {
  fileprivate var moreThanOneLine: Bool { message.contains(where: \.isNewline) }
}
