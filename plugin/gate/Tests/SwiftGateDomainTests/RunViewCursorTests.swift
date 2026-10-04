import Foundation
import SwiftGateDomain
import Testing

@Suite("Run view cursor and changes")
struct RunViewCursorTests {
  static let start = Date(timeIntervalSince1970: 1_790_000_000)

  static func snapshot(_ files: [String: Int]) -> RunViewSnapshot {
    RunViewSnapshot(files: files.mapValues { RunViewSnapshot.Stamp(bytes: $0) })
  }

  static func view(cursor: String, spanEnd: Date? = nil, gates: [RunView.Gate] = []) -> RunView {
    RunView(
      cursor: cursor,
      run: RunView.Run(id: "20261004T045528Z-58d28c78", startedAt: start),
      tasks: [RunView.Task(id: "parse-config", status: .inProgress, gate: .push)],
      spans: [
        RunView.Span(id: "run", phase: .run, start: start),
        RunView.Span(
          id: "task-parse-config", parent: "run", phase: .task, task: "parse-config",
          start: start, end: spanEnd),
      ],
      gates: gates,
      halts: [RunView.Halt(task: "parse-config", reason: .question, at: start)])
  }

  @Test(
    "a snapshot's cursor names its files' lengths, not the order they were listed in — catches a cursor that misses an appended byte"
  )
  func cursorFollowsLengths() {
    let listed = Self.snapshot([".harness/events/build.jsonl": 120, "ledger log": 40])
    var reordered = RunViewSnapshot()
    reordered.files["ledger log"] = RunViewSnapshot.Stamp(bytes: 40)
    reordered.files[".harness/events/build.jsonl"] = RunViewSnapshot.Stamp(bytes: 120)
    let appended = Self.snapshot([".harness/events/build.jsonl": 121, "ledger log": 40])
    let rewritten = RunViewSnapshot(files: [
      ".harness/events/build.jsonl": RunViewSnapshot.Stamp(bytes: 120),
      "ledger log": RunViewSnapshot.Stamp(bytes: 40, modifiedNanoseconds: 7),
    ])

    #expect(!listed.cursor.isEmpty)
    #expect(listed.cursor == reordered.cursor)
    #expect(listed.cursor != appended.cursor)
    #expect(listed.cursor != rewritten.cursor)
    #expect(EventPayloadGuard.rejection(inJSON: listed.cursor) == nil)
  }

  @Test(
    "changes hold only the rows that differ and the new cursor — catches a poll that resends the whole view"
  )
  func changesHoldOnlyChangedRows() throws {
    let old = Self.view(cursor: "c-old")
    let gate = RunView.Gate(runID: "20261004T050000Z-0a1b2c3d", verdict: .green, milliseconds: 9)
    let new = Self.view(
      cursor: "c-new", spanEnd: Self.start.addingTimeInterval(60), gates: [gate])

    let changes = RunViewChanges.between(old, new)

    #expect(changes.cursor == "c-new")
    #expect(changes.spans?.map(\.id) == ["task-parse-config"])
    #expect(changes.gates == [gate])
    #expect(changes.run == nil)
    #expect(changes.tasks == nil)
    #expect(changes.halts == nil)
    let object = try JSONSerialization.jsonObject(with: RunViewJSON.encode(changes))
    #expect(
      (object as? [String: Any]).map { Set($0.keys) } == ["cursor", "spans", "gates"])
  }

  @Test(
    "a changed run row is sent whole — catches a run state change the page never sees"
  )
  func changedRunIsSent() {
    let old = Self.view(cursor: "c-old")
    var new = Self.view(cursor: "c-new")
    new.run.state = .halted
    #expect(RunViewChanges.between(old, new).run == new.run)
  }

  @Test(
    "a cursor the book never answered gets the whole view — catches a stale or malformed cursor answered with an error or nothing"
  )
  func unknownCursorGetsFullView() {
    var book = RunViewCursorBook()
    let snapshot = Self.snapshot(["a": 1])
    let built = Self.view(cursor: snapshot.cursor)
    for cursor in [nil, "", "not a cursor", Self.snapshot(["a": 0]).cursor] {
      #expect(book.answer(after: cursor, snapshot: snapshot) { built } == .full(built))
    }
  }

  @Test(
    "a poll whose snapshot hasn't moved gets only its cursor back and reads nothing — catches a rebuild on every poll"
  )
  func unmovedSnapshotSkipsTheBuild() {
    var book = RunViewCursorBook()
    let snapshot = Self.snapshot(["a": 1])
    let built = Self.view(cursor: snapshot.cursor)
    #expect(book.answer(after: nil, snapshot: snapshot) { built } == .full(built))
    var builds = 0
    let answer = book.answer(after: snapshot.cursor, snapshot: snapshot) {
      builds += 1
      return Self.view(cursor: snapshot.cursor)
    }
    #expect(answer == .changes(RunViewChanges(cursor: snapshot.cursor)))
    #expect(builds == 0)
  }

  @Test(
    "a poll after a cursor the book answered gets the changes since that view, under the new cursor — catches a diff against the wrong view"
  )
  func knownCursorGetsChanges() {
    var book = RunViewCursorBook()
    let first = Self.snapshot(["a": 1])
    let second = Self.snapshot(["a": 2])
    let third = Self.snapshot(["a": 3])
    let ended = Self.start.addingTimeInterval(60)
    _ = book.answer(after: nil, snapshot: first) { Self.view(cursor: "ignored") }
    _ = book.answer(after: first.cursor, snapshot: second) { Self.view(cursor: "ignored") }

    // A page still on the first cursor gets the end it missed, measured from the first view.
    let answer = book.answer(after: first.cursor, snapshot: third) {
      Self.view(cursor: "ignored", spanEnd: ended)
    }
    guard case .changes(let changes) = answer else {
      Issue.record("a known cursor got \(answer)")
      return
    }
    #expect(changes.cursor == third.cursor)
    #expect(changes.spans?.map(\.end) == [ended])
    #expect(changes.halts == nil)
  }

  @Test(
    "the book keeps a bounded number of views — catches a server that grows with every poll"
  )
  func bookIsBounded() {
    var book = RunViewCursorBook()
    let oldest = Self.snapshot(["a": 0])
    _ = book.answer(after: nil, snapshot: oldest) { Self.view(cursor: "") }
    for bytes in 1...RunViewCursorBook.capacity {
      _ = book.answer(after: nil, snapshot: Self.snapshot(["a": bytes])) { Self.view(cursor: "") }
    }
    let newest = Self.snapshot(["a": RunViewCursorBook.capacity])
    let evicted = book.answer(after: oldest.cursor, snapshot: Self.snapshot(["a": 99])) {
      Self.view(cursor: "")
    }
    let kept = book.answer(after: newest.cursor, snapshot: Self.snapshot(["a": 100])) {
      Self.view(cursor: "")
    }
    if case .changes = evicted { Issue.record("an evicted cursor still got changes") }
    if case .full = kept { Issue.record("the newest cursor got the whole view") }
  }
}
