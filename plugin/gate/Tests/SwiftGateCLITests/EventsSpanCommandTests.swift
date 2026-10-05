import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("events span start and events span end")
struct EventsSpanCommandTests {
  static let runStart = Date(timeIntervalSince1970: 1_790_000_000)
  static let buildRun = RunID.make(startedAt: runStart, suffix: 0x2b)
  static let spanID = "00c0ffee12345678"

  static func temporaryRoot() -> URL {
    TestTemporaryDirectory.root.appending(
      path: "swiftgate-span-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  static func log(_ root: URL, at seconds: Double, id: String, span: String = spanID) -> SpanLog {
    SpanLog(
      root: root, now: { runStart.addingTimeInterval(seconds) }, newEventID: { id },
      newSpanID: { span })
  }

  static func start(
    _ root: URL, at seconds: Double, id: String, phase: String = "worker",
    task: String? = "parse-config", role: String? = "build-worker", parent: String? = nil,
    enabled: Bool = true
  ) -> SpanRun.Output {
    SpanRun.start(
      log: log(root, at: seconds, id: id), enabled: enabled, phase: phase, buildRun: buildRun,
      task: task, role: role, parent: parent)
  }

  static func end(
    _ root: URL, at seconds: Double, id: String, span: String = spanID, outcome: String = "ok",
    enabled: Bool = true
  ) -> SpanRun.Output {
    SpanRun.end(
      log: log(root, at: seconds, id: id), enabled: enabled, spanID: span, outcome: outcome)
  }

  static func events(_ root: URL) throws -> [HarnessEvent] {
    guard let data = try HarnessEventFiles(root: root).read(.span, runID: nil) else { return [] }
    return try HarnessEventJSON.decode(data).events
  }

  @Test(
    "start prints the new span id and end writes ms from the start's time with the start as parent — catches ms measured from anything but the start"
  )
  func startThenEndRecordsThePair() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let started = Self.start(root, at: 600, id: "start-1", parent: "0123456789abcdef")
    let ended = Self.end(root, at: 612.345, id: "end-1", outcome: "red")

    #expect(started.status == 0, "\(started)")
    #expect(started.stdout == Self.spanID, "\(started)")
    #expect(ended.status == 0, "\(ended)")
    let events = try Self.events(root)
    #expect(events.map(\.eventID) == ["start-1", "end-1"])
    #expect(
      events.first?.payload
        == .spanStart(
          SpanStartEvent(
            spanID: Self.spanID, parentSpan: "0123456789abcdef", phase: .worker,
            buildRun: Self.buildRun, task: "parse-config", role: .buildWorker)))
    let end = try #require(events.last)
    #expect(end.parentID == "start-1")
    #expect(end.time == Self.runStart.addingTimeInterval(612.345))
    #expect(
      end.payload
        == .spanEnd(SpanEndEvent(spanID: Self.spanID, outcome: .red, milliseconds: 12_345)))
  }

  @Test(
    "an end whose span id no start wrote exits 1 and the store gains no line — catches an orphan end"
  )
  func unknownSpanIDWritesNothing() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let orphan = Self.end(root, at: 1, id: "end-0")
    #expect(orphan.status == 1, "\(orphan)")
    #expect(orphan.stderr.contains(Self.spanID), "\(orphan)")
    #expect(try Self.events(root).isEmpty)

    #expect(Self.start(root, at: 2, id: "start-1").status == 0)
    let other = Self.end(root, at: 3, id: "end-1", span: "ffffffffffffffff")
    #expect(other.status == 1, "\(other)")
    #expect(try Self.events(root).map(\.eventID) == ["start-1"])
  }

  @Test(
    "a start with --end-parent ends its still-open parent with that outcome before it starts, starts anyway when the parent already ended, and refuses an outcome outside the list with nothing written — catches a reviewer chaining the end of the stage before it with its own start in 1 Bash call, which its guard refuses"
  )
  func startEndsItsOpenParent() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let worker = "000000000000000a"
    let review = "000000000000000b"
    func log(at seconds: Double, span: String) -> SpanLog {
      SpanLog(
        root: root, now: { Self.runStart.addingTimeInterval(seconds) },
        newEventID: { UUID().uuidString }, newSpanID: { span })
    }
    func start(at seconds: Double, span: String, phase: String, parent: String?, end: String?)
      -> SpanRun.Output
    {
      SpanRun.start(
        log: log(at: seconds, span: span), enabled: true, phase: phase, buildRun: Self.buildRun,
        task: "parse-config", role: "review", parent: parent, endParent: end)
    }

    #expect(start(at: 0, span: worker, phase: "worker", parent: nil, end: nil).status == 0)
    let reviewed = start(at: 10, span: review, phase: "review", parent: worker, end: "red")
    #expect(reviewed.status == 0, "\(reviewed)")
    #expect(reviewed.stdout == review)
    #expect(
      SpanRun.end(log: log(at: 15, span: review), enabled: true, spanID: review, outcome: "ok")
        .status == 0)
    let verified = start(
      at: 20, span: "000000000000000c", phase: "verify", parent: review, end: "ok")
    #expect(verified.status == 0, "\(verified)")
    let refused = start(
      at: 30, span: "000000000000000d", phase: "verify", parent: review, end: "done")
    #expect(refused.status == 2, "\(refused)")

    let payloads = try Self.events(root).map(\.payload)
    #expect(payloads.count == 5, "\(payloads)")
    #expect(
      payloads.compactMap { payload -> SpanEndEvent? in
        guard case .spanEnd(let end) = payload else { return nil }
        return end
      } == [
        SpanEndEvent(spanID: worker, outcome: .red, milliseconds: 10_000),
        SpanEndEvent(spanID: review, outcome: .ok, milliseconds: 5_000),
      ])
    #expect(
      payloads.compactMap { payload -> String? in
        guard case .spanStart(let start) = payload else { return nil }
        return start.spanID
      } == [worker, review, "000000000000000c"])
  }

  @Test("a second end of 1 span exits 1 and writes nothing — catches a span closed twice")
  func secondEndIsRefused() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(Self.start(root, at: 0, id: "start-1").status == 0)
    #expect(Self.end(root, at: 5, id: "end-1").status == 0)
    let again = Self.end(root, at: 9, id: "end-2", outcome: "abandoned")

    #expect(again.status == 1, "\(again)")
    #expect(again.stderr.contains(Self.spanID), "\(again)")
    #expect(try Self.events(root).map(\.eventID) == ["start-1", "end-1"])
  }

  @Test(
    "an unknown phase, outcome or role exits 2 naming every allowed value and writes nothing — catches free text reaching the store"
  )
  func unknownValuesNameTheAllowedList() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let cases: [(SpanRun.Output, [String])] = [
      (Self.start(root, at: 0, id: "s-1", phase: "warmup"), SpanPhase.allCases.map(\.rawValue)),
      (Self.start(root, at: 0, id: "s-2", role: "intern"), AgentRole.allCases.map(\.rawValue)),
    ]
    for (output, allowed) in cases {
      #expect(output.status == 2, "\(output)")
      for value in allowed {
        #expect(output.stderr.contains(value), "\(value) missing from: \(output.stderr)")
      }
    }
    #expect(try Self.events(root).isEmpty)

    #expect(Self.start(root, at: 1, id: "start-1").status == 0)
    let outcome = Self.end(root, at: 2, id: "end-1", outcome: "done")
    #expect(outcome.status == 2, "\(outcome)")
    for value in SpanOutcome.allCases.map(\.rawValue) {
      #expect(outcome.stderr.contains(value), "\(value) missing from: \(outcome.stderr)")
    }
    #expect(try Self.events(root).map(\.eventID) == ["start-1"])
  }

  @Test(
    "a build run, task, parent or span id that isn't an id exits 2 and writes nothing — catches a path or free text in a payload"
  )
  func badIDsAreRefused() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let outputs = [
      SpanRun.start(
        log: Self.log(root, at: 0, id: "s-1"), enabled: true, phase: "plan",
        buildRun: "../elsewhere", task: nil, role: nil, parent: nil),
      Self.start(root, at: 0, id: "s-2", task: "why it stalled"),
      Self.start(root, at: 0, id: "s-3", parent: "/tmp/span"),
      Self.end(root, at: 0, id: "e-1", span: "0123456789ABCDEF"),
    ]
    for output in outputs {
      #expect(output.status == 2, "\(output)")
      #expect(output.stderr.split(separator: "\n").count == 1, "\(output)")
    }
    #expect(try Self.events(root).isEmpty)
  }

  @Test(
    "with telemetry off, start and end write nothing, say so in 1 line and exit 0 — catches the opt-out stopping a build"
  )
  func telemetryOffRecordsNothing() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    for output in [
      Self.start(root, at: 0, id: "s-1", enabled: false),
      Self.end(root, at: 1, id: "e-1", enabled: false),
    ] {
      #expect(output.status == 0, "\(output)")
      #expect(output.stdout.isEmpty, "\(output)")
      #expect(output.stderr.contains("telemetry is off"), "\(output)")
      #expect(output.stderr.split(separator: "\n").count == 1, "\(output)")
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test(
    "a span started in 1 linked worktree ends from another and lands in the main checkout's store — catches a per-worktree write"
  )
  func spansLandInTheMainStore() async throws {
    let main = try ProbeRepository()
    let runner = LiveProcessRunner(baseEnvironment: Self.gitEnvironment)
    let first = Self.sibling(of: main.root, "first")
    let second = Self.sibling(of: main.root, "second")
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
      main.remove()
    }
    try await Self.git(runner, in: main.root, "init", "-q", "-b", "main")
    try await Self.git(runner, in: main.root, "add", "-A")
    try await Self.git(runner, in: main.root, "commit", "-q", "-m", "base")
    try await Self.git(runner, in: main.root, "worktree", "add", "-q", "-b", "a", first.path)
    try await Self.git(runner, in: main.root, "worktree", "add", "-q", "-b", "b", second.path)

    let index = SpanStoreIndex(directory: Self.temporaryRoot())
    defer { try? FileManager.default.removeItem(at: index.directory) }
    let before = Date()  // swiftgate:allow det.date-init — bounds the real elapsed time
    let started = await SpanRun.start(
      in: first.path, phase: "review", buildRun: Self.buildRun, task: "parse-config",
      role: "review", parent: nil, index: index)
    #expect(started.status == 0, "\(started)")
    let ended = await SpanRun.end(
      in: second.path, spanID: started.stdout, outcome: "ok", index: index)
    let after = Date()  // swiftgate:allow det.date-init — bounds the real elapsed time
    let elapsed = after.timeIntervalSince(before)
    #expect(ended.status == 0, "\(ended)")

    for worktree in [first, second] {
      #expect(try Self.events(worktree).isEmpty, "\(worktree.lastPathComponent) holds spans")
    }
    let events = try Self.events(main.root)
    #expect(events.count == 2)
    guard case .spanEnd(let end) = events.last?.payload else {
      Issue.record("no span.end in the main store: \(events)")
      return
    }
    #expect(end.spanID == started.stdout)
    #expect(events.last?.parentID == events.first?.eventID)
    #expect(Double(end.milliseconds) <= elapsed * 1000 + 1000, "\(end.milliseconds) ms")
  }

  @Test(
    "the trial's contract span, started in the clone's checkout, ends from a directory in another repository and lands in the clone's store — catches the price-tracker-4 contract span left open because its end ran from the plugin's skill directory"
  )
  func spanEndsFromAnotherRepository() async throws {
    let clone = try ProbeRepository()
    let elsewhere = try ProbeRepository()
    let runner = LiveProcessRunner(baseEnvironment: Self.gitEnvironment)
    let index = SpanStoreIndex(directory: Self.temporaryRoot())
    defer {
      try? FileManager.default.removeItem(at: index.directory)
      clone.remove()
      elsewhere.remove()
    }
    for repository in [clone, elsewhere] {
      try await Self.git(runner, in: repository.root, "init", "-q", "-b", "main")
    }
    let skills = elsewhere.root.appending(path: "skills/build", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)

    let started = await SpanRun.start(
      in: clone.root.path, phase: "contract", buildRun: "spec", task: nil, role: nil,
      parent: nil, index: index)
    #expect(started.status == 0, "\(started)")
    let ended = await SpanRun.end(
      in: skills.path, spanID: started.stdout, outcome: "ok", index: index)
    #expect(ended.status == 0, "\(ended)")

    #expect(try Self.events(elsewhere.root).isEmpty, "the other repository holds spans")
    let events = try Self.events(clone.root)
    #expect(events.count == 2)
    guard case .spanEnd(let end) = events.last?.payload else {
      Issue.record("no span.end in the clone's store: \(events)")
      return
    }
    #expect(end.spanID == started.stdout)
    #expect(index.root(spanID: started.stdout) != nil)
  }

  @Test(
    "an index entry older than the kept window is dropped on the next start, and a span the index never saw ends from its own repository — catches an index that grows forever or one that blocks a plain end"
  )
  func indexPrunesAndFallsBack() async throws {
    let repository = try ProbeRepository()
    let runner = LiveProcessRunner(baseEnvironment: Self.gitEnvironment)
    let index = SpanStoreIndex(directory: Self.temporaryRoot())
    defer {
      try? FileManager.default.removeItem(at: index.directory)
      repository.remove()
    }
    try await Self.git(runner, in: repository.root, "init", "-q", "-b", "main")
    index.record(spanID: "0123456789abcdef", root: repository.root)
    let old = index.directory.appending(path: "0123456789abcdef")
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -SpanStoreIndex.retainedSeconds - 60)],
      ofItemAtPath: old.path)

    let started = await SpanRun.start(
      in: repository.root.path, phase: "plan", buildRun: "spec", task: nil, role: nil,
      parent: nil, index: index)
    #expect(started.status == 0, "\(started)")
    #expect(index.root(spanID: "0123456789abcdef") == nil)
    #expect(
      index.root(spanID: started.stdout)?.standardizedFileURL.path
        == repository.root.standardizedFileURL.path)

    let other = SpanStoreIndex(directory: Self.temporaryRoot())
    let ended = await SpanRun.end(
      in: repository.root.path, spanID: started.stdout, outcome: "ok", index: other)
    #expect(ended.status == 0, "\(ended)")
  }

  @Test(
    "a store holding a real recorded sequence refuses a second end of each of its spans, and its ms match the gap between start and end — catches ends matched to the wrong start"
  )
  func recordedSequenceIsClosed() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorded = try Fixture.data("RunView/span-sequence/span.jsonl")
    let store = URL(filePath: HarnessEventFiles(root: root).path(.span, runID: nil))
    try FileManager.default.createDirectory(
      at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
    try recorded.write(to: store)

    let events = try Self.events(root)
    var starts: [String: HarnessEvent] = [:]
    for event in events {
      guard case .spanStart(let start) = event.payload else { continue }
      starts[start.spanID] = event
    }
    #expect(starts.count == 2)
    for event in events {
      guard case .spanEnd(let end) = event.payload else { continue }
      let start = try #require(starts[end.spanID])
      #expect(event.parentID == start.eventID)
      let gap = event.time.timeIntervalSince(start.time) * 1000
      #expect(abs(Double(end.milliseconds) - gap) <= 1, "\(end.milliseconds) ms against \(gap)")
      let again = Self.end(root, at: 0, id: "again-\(end.spanID)", span: end.spanID)
      #expect(again.status == 1, "\(again)")
    }
    #expect(try Self.events(root).count == events.count)
  }

  static let gitEnvironment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  static func sibling(of root: URL, _ name: String) -> URL {
    root.deletingLastPathComponent()
      .appending(path: "\(root.lastPathComponent)-\(name)", directoryHint: .isDirectory)
  }

  static func git(_ runner: LiveProcessRunner, in directory: URL, _ arguments: String...)
    async throws
  {
    let result = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: directory.path,
        timeout: .seconds(30)))
    try #require(result.status.isSuccess, "git \(arguments): \(result.stderr.text)")
  }
}
