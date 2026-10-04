import Foundation
import SwiftGateDomain
import Testing

@Suite("run view events")
struct SpanEventsTests {
  private func line(kind: String, payload: String) -> Data {
    Data(
      ("{\"eventID\":\"e1\",\"kind\":\"\(kind)\",\"payload\":\(payload),"
        + "\"schemaVersion\":1,\"source\":{},\"time\":\"2026-10-03T12:00:00.000Z\"}\n").utf8)
  }

  private func spanStart(id: String = "0123456789abcdef", phase: String = "plan") -> Data {
    line(
      kind: "span.start",
      payload:
        "{\"buildRun\":\"20261003T120000Z-1a2b3c4d\",\"phase\":\"\(phase)\",\"spanID\":\"\(id)\"}")
  }

  private func decodeError(_ data: Data) -> String? {
    do {
      _ = try HarnessEventJSON.decode(data)
      return nil
    } catch {
      return error.description
    }
  }

  @Test(
    "a span.start with phase = \"warmup\" fails decoding naming phase, and phase = \"plan\" decodes — catches an open phase string"
  )
  func spanPhaseIsClosed() throws {
    let read = try HarnessEventJSON.decode(spanStart())
    #expect(
      read.events.map(\.payload) == [
        .spanStart(
          SpanStartEvent(
            spanID: "0123456789abcdef", parentSpan: nil, phase: .plan,
            buildRun: "20261003T120000Z-1a2b3c4d", task: nil, role: nil))
      ])
    let error = try #require(decodeError(spanStart(phase: "warmup")))
    #expect(error.contains("phase"), "\(error)")
  }

  @Test(
    "a spanID of 15 or 17 hex characters, or upper case, fails naming spanID, and 16 decodes — catches an unchecked span id"
  )
  func spanIDIsSixteenHex() throws {
    #expect(try HarnessEventJSON.decode(spanStart(id: "fedcba9876543210")).events.count == 1)
    for bad in ["0123456789abcde", "0123456789abcdef0", "0123456789ABCDEF", "0123456789abcdeg"] {
      let error = try #require(decodeError(spanStart(id: bad)), "\(bad) decoded")
      #expect(error.contains("spanID"), "\(bad): \(error)")
      #expect(!SpanStartEvent.isValidID(bad), "\(bad)")
    }
    #expect(SpanStartEvent.isValidID("0123456789abcdef"))
    let badParent = line(
      kind: "span.start",
      payload:
        "{\"buildRun\":\"b\",\"parentSpan\":\"abc\",\"phase\":\"worker\",\"spanID\":\"0123456789abcdef\"}"
    )
    let error = try #require(decodeError(badParent))
    #expect(error.contains("parentSpan"), "\(error)")
  }

  @Test(
    "a span.end round-trips with its outcome and ms in stream span — catches an end the store can't read back"
  )
  func spanEndRoundTrips() throws {
    let event = HarnessEvent(
      eventID: "e2", parentID: "e1", time: Date(timeIntervalSince1970: 1_790_000_000),
      source: HarnessEventSource(route: nil),
      payload: .spanEnd(
        SpanEndEvent(spanID: "0123456789abcdef", outcome: .halted, milliseconds: 42)))
    let data = try HarnessEventJSON.encodeLine(event)
    #expect(String(decoding: data, as: UTF8.self).contains("\"ms\":42"))
    #expect(try HarnessEventJSON.decode(data).events == [event])
    #expect(event.kind.stream == .span)
    #expect(HarnessEventKind.spanStart.stream == .span)
  }

  @Test(
    "a prove.result with outcome = \"maybe\" fails naming outcome, and a proven one round-trips in stream test — catches an open outcome"
  )
  func proveOutcomeIsClosed() throws {
    let event = HarnessEvent(
      eventID: "e3", parentID: "gate-1", time: Date(timeIntervalSince1970: 1_790_000_000),
      source: HarnessEventSource(route: .check),
      payload: .proveResult(
        ProveResultEvent(
          test: "GateTests.SuiteTests/proves()", testHashed: false, target: "GateTests",
          outcome: .proven, proofBase: "abc1234",
          assertion: ProveAssertion(
            file: "Tests/GateTests/SuiteTests.swift", line: 12, kind: .expect)
        )))
    let data = try HarnessEventJSON.encodeLine(event)
    #expect(try HarnessEventJSON.decode(data).events == [event])
    #expect(!String(decoding: data, as: UTF8.self).contains("testHashed"))
    #expect(event.kind.stream == .test)

    let maybe = line(
      kind: "prove.result",
      payload: "{\"outcome\":\"maybe\",\"target\":\"GateTests\",\"test\":\"t\"}")
    let error = try #require(decodeError(maybe))
    #expect(error.contains("outcome"), "\(error)")
  }

  private func toolsEvent(files: [String]) -> HarnessEvent {
    HarnessEvent(
      eventID: "e4", time: Date(timeIntervalSince1970: 1_790_000_000),
      source: HarnessEventSource(route: .ingest),
      payload: .agentTools(
        AgentToolsEvent(
          sessionID: "s1", agent: .subagent, agentID: "a1", role: .buildWorker, task: "t1",
          buildRun: "b1", windowStart: Date(timeIntervalSince1970: 1_790_000_000),
          windowEnd: Date(timeIntervalSince1970: 1_790_000_060),
          tools: [
            ToolCallCount(tool: .edit, count: 2, milliseconds: 30),
            ToolCallCount(tool: .mcp, count: 1, milliseconds: 5),
          ],
          otherCount: 1, files: files, droppedPaths: 1)))
  }

  @Test(
    "an agent.tools event round-trips in stream usage, and the guard rejects 1 holding an absolute path in files — catches the guard skipping the new kind"
  )
  func agentToolsRoundTripsAndIsGuarded() throws {
    let event = toolsEvent(files: ["Sources/App/Model.swift"])
    let data = try HarnessEventJSON.encodeLine(event)
    #expect(try HarnessEventJSON.decode(data).events == [event])
    #expect(String(decoding: data, as: UTF8.self).contains("\"tool\":\"Edit\""))
    #expect(event.kind.stream == .usage)
    #expect(try EventPayloadGuard.rejection(of: event) == nil)
    #expect(try EventPayloadGuard.rejection(of: toolsEvent(files: ["/etc/hosts"])) == .absolutePath)
  }

  @Test(
    "a gate.step line written before step starts were timed decodes with startMs nil, and a timed step keeps its startMs — catches a required field breaking old stores"
  )
  func gateStepStartIsOptional() throws {
    let old = line(
      kind: "gate.step",
      payload:
        "{\"derivedData\":\"none\",\"ms\":5,\"step\":\"lint\",\"tier\":\"T0\",\"verdict\":\"GREEN\"}"
    )
    let read = try HarnessEventJSON.decode(old)
    guard case .gateStep(let step) = try #require(read.events.first).payload else {
      Issue.record("not a gate.step")
      return
    }
    #expect(step.startMs == nil)

    let timed = GateStepEvent(
      GateStepTiming(
        step: .lint, tier: .t0, milliseconds: 5, verdict: .green, derivedData: .none, startMs: 120))
    #expect(timed.startMs == 120)
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(timed)) as? [String: Any])
    #expect(object["startMs"] as? Int == 120)
  }
}
