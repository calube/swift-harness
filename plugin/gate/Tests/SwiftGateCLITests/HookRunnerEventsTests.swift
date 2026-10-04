import CryptoKit
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

@Suite("hook decision events")
struct HookRunnerEventsTests {
  /// Counts what it's handed, then refuses it.
  private final class RefusingWriter: HarnessEventWriting {
    private let handed = Mutex(0)

    var events: Int { handed.withLock { $0 } }

    func append(_ event: HarnessEvent) throws(HarnessEventWriteError) {
      handed.withLock { $0 += 1 }
      throw HarnessEventWriteError(path: "hook.jsonl", reason: "disk full")
    }
  }

  /// Keeps what it's handed.
  private final class KeepingWriter: HarnessEventWriting {
    private let kept = Mutex<[HarnessEvent]>([])

    var events: [HarnessEvent] { kept.withLock { $0 } }

    func append(_ event: HarnessEvent) throws(HarnessEventWriteError) {
      kept.withLock { $0.append(event) }
    }
  }

  private static func eventsFile(_ root: URL) -> URL {
    StateRoot.tree(root).url(RunLayout.eventsFile(.hook))
  }

  /// The hook stream's text; empty when nothing wrote it.
  private static func text(_ root: URL) -> String {
    String(
      decoding: FileManager.default.contents(atPath: eventsFile(root).path) ?? Data(), as: UTF8.self
    )
  }

  private static func events(_ root: URL) throws -> [HarnessEvent] {
    try HarnessEventJSON.decode(Data(text(root).utf8)).events
  }

  private static func decision(_ event: HarnessEvent) throws -> HookDecisionEvent {
    guard case .hookDecision(let decision) = event.payload else {
      throw NotAHookDecision(kind: event.kind)
    }
    return decision
  }

  private struct NotAHookDecision: Error {
    let kind: HarnessEventKind
  }

  /// Runs `fixture` against `harness` with `telemetry` standing in for the project's.
  private static func run(
    _ harness: HookHarness, _ event: HookEvent, _ fixture: String,
    telemetry: @escaping @Sendable () -> HookTelemetry?, cwd: URL? = nil,
    replacing: [String: String] = [:]
  ) async throws -> HookResult {
    let input = try harness.payload(fixture, cwd: cwd, replacing: replacing)
    var dependencies = harness.dependencies
    dependencies.telemetry = telemetry
    return await HookRunner.run(event, input: input) { _ in dependencies }
  }

  private static func live(_ root: URL) -> @Sendable () -> HookTelemetry? {
    { HookTelemetry.live(root: root) }
  }

  @Test(
    "a captured PreToolUse payload gives 1 hook.decision with its tool, the decision the hook printed, its rule id and a latency — catches an event written before the hook runs"
  )
  func capturedPreToolUse() async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }

    let result = try await Self.run(
      harness, .preToolUse, "pre-tool-use-bash-xcodebuild", telemetry: Self.live(harness.root))

    let output = try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
    #expect(output["permissionDecision"] == "deny")
    let events = try Self.events(harness.root)
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.kind == .hookDecision)
    #expect(event.source == HarnessEventSource(route: .hook, hook: .preToolUse))
    let decision = try Self.decision(event)
    #expect(decision.event == .preToolUse)
    #expect(decision.tool == "Bash")
    #expect(decision.decision == .block)
    #expect(decision.ruleIDs == [BashGuard.rawXcodebuildRuleID])
    #expect(decision.milliseconds >= 0)
    #expect(decision.sessionID == "8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f")
    #expect(decision.inputHash?.count == 64)
  }

  @Test(
    "the payload's command string, file path and the hook's reason text appear nowhere in the event file — catches tool input or hook output stored as text",
    arguments: [
      ("pre-tool-use-bash-xcodebuild", HookEvent.preToolUse),
      ("pre-tool-use-bash-allowed", .preToolUse),
      ("pre-tool-use-edit-swift", .preToolUse),
    ])
  func noInputText(fixture: String, event: HookEvent) async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }

    let result = try await Self.run(harness, event, fixture, telemetry: Self.live(harness.root))

    let file = Self.text(harness.root)
    #expect(file.split(separator: "\n").count == 1)
    let payload = try #require(
      try JSONSerialization.jsonObject(with: harness.payload(fixture)) as? [String: Any])
    let input = try #require(payload["tool_input"] as? [String: Any])
    for case let value as String in input.values {
      #expect(!file.contains(value), "\(fixture)'s `\(value)` is in the event file")
    }
    #expect(!file.contains(harness.root.path))
    if let reason = try result.stdout.flatMap({ try harness.json(HookResult.output($0)) }) {
      let text = (reason["hookSpecificOutput"] as? [String: String])?["permissionDecisionReason"]
      #expect(!file.contains(try #require(text)))
    }
  }

  @Test(
    "2 identical inputs give 1 hash, another input another, and the same input under another store's salt another — catches an unsalted or constant hash"
  )
  func saltedHash() async throws {
    let first = try HookHarness()
    let second = try HookHarness()
    defer {
      first.repository.remove()
      second.repository.remove()
    }

    let fixtures = [
      "pre-tool-use-bash-allowed", "pre-tool-use-bash-allowed", "pre-tool-use-edit-swift",
    ]
    for fixture in fixtures {
      _ = try await Self.run(first, .preToolUse, fixture, telemetry: Self.live(first.root))
    }
    _ = try await Self.run(
      second, .preToolUse, "pre-tool-use-bash-allowed", telemetry: Self.live(second.root))

    let hashes = try Self.events(first.root).map { try Self.decision($0).inputHash }
    let other = try Self.events(second.root).map { try Self.decision($0).inputHash }
    try #require(hashes.count == 3)
    #expect(hashes[0] != nil)
    #expect(hashes[0] == hashes[1])
    #expect(hashes[0] != hashes[2])
    try #require(other.count == 1)
    #expect(other[0] != nil)
    #expect(other[0] != hashes[0])
    let input = try #require(
      try JSONSerialization.jsonObject(with: first.payload("pre-tool-use-bash-allowed"))
        as? [String: Any])["tool_input"]
    let unsalted = SHA256.hash(
      data: try JSONSerialization.data(withJSONObject: input as Any, options: [.sortedKeys])
    ).map { String(format: "%02x", $0) }.joined()
    #expect(hashes[0] != unsalted)
  }

  @Test(
    "outside a project, and with [telemetry] enabled = false, a hook writes no event and no store — catches telemetry written where the project opted out or has no config"
  )
  func nothingWritten() async throws {
    let harness = try HookHarness()
    let outside = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let optedOut = try HookHarness()
    try Data(
      (ProbeRepository.config + "\n[telemetry]\nenabled = false\n").utf8
    ).write(to: optedOut.root.appending(path: ConfigLoader.fileName))
    defer {
      harness.repository.remove()
      optedOut.repository.remove()
      try? FileManager.default.removeItem(at: outside)
    }

    let writer = KeepingWriter()
    let kept = HookTelemetry(
      events: writer,
      identity: { () throws(HarnessEventWriteError) in
        try EventSegmentStore(root: harness.root).identity()
      })
    let outsideResult = try await Self.run(
      harness, .preToolUse, "pre-tool-use-bash-xcodebuild", telemetry: { kept }, cwd: outside)
    let optedOutResult = try await Self.run(
      optedOut, .preToolUse, "pre-tool-use-bash-xcodebuild", telemetry: Self.live(optedOut.root))
    let liveResult = try await Self.run(
      harness, .preToolUse, "pre-tool-use-bash-xcodebuild", telemetry: Self.live(harness.root))

    #expect(outsideResult == .silent)
    #expect(writer.events.isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: StateRoot.tree(outside).url(RunLayout.eventsDirectory).path))
    #expect(optedOutResult == liveResult)
    #expect(
      !FileManager.default.fileExists(
        atPath: StateRoot.tree(optedOut.root).url(RunLayout.eventsDirectory).path))
    #expect(try Self.events(harness.root).count == 1)
  }

  @Test(
    "a tool name with a space, or over 128 characters, is absent from the event while an MCP tool's is kept — catches free text stored as a tool name",
    arguments: [
      ("Bash Tool", nil as String?),
      (String(repeating: "T", count: 129), nil),
      ("mcp__swift_harness__events", "mcp__swift_harness__events"),
    ])
  func toolName(name: String, expected: String?) async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }

    _ = try await Self.run(
      harness, .preToolUse, "pre-tool-use-bash-allowed", telemetry: Self.live(harness.root),
      replacing: [#""tool_name": "Bash""#: #""tool_name": "\#(name)""#])

    let events = try Self.events(harness.root)
    #expect(events.count == 1)
    #expect(try Self.decision(try #require(events.first)).tool == expected)
    let file = Self.text(harness.root)
    if expected == nil { #expect(!file.contains(name)) }
  }

  @Test(
    "a writer that throws, or a store that can't name itself, leaves the hook's stdout and exit code as a run with no telemetry has them and says so in 1 stderr line — catches a telemetry failure that changes a hook's decision",
    arguments: ["pre-tool-use-bash-xcodebuild", "pre-tool-use-bash-allowed"])
  func failedWriteKeepsDecision(fixture: String) async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    let refusing = RefusingWriter()
    let identity = try EventSegmentStore(root: harness.root).identity()

    let plain = try await Self.run(harness, .preToolUse, fixture, telemetry: { nil })
    let throwing = try await Self.run(
      harness, .preToolUse, fixture,
      telemetry: { HookTelemetry(events: refusing, identity: { identity }) })
    let nameless = try await Self.run(
      harness, .preToolUse, fixture,
      telemetry: {
        HookTelemetry(
          events: KeepingWriter(),
          identity: { () throws(HarnessEventWriteError) in
            throw HarnessEventWriteError(path: "store.json", reason: "unreadable")
          })
      })

    #expect(refusing.events == 1)
    for result in [throwing, nameless] {
      #expect(result.stdout == plain.stdout)
      #expect(result.exitCode == plain.exitCode)
      let lines = try #require(result.stderr).split(separator: "\n")
      #expect(lines.count == 1)
      #expect(lines.first?.hasPrefix("swiftgate: hook event not written: ") == true)
    }
  }

  /// Logs each step it's asked to take, in order.
  private final class StepLog: Sendable {
    private let steps = Mutex<[String]>([])

    var entries: [String] { steps.withLock { $0 } }

    func append(_ step: String) { steps.withLock { $0.append(step) } }
  }

  private struct LoggingJudge: CommitCommentJudging {
    let log: StepLog

    func review(root: URL) async -> String? {
      log.append("judge")
      return nil
    }
  }

  @Test(
    "the telemetry config and writer are asked for only after the hook's last dependency has answered — catches event work on the hook's decision path"
  )
  func telemetryAfterDecision() async throws {
    var harness = try HookHarness()
    defer { harness.repository.remove() }
    let log = StepLog()
    harness.commitJudge = LoggingJudge(log: log)
    let root = harness.root

    _ = try await Self.run(
      harness, .preToolUse, "pre-tool-use-bash-git-commit",
      telemetry: {
        log.append("telemetry")
        return HookTelemetry.live(root: root)
      })

    #expect(log.entries == ["judge", "telemetry"])
    #expect(try Self.events(root).count == 1)
  }

  @Test(
    "recording a hook's event, config read and store identity included, costs under 10ms of CPU at its fastest of 5, a fifth of PreToolUse's budget — catches a write that rivals the hook's own work"
  )
  func recordCost() async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    let input = try harness.payload("pre-tool-use-bash-xcodebuild")
    let payload = try HookPayload.decode(input)
    let result = HookResult.output(HookOutput.deny("swiftgate guard.raw-xcodebuild: no"))
    _ = try EventSegmentStore(root: harness.root).identity()

    let samples = await Latency.samples {
      let (warning, milliseconds) = await Latency.threadCPUMilliseconds {
        HookTelemetry.live(root: harness.root)?.record(
          .preToolUse, payload: payload, input: input, result: result, milliseconds: 3,
          at: Date())
      }
      #expect(warning == nil)
      return milliseconds
    }

    #expect(try Self.events(harness.root).count == 5)
    #expect(samples.min()! < 10, "recording samples: \(samples)ms of CPU, budget: under 10ms")
  }
}
