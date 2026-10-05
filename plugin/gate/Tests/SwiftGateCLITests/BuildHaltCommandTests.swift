import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("build halt and build resume")
struct BuildHaltCommandTests {
  static let runStart = Date(timeIntervalSince1970: 1_790_000_000)
  /// A build run id whose own start is an hour before any halt, so a wait taken from the run's
  /// start can't pass for one taken from the halt.
  static let buildRun = RunID.make(startedAt: runStart, suffix: 0x2a)

  static func temporaryRoot() -> URL {
    TestTemporaryDirectory.root.appending(
      path: "swiftgate-build-halt-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  static func log(_ root: URL, at seconds: Double, id: String) -> BuildHaltLog {
    BuildHaltLog(
      root: root, now: { runStart.addingTimeInterval(seconds) }, newEventID: { id })
  }

  static func halt(
    _ root: URL, at seconds: Double, id: String, task: String?, reason: BuildHaltReason = .stall
  ) -> BuildHaltRun.Output {
    BuildHaltRun.halt(
      log: log(root, at: seconds, id: id), enabled: true, buildRun: buildRun, task: task,
      reason: reason, json: false)
  }

  static func resume(
    _ root: URL, at seconds: Double, id: String, task: String?,
    answer: BuildResumeAnswer = .retry
  ) -> BuildHaltRun.Output {
    BuildHaltRun.resume(
      log: log(root, at: seconds, id: id), enabled: true, buildRun: buildRun, task: task,
      answer: answer, json: false)
  }

  static func events(_ root: URL) throws -> [HarnessEvent] {
    guard let data = try HarnessEventFiles(root: root).read(.build, runID: nil) else { return [] }
    return try HarnessEventJSON.decode(data).events
  }

  @Test(
    "a resume's wait runs from its halt's time to its own, and its parent is the halt — catches wait measured from the run start"
  )
  func resumeTimesTheWaitFromTheHalt() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let halted = Self.halt(root, at: 3_600, id: "halt-1", task: "parse-config", reason: .question)
    let resumed = Self.resume(root, at: 3_780.25, id: "resume-1", task: "parse-config")

    #expect(halted.status == 0, "\(halted)")
    #expect(resumed.status == 0, "\(resumed)")
    let events = try Self.events(root)
    #expect(events.map(\.eventID) == ["halt-1", "resume-1"])
    #expect(
      events.first?.payload
        == .buildHalt(
          BuildHaltEvent(buildRun: Self.buildRun, task: "parse-config", reason: .question))
    )
    let resume = try #require(events.last)
    #expect(resume.parentID == "halt-1")
    #expect(resume.time == Self.runStart.addingTimeInterval(3_780.25))
    #expect(
      resume.payload
        == .buildResume(
          BuildResumeEvent(
            buildRun: Self.buildRun, task: "parse-config", answer: .retry,
            waitMilliseconds: 180_250)))
  }

  @Test(
    "a resume with no open halt exits 1 and writes nothing — catches a resume that invents a halt or answers one twice"
  )
  func resumeWithoutAnOpenHaltWritesNothing() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let orphan = Self.resume(root, at: 10, id: "resume-0", task: nil)
    #expect(orphan.status == 1, "\(orphan)")
    #expect(orphan.stderr.contains(Self.buildRun), "\(orphan)")
    #expect(try Self.events(root).isEmpty)

    #expect(Self.halt(root, at: 20, id: "halt-1", task: nil, reason: .budget).status == 0)
    #expect(Self.resume(root, at: 30, id: "resume-1", task: nil).status == 0)
    let again = Self.resume(root, at: 40, id: "resume-2", task: nil)
    #expect(again.status == 1, "\(again)")
    #expect(try Self.events(root).map(\.eventID) == ["halt-1", "resume-1"])
  }

  @Test(
    "a halt for 1 task isn't answered by a resume for another, or by one for the whole run — catches a resume scoped to the run, not the task"
  )
  func resumeAnswersOnlyItsOwnTask() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(Self.halt(root, at: 0, id: "halt-a", task: "task-a").status == 0)
    let other = Self.resume(root, at: 5, id: "resume-b", task: "task-b")
    let whole = Self.resume(root, at: 6, id: "resume-run", task: nil)
    #expect(other.status == 1, "\(other)")
    #expect(whole.status == 1, "\(whole)")
    #expect(try Self.events(root).map(\.eventID) == ["halt-a"])

    #expect(Self.resume(root, at: 9, id: "resume-a", task: "task-a").status == 0)
    #expect(try Self.events(root).last?.parentID == "halt-a")
  }

  @Test(
    "a resume answers the newest open halt of its task, and an unanswered halt stays open — catches a halt with no resume that vanishes"
  )
  func newestOpenHaltIsAnsweredAndTheRestStayOpen() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(Self.halt(root, at: 0, id: "halt-old", task: "task-a").status == 0)
    #expect(Self.halt(root, at: 50, id: "halt-new", task: "task-a").status == 0)
    #expect(Self.halt(root, at: 60, id: "halt-other", task: "task-b").status == 0)
    #expect(Self.resume(root, at: 80, id: "resume-a", task: "task-a").status == 0)

    let events = try Self.events(root)
    #expect(events.last?.parentID == "halt-new")
    #expect(BuildHalts.open(in: events).map(\.eventID) == ["halt-old", "halt-other"])
  }

  @Test(
    "concurrent resumes of 1 halt answer it once — catches a race outside the lock"
  )
  func concurrentResumesAnswerOneHaltOnce() async throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let rounds = 12
    let resumers = 8

    for round in 0..<rounds {
      let task = "task-\(round)"
      #expect(Self.halt(root, at: Double(round), id: "halt-\(round)", task: task).status == 0)
      let statuses = await withTaskGroup(of: Int32.self) { group in
        for resumer in 0..<resumers {
          group.addTask {
            await OffPool.run {
              Self.resume(
                root, at: Double(round) + 0.5, id: "resume-\(round)-\(resumer)", task: task
              ).status
            }
          }
        }
        return await group.reduce(into: []) { $0.append($1) }
      }
      #expect(statuses.filter { $0 == 0 }.count == 1, "round \(round): \(statuses)")
      #expect(statuses.filter { $0 == 1 }.count == resumers - 1, "round \(round): \(statuses)")
    }

    let answered = try Self.events(root).compactMap(\.parentID)
    #expect(answered.count == rounds)
    #expect(Set(answered).count == rounds)
  }

  @Test(
    "`--answer stop`, as the run skill words stopping the build, parses as abandon — catches the trial's stop refused as an unknown answer"
  )
  func stopIsAbandon() async throws {
    let parsed = try await SwiftGate.asyncParseAsRoot([
      "build", "resume", "--run", Self.buildRun, "--task", "spec-watchlist", "--answer", "stop",
    ])
    let command = try #require(parsed as? BuildResumeCommand)
    #expect(command.answer == .abandon)
  }

  @Test(
    "every --reason the build loop's halt table and the plugin's prompts name parses, and a halting return outcome the table lists parses as that row's reason — catches the review-blocked halt refused with exit 64"
  )
  func everyDocumentedReasonParses() async throws {
    let plugin = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let loop = try String(
      contentsOf: plugin.appending(path: "skills/build/references/event-loop.md"),
      encoding: .utf8)
    let section = try #require(loop.components(separatedBy: "## Recording halts").last)
    let table = section.split(separator: "\n").drop { !$0.hasPrefix("| Halt |") }
      .prefix { $0.hasPrefix("|") }.dropFirst(2)
    func ticked(_ text: Substring) -> [String] {
      text.split(separator: "`", omittingEmptySubsequences: false).enumerated()
        .filter { $0.offset % 2 == 1 }.map { String($0.element) }
    }
    var expected: [(spelled: String, reason: String)] = []
    for line in table {
      let cells = line.split(separator: "|", omittingEmptySubsequences: false)
      let reasons = ticked(cells[3])
      for reason in reasons { expected.append((reason, reason)) }
      let outcomes = ticked(cells[1]).filter { TaskReturn.Outcome(rawValue: $0) != nil }
      for outcome in outcomes { expected.append((outcome, try #require(reasons.first))) }
    }
    #expect(expected.contains { $0.spelled == "review-blocked" && $0.reason == "question" })
    let prompts = ["skills/build/SKILL.md", "skills/run/SKILL.md", "agents/build-fixer.md"]
    for path in prompts + ["skills/build/references/event-loop.md"] {
      let text = try String(contentsOf: plugin.appending(path: path), encoding: .utf8)
      for match in text.matches(of: /build halt[^`\n]*--reason ([a-z-]+)/) {
        expected.append((String(match.output.1), String(match.output.1)))
      }
    }
    for (spelled, reason) in expected {
      let parsed = try await SwiftGate.asyncParseAsRoot([
        "build", "halt", "--run", Self.buildRun, "--task", "t", "--reason", spelled,
      ])
      let command = try #require(parsed as? BuildHaltCommand, "\(spelled)")
      #expect(command.reason.rawValue == reason, "\(spelled)")
    }
  }

  @Test(
    "an unknown --reason or --answer fails parsing and names every allowed value — catches a free-text reason reaching the store"
  )
  func unknownReasonOrAnswerNamesTheAllowedValues() async throws {
    let cases: [([String], [String])] = [
      (
        ["build", "halt", "--run", Self.buildRun, "--reason", "lunch"],
        BuildHaltReason.allCases.map(\.rawValue)
      ),
      (
        ["build", "resume", "--run", Self.buildRun, "--answer", "maybe"],
        BuildResumeAnswer.allCases.map(\.rawValue)
      ),
    ]
    for (arguments, allowed) in cases {
      do {
        _ = try await SwiftGate.asyncParseAsRoot(arguments)
        Issue.record("\(arguments) parsed instead of failing")
      } catch {
        let message = SwiftGate.message(for: error)
        let listed = message.split(separator: "\n").map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        #expect(SwiftGate.exitCode(for: error).rawValue == 64, "\(message)")
        for value in allowed {
          // ArgumentParser lists a few values inline and more as a bulleted list.
          #expect(
            listed.contains("- \(value)") || message.contains("'\(value)'"),
            "\(value) missing from: \(message)")
        }
      }
    }
  }

  @Test(
    "a run or task that isn't an id exits 2 and writes nothing — catches a path or free text in a payload"
  )
  func badIdsAreRefused() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let badRun = BuildHaltRun.halt(
      log: Self.log(root, at: 0, id: "halt-1"), enabled: true, buildRun: "../elsewhere",
      task: nil, reason: .stall, json: false)
    let badTask = Self.halt(root, at: 0, id: "halt-2", task: "why it stalled")

    #expect(badRun.status == 2, "\(badRun)")
    #expect(badTask.status == 2, "\(badTask)")
    #expect(try Self.events(root).isEmpty)
  }

  @Test(
    "with telemetry off, halt and resume write nothing, say so in 1 line and exit 0 — catches the opt-out stopping a build"
  )
  func telemetryOffRecordsNothing() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let halted = BuildHaltRun.halt(
      log: Self.log(root, at: 0, id: "halt-1"), enabled: false, buildRun: Self.buildRun,
      task: nil, reason: .stall, json: false)
    let resumed = BuildHaltRun.resume(
      log: Self.log(root, at: 1, id: "resume-1"), enabled: false, buildRun: Self.buildRun,
      task: nil, answer: .wait, json: false)

    for output in [halted, resumed] {
      #expect(output.status == 0, "\(output)")
      #expect(output.stderr.split(separator: "\n").count == 1, "\(output)")
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test(
    "a halt whose store can't be written exits 2 with 1 line naming the path — catches a lost halt reported as recorded"
  )
  func unwritableStoreIsReported() throws {
    let root = Self.temporaryRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // A file where the events directory belongs.
    try Data().write(to: root.appending(path: ".harness"))

    let halted = Self.halt(root, at: 0, id: "halt-1", task: nil)

    #expect(halted.status == 2, "\(halted)")
    #expect(halted.stderr.split(separator: "\n").count == 1, "\(halted)")
    #expect(halted.stderr.contains(".harness"), "\(halted)")
  }

  @Test(
    "the fifth send-money trial's budget halt 215 s before its cutoff exits 1 naming build cutoff and records nothing, and at the cutoff it records — catches a time halt taken by hand"
  )
  func budgetHaltBeforeTheCutoffIsRefused() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try BuildRunJSON.decode(Fixture.data("BuildReturn/send-money-5/run.json"))
    let cutoffAt = try #require(record.timeBox).deadlines.cutoffAt
    let clock = try Fixture.text("BuildReturn/send-money-5/clock-and-cutoff-at-return.txt")
    let match = try #require(clock.firstMatch(of: /"now" : "([^"]+)"/))
    let now = try Date(String(match.1), strategy: .iso8601)
    func halt(at time: Date, id: String) -> BuildHaltRun.Output {
      BuildHaltRun.halt(
        log: BuildHaltLog(root: root, now: { time }, newEventID: { id }), enabled: true,
        buildRun: record.runID, task: nil, reason: .budget, json: false, cutoffAt: cutoffAt)
    }

    let early = halt(at: now, id: "halt-early")
    #expect(early.status == 1, "\(early)")
    #expect(early.stderr.contains("build cutoff"), "\(early)")
    #expect(try Self.events(root).isEmpty)

    let atCutoff = halt(at: cutoffAt, id: "halt-cutoff")
    #expect(atCutoff.status == 0, "\(atCutoff)")
    #expect(try Self.events(root).map(\.eventID) == ["halt-cutoff"])
  }
}
