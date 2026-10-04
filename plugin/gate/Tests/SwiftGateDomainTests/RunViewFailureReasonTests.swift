import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The `memos-3` brownfield trial's warm-up: its `warmup.run` events, and the times and baseline
/// files it wrote at the base tree. The memos area's Go tests failed with 1 test id; the web
/// area's failed with none read.
private struct Memos3Warmup {
  static let directory = "RunView/brownfield-blocked"
  static let tree = "98ce20b4568e17d2b5fee0f4a11ec054d03d03e2"
  static let memosTest = "45BCDA7C-6BA0-44B8-B894-13B851158D52"
  static let webTest = "AE9DDF06-4CE9-4DDA-BA76-C63837D85CEA"
  static let memosBuild = "140717C0-8AB4-4EC2-8DCE-AA4F5F899ABE"

  let events: [HarnessEvent]
  let times: WarmupTimesFile
  let baseline: BaselineFile

  init() throws {
    events = try HarnessEventJSON.decode(
      try Fixture.data("\(Self.directory)/events/brownfield.jsonl")
    ).events
    times = try WarmupTimesFile.decode(
      try Fixture.data("\(Self.directory)/warmup/\(Self.tree).json"), tree: Self.tree)
    baseline = try BaselineFile.decode(
      try Fixture.data("\(Self.directory)/baseline/\(Self.tree).json"), tree: Self.tree)
  }

  var launched: Date { events.map(\.time).min() ?? Date() }
}

private func words(_ text: String) -> Int {
  text.split(whereSeparator: \.isWhitespace).count
}

private func warmupRun(_ step: WarmupStep, _ outcome: WarmupOutcome) -> WarmupRunEvent {
  WarmupRunEvent(area: "memos", step: step, milliseconds: 1000, cache: .cold, outcome: outcome)
}

@Suite("RunView failure reasons")
struct RunViewFailureReasonTests {
  @Test(
    "a failed warm-up test step says the base commit's tests fail and how many the baseline recorded — catches a red warm-up with no explanation"
  )
  func warmupTestReasons() {
    let test = warmupRun(.test, .failed)
    let five = RunViewFailureReasons.warmup(
      test, baseline: .failedTests(Set((1...5).map { "t\($0)" })))
    #expect(five.reason == "Base commit's tests already fail; 5 recorded as baseline.")
    #expect(five.baseline)
    let one = RunViewFailureReasons.warmup(test, baseline: .failedTests(["t"]))
    #expect(one.reason == "Base commit's tests already fail; 1 recorded as baseline.")
    let whole = RunViewFailureReasons.warmup(test, baseline: .failed)
    #expect(
      whole.reason
        == "Base commit's tests fail, no test names read; whole step recorded as baseline.")
    #expect(whole.baseline)
    let unmatched = RunViewFailureReasons.warmup(test, baseline: nil)
    #expect(unmatched.reason == "Base commit's tests already fail; no baseline record found.")
    #expect(!unmatched.baseline)
  }

  @Test(
    "a failed warm-up build says the base commit doesn't build, a dropped or missing tool says so, and a pass has none — catches a build failure called a test failure"
  )
  func warmupOtherReasons() {
    let build = warmupRun(.build, .failed)
    #expect(
      RunViewFailureReasons.warmup(build, baseline: .failed).reason
        == "Base commit doesn't build; failure recorded as baseline.")
    let unrecorded = RunViewFailureReasons.warmup(build, baseline: nil)
    #expect(unrecorded.reason == "Base commit doesn't build; no baseline record found.")
    #expect(!unrecorded.baseline)
    #expect(
      RunViewFailureReasons.warmup(warmupRun(.generate, .failed), baseline: nil).reason
        == "Project generation failed at the base commit.")
    #expect(
      RunViewFailureReasons.warmup(warmupRun(.install, .failed), baseline: nil).reason
        == "Dependency install failed.")
    #expect(
      RunViewFailureReasons.warmup(warmupRun(.test, .dropped), baseline: nil).reason
        == "Step dropped before it ran.")
    #expect(
      RunViewFailureReasons.warmup(warmupRun(.test, .notInstalled), baseline: nil).reason
        == "The tool this step needs isn't installed.")
    let passed = RunViewFailureReasons.warmup(warmupRun(.test, .passed), baseline: .passed)
    #expect(passed.reason == nil)
    #expect(!passed.baseline)
  }

  @Test(
    "the captured warm-up's steps match the baseline it wrote, so its red spans say what was recorded — catches a reason that ignores the baseline file"
  )
  func capturedWarmup() throws {
    let warmup = try Memos3Warmup()
    let baselines = RunViewWarmupBaselines.match(
      events: warmup.events, times: [warmup.times],
      baselines: [Memos3Warmup.tree: warmup.baseline])
    #expect(
      baselines[Memos3Warmup.memosTest]
        == .failedTests([
          "github.com/usememos/memos/scripts.TestEntrypointDoesNotLoopWhenTargetUIDIsRoot"
        ]))
    #expect(baselines[Memos3Warmup.webTest] == .failed)
    #expect(baselines[Memos3Warmup.memosBuild] == .passed)

    let view = RunViewBuilder.build(
      RunViewInput(
        buildRun: "20261004T124141Z-c3747b7a", events: warmup.events,
        launchedAt: warmup.launched, warmupBaselines: baselines))
    let memos = try #require(view.spans.first { $0.id.hasSuffix(Memos3Warmup.memosTest) })
    #expect(memos.failureReason == "Base commit's tests already fail; 1 recorded as baseline.")
    #expect(memos.baseline)
    let web = try #require(view.spans.first { $0.id.hasSuffix(Memos3Warmup.webTest) })
    #expect(
      web.failureReason
        == "Base commit's tests fail, no test names read; whole step recorded as baseline.")
    let build = try #require(view.spans.first { $0.id.hasSuffix(Memos3Warmup.memosBuild) })
    #expect(build.failureReason == nil)
    #expect(!build.baseline)
  }

  @Test(
    "a warm-up whose times file another tree's record also fits, or none fits, matches no baseline — catches a baseline count read from the wrong base tree"
  )
  func ambiguousWarmup() throws {
    let warmup = try Memos3Warmup()
    let other = String(repeating: "b", count: 40)
    let twin = WarmupTimesFile(tree: other, areas: warmup.times.areas)
    let one = RunViewWarmupBaselines.match(
      events: warmup.events, times: [warmup.times],
      baselines: [Memos3Warmup.tree: warmup.baseline, other: BaselineFile(tree: other)])
    #expect(one[Memos3Warmup.webTest] == .failed)
    let both = RunViewWarmupBaselines.match(
      events: warmup.events, times: [warmup.times, twin],
      baselines: [Memos3Warmup.tree: warmup.baseline, other: BaselineFile(tree: other)])
    #expect(both.isEmpty)
    let none = RunViewWarmupBaselines.match(
      events: warmup.events, times: [], baselines: [Memos3Warmup.tree: warmup.baseline])
    #expect(none.isEmpty)
  }

  @Test(
    "a RED gate names its first gating rule and the failing test count, and a merge on it says the merged branch — catches a gate reason missing its rule or count"
  )
  func gateReason() throws {
    let failure = RunView.GateFailure(
      stage: .merge, tiers: [.t2],
      findings: [
        RunView.FailureFinding(
          rule: "area.test-failed", severity: .major, file: nil, line: nil,
          message: "46 tests failed", truncated: false)
      ], command: "swiftgate events list --run r")
    let gate = RunView.Gate(
      runID: "r", verdict: .red, milliseconds: 1,
      tests: try TestCounts(passed: 3, failed: 46, skipped: 0),
      failure: failure)
    #expect(
      RunViewFailureReasons.gate(gate) == "area.test-failed: 46 tests fail on the merged branch.")
    var task = gate
    task.failure?.stage = .task
    task.tests = try TestCounts(passed: 3, failed: 1, skipped: 0)
    #expect(
      RunViewFailureReasons.gate(task) == "area.test-failed: 1 test fails on the task branch.")

    var lint = gate
    lint.failure?.findings = [
      RunView.FailureFinding(
        rule: "neutral.lint", severity: .major, file: "store/test/memo_share_test.go", line: 212,
        message: "unused variable `limit`", truncated: false)
    ]
    #expect(RunViewFailureReasons.gate(lint) == "neutral.lint: unused variable `limit`")

    let green = RunView.Gate(runID: "g", verdict: .green, milliseconds: 1)
    #expect(RunViewFailureReasons.gate(green) == nil)
  }

  @Test(
    "a stopped task says the rejection, its RED gate, the missing return or the halt behind it — catches a blocked task with no reason"
  )
  func taskReasons() throws {
    let at = Date(timeIntervalSince1970: 0)
    func task(_ block: RunView.TaskBlock?, status: TaskStatus = .blocked) -> RunView.Task {
      RunView.Task(id: "web", status: status, gate: .slice, blocked: block)
    }
    let rejection = RunView.ReturnRejection(
      at: at, verdict: .red, fix: false, rules: [.surfaceCommitOffBranch],
      findings: [
        BuildReturnCheckedEvent.Finding(
          rule: .surfaceCommitOffBranch,
          message: "surface commit \"7c3becaa\" isn't on branch spec/share-view-limit-web",
          truncated: false)
      ], moreFindings: 0, message: "1 claim(s) the evidence doesn't support")
    #expect(
      RunViewFailureReasons.task(
        task(RunView.TaskBlock(at: at, cause: .returnRejected, rejection: rejection)), gates: [:])
        == "Return rejected: surface commit \"7c3becaa\" isn't on branch spec/share-view-limit-web")
    let red = RunView.Gate(
      runID: "r", verdict: .red, milliseconds: 1,
      failure: RunView.GateFailure(
        stage: .worker,
        findings: [
          RunView.FailureFinding(
            rule: "neutral.lint", severity: .major, file: nil, line: nil, message: "lint failed",
            truncated: false)
        ], command: "c"))
    #expect(
      RunViewFailureReasons.task(
        task(RunView.TaskBlock(at: at, cause: .gateRed, gateRun: "r")), gates: ["r": red])
        == "neutral.lint: lint failed")
    #expect(
      RunViewFailureReasons.task(
        task(RunView.TaskBlock(at: at, cause: .returnNotStored)), gates: [:])
        == "No return came back from the worker.")
    #expect(
      RunViewFailureReasons.task(
        task(RunView.TaskBlock(at: at, cause: .halt, halt: .amend), status: .needsReplan),
        gates: [:]) == "Halted: design conflict; the design went back for an amend.")
    #expect(
      RunViewFailureReasons.task(task(RunView.TaskBlock(at: at)), gates: [:])
        == RunViewFailureReasons.noReason)
    #expect(
      RunViewFailureReasons.task(task(nil, status: .abandoned), gates: [:])
        == "Task abandoned before it merged.")
    #expect(RunViewFailureReasons.task(task(nil, status: .done), gates: [:]) == nil)
  }

  @Test("each halt reason reads as plain words — catches a halt shown as its raw enum value")
  func haltReasons() {
    #expect(RunViewFailureReasons.halt(.gateRed) == "Halted: a gate stayed RED.")
    #expect(RunViewFailureReasons.halt(.mergeConflict) == "Halted: merge conflict.")
    #expect(RunViewFailureReasons.halt(.budget) == "Halted: the time budget ran out.")
    for reason in BuildHaltReason.allCases {
      let text = RunViewFailureReasons.halt(reason)
      #expect(text.hasPrefix("Halted: ") && text != "Halted: \(reason.rawValue).")
      #expect(words(text) <= RunView.maxReasonWords)
    }
  }

  @Test(
    "a reason is cut to 15 words and 120 bytes and keeps no machine path — catches a long or path-bearing reason reaching a published page"
  )
  func capAndScrub() {
    let long = (1...20).map { "word\($0)" }.joined(separator: " ")
    let cut = RunViewFailureReasons.capped(long)
    #expect(words(cut) == RunView.maxReasonWords)
    #expect(cut.hasSuffix("word15…"))
    let wide = String(repeating: "x", count: 200)
    let narrow = RunViewFailureReasons.capped(wide)
    #expect(narrow.utf8.count <= RunView.maxReasonBytes)
    #expect(narrow.hasSuffix("…"))
    #expect(
      RunViewFailureReasons.capped(
        "neutral.lint: /Users/someone/app/store/a.go:3 and\n/tmp/x/y failed",
        roots: ["/Users/someone/app"])
        == "neutral.lint: store/a.go:3 and <path> failed")
    #expect(RunViewFailureReasons.capped("No reason recorded.") == "No reason recorded.")
  }

  @Test(
    "a red step of a GREEN gate whose baseline absorbed failures reads as excused at the base commit — catches an absorbed failure shown with no reason or as the run's fault"
  )
  func excusedStep() {
    let start = Date(timeIntervalSince1970: 1_000)
    let end = start.addingTimeInterval(5)
    func view(_ ruleCounts: [String: Int]) -> RunView {
      var view = RunView(
        run: RunView.Run(id: "r", startedAt: start, state: .done),
        spans: [
          RunView.Span(
            id: "step:g:3", phase: .step, gateRun: "g", start: start, end: end, outcome: .red)
        ],
        gates: [RunView.Gate(runID: "g", verdict: .green, milliseconds: 5, ruleCounts: ruleCounts)])
      RunViewFailureReasons.fill(&view, input: RunViewInput(buildRun: "r"))
      return view
    }
    let absorbed = view(["baseline.summary": 1, "prove.summary": 1]).spans[0]
    #expect(absorbed.failureReason == "Fails at the base commit too; the baseline excused it.")
    #expect(absorbed.baseline)
    let passed = view([:]).spans[0]
    #expect(passed.failureReason == "Step failed, but its gate passed.")
    #expect(!passed.baseline)
  }

  @Test(
    "a span still open in a done run says it never ended, and one in a running run says nothing — catches a live span called failed"
  )
  func neverEnded() throws {
    let started = Date(timeIntervalSince1970: 1_000)
    let open = RunView.Span(id: "a", phase: .plan, start: started)
    var done = RunView(run: RunView.Run(id: "r", startedAt: started, state: .done), spans: [open])
    RunViewFailureReasons.fill(&done, input: RunViewInput(buildRun: "r"))
    #expect(done.spans.first?.failureReason == RunViewFailureReasons.neverEnded)
    var running = RunView(
      run: RunView.Run(id: "r", startedAt: started, state: .running), spans: [open])
    RunViewFailureReasons.fill(&running, input: RunViewInput(buildRun: "r"))
    #expect(running.spans.first?.failureReason == nil)
  }
}
