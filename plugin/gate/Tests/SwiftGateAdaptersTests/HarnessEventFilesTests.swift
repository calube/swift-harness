import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("harness event files and the judge call hook")
struct HarnessEventFilesTests {
  static let subject = JudgeSubject(
    id: "PassTests/doubles()", file: "Tests/PassTests.swift", line: 4,
    source: "@Test func doubles() { #expect(doubled(2) == 4) }", context: "+func doubled() {}",
    declaredTier: "T1")

  static func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-events-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  static func call(_ id: String) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: Date(timeIntervalSince1970: 1_790_000_000),
      runID: "20260930T120000Z-0000abcd", source: HarnessEventSource(route: .judgeTests),
      payload: .judgeCall(
        JudgeCallEvent(
          role: .answer, backend: .jev, model: "jev-1.13.0", servedModel: "jev-1.13.0",
          questionSet: "test-quality@2-jev",
          questions: [JudgeEventQuestion(id: "fails-if-broken", blocking: true)],
          subject: JudgeEventSubject(subject),
          answers: [
            JudgeAnswer(
              question: "fails-if-broken",
              distribution: ["yes": 0.1, "no": 0.9], rationale: String(repeating: "r", count: 600))
          ], cacheHit: false, latencyMs: 40, backendMs: nil, costUSD: 0.00002, inputTokens: 500,
          outputTokens: 20, error: nil)))
  }

  @Test(
    "16 concurrent writers of 40 events each leave 640 whole lines in the shared log and in the run's copy, every id once — catches torn or lost lines when sessions share a worktree"
  )
  func concurrentAppends() async throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = HarnessEventFiles(root: root)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for writer in 0..<16 {
        group.addTask {
          for index in 0..<40 { try files.append(Self.call("w\(writer)-\(index)")) }
        }
      }
      try await group.waitForAll()
    }

    for runID in [nil, "20260930T120000Z-0000abcd"] {
      let data = try #require(try files.read(.judge, runID: runID))
      let read = try HarnessEventJSON.decode(data)
      #expect(!read.tornLastLine)
      #expect(read.events.count == 640)
      #expect(Set(read.events.map(\.eventID)).count == 640)
    }
    #expect(files.path(.judge, runID: nil).hasSuffix(".harness/events/judge.jsonl"))
  }

  @Test(
    "a log that can't be created throws naming its path — catches a lost event going unreported"
  )
  func unwritableLogNamesPath() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appending(path: ".harness"), withIntermediateDirectories: true)
    // A file where the events directory belongs.
    try Data().write(to: root.appending(path: ".harness/events"))

    #expect(throws: HarnessEventWriteError.self) {
      try HarnessEventFiles(root: root).append(Self.call("x"))
    }
    do {
      try HarnessEventFiles(root: root).append(Self.call("x"))
    } catch {
      #expect(error.path.hasSuffix(".harness/events/judge.jsonl"))
    }
  }

  @Test(
    "a Jev call with a sentinel key in the environment emits its answers, model and cost, and neither its success nor a failure that echoes the key puts the key in any event — catches the key or a header reaching the audit log"
  )
  func jevCallsNeverCarryTheKey() async throws {
    let key = "tsk-sentinel-events-7f3a"
    let log = MemoryEventLog()
    let scope = JudgeEventScope.testing(log, source: HarnessEventSource(route: .judgeAsk))
    let good = JevJudge(
      model: JevPin.model,
      transport: FakeHTTPTransport([try FakeHTTPTransport.captured("test-quality-levels")]),
      environment: [JevPin.keyVariable: key], clock: FakeRetryClock())
    let echoing = JevJudge(
      model: JevPin.model,
      transport: FakeHTTPTransport([
        .response(HTTPResponse(status: 500, body: Data("bad key \(key)".utf8)))
      ]), environment: [JevPin.keyVariable: key], clock: FakeRetryClock())

    try await JudgeEventScope.bind(scope) { () async throws in
      _ = try await good.measuredAnswer(Self.subject, questions: .tests)
      await #expect(throws: JudgeError.self) {
        _ = try await echoing.measuredAnswer(Self.subject, questions: .tests)
      }
    }

    #expect(log.calls.count == 2)
    let answered = try #require(log.calls.first)
    #expect(answered.backend == .jev)
    #expect(answered.servedModel == JevPin.model)
    #expect(answered.answers?.count == 4)
    #expect(answered.costUSD != nil)
    #expect(answered.subject == JudgeEventSubject(Self.subject))
    #expect(log.calls.last?.error?.kind == .malformedReply)
    #expect(log.calls.last?.answers == nil)
    #expect(log.events.allSatisfy { $0.source.route == .judgeAsk })
    let text = try log.events.map {
      String(decoding: try HarnessEventJSON.encodeLine($0), as: UTF8.self)
    }
    .joined()
    #expect(!text.isEmpty)
    #expect(!text.contains(key))
    #expect(!text.lowercased().contains("authorization"))
  }

  @Test(
    "a cached answer emits a call marked as a cache hit costing 0, after the first ask emitted 1 that wasn't — catches a cache hit counted as a paid backend call"
  )
  func cacheHitIsMarked() async throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let log = MemoryEventLog()
    let judge = CachingJudge(
      FakeJudge(
        identity: JudgeIdentity(backend: "claude", model: "sonnet"),
        usage: JudgeUsage(costUSD: 0.01, wallMilliseconds: 900)
      ) { _, questions throws(JudgeError) in
        questions.questions.map {
          JudgeAnswer(
            question: $0.id,
            distribution: Dictionary(
              uniqueKeysWithValues: $0.options.enumerated().map { ($1, $0 == 0 ? 1.0 : 0.0) }),
            rationale: "r")
        }
      }, cache: FileJudgeCache(directory: root))

    try await JudgeEventScope.bind(JudgeEventScope.testing(log)) { () throws(JudgeError) in
      _ = try await judge.measuredAnswer(Self.subject, questions: .tests)
      _ = try await judge.measuredAnswer(Self.subject, questions: .tests)
    }

    #expect(log.calls.map(\.cacheHit) == [false, true])
    #expect(log.calls.map(\.costUSD) == [0.01, 0])
    #expect(log.calls.first?.latencyMs == 900)
  }
}
