import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway repository on `main` with 1 commit, a spec page and its own `.git` common dir, so
/// every sprint command here writes plan state only there. Gate runs are recorded by the real
/// ``GateRun`` driver against the repository's real HEAD.
private struct SprintRepo {
  static let slug = "feature"
  static let branch = "sprint/feature"
  static let clean = "func feature() -> Int {\n  0\n}\n"
  static let behaviour = "func feature() -> Int {\n  40 + 2\n}\n"

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ])

  init() async throws {
    root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-sprint-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: root.appending(path: "Sources/App"), withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try Data(".harness/\n".utf8).write(to: root.appending(path: ".gitignore"))
    try Data("# Feature\n\n1. It counts.\n".utf8).write(to: root.appending(path: "spec.md"))
    try await commit("Sources/App/App.swift", "func existing() -> Int {\n  1\n}\n", "base")
  }

  func remove() { TestTemporaryDirectory.remove(root) }

  var liveGit: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  func context(store: SprintStore? = nil) async throws -> SprintContext {
    let layout = try PlanStateLayout(commonDirectory: try await liveGit.commonDirectory())
    return SprintContext(
      root: root, git: liveGit,
      branches: LiveSprintBranches(runner: runner, repositoryRoot: root.path),
      store: store ?? SprintStore(layout: layout),
      surfaceReader: LiveSurfaceCommitReader(runner: runner, repositoryRoot: root.path))
  }

  func layout() async throws -> PlanStateLayout {
    try PlanStateLayout(commonDirectory: try await liveGit.commonDirectory())
  }

  @discardableResult
  func git(_ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @discardableResult
  func commit(_ path: String, _ text: String, _ message: String) async throws -> String {
    try Data(text.utf8).write(to: root.appending(path: path))
    try await git("add", "-A")
    try await git("commit", "-q", "-m", message)
    return try await git("rev-parse", "HEAD")
  }

  func sha(_ ref: String) async throws -> String { try await git("rev-parse", ref) }

  /// The ref a recorded gate run names as its `--base`.
  enum GateBase {
    /// The recorded sprint's surface, or no base before one is recorded: what the skill passes.
    case recordedSurface
    case ref(String)
    /// A run with no base, as history written before runs recorded one.
    case none
  }

  /// Records a gate run at the current HEAD through the real run driver and returns its id.
  func gate(
    _ command: String, _ verdict: Verdict = .green, steps: [String]? = nil,
    proofBases: [String]? = nil, base: GateBase = .recordedSurface
  ) async throws -> String {
    let parts = GateRunParts(
      tiers: [try TierResult(tier: .t1, verdict: verdict, durationMilliseconds: 1, testCounts: nil)]
    )
    let baseRef: String? =
      switch base {
      case .recordedSurface: try await context().store.read()?.surfaceCommit
      case .ref(let ref): ref
      case .none: nil
      }
    var captured: String?
    do {
      try await GateRun.execute(
        root: root, format: .json, command: command, steps: steps, proofBases: proofBases,
        base: baseRef, git: liveGit
      ) { context in
        captured = context.runID
        return parts
      }
    } catch is ExitCode {
      // A RED or BLOCKED run exits non-zero after recording itself.
    }
    return try #require(captured)
  }

  /// `main` has a green push gate and the sprint started with `slices` slices, on its branch.
  func started(slices: Int = 1) async throws -> SprintContext {
    _ = try await gate("check push")
    let context = try await context()
    let outcome = await SprintCommandRun.start(
      slug: Self.slug, specPage: "spec.md", slices: slices, context: context)
    try #require(outcome.refusal == nil, "\(outcome.message)")
    try await git("switch", "-q", Self.branch)
    return context
  }

  /// Started, with a clean surface recorded; returns the surface sha.
  func surfaced(slices: Int = 1) async throws -> (SprintContext, String) {
    let context = try await started(slices: slices)
    let surface = try await commit("Sources/App/Feature.swift", Self.clean, "surface")
    let outcome = await SprintCommandRun.surface(commit: surface, context: context)
    try #require(outcome.refusal == nil, "\(outcome.message)")
    return (context, surface)
  }

  /// Surfaced, with its only slice committed and passed at a green push gate.
  func sliced() async throws -> (SprintContext, String) {
    let (context, surface) = try await surfaced()
    try await commit("Sources/App/Feature.swift", Self.behaviour, "slice 1")
    let outcome = await SprintCommandRun.slice(
      1, gate: try await gate("check push"), context: context)
    try #require(outcome.refusal == nil, "\(outcome.message)")
    return (context, surface)
  }
  /// Writes each file, creating its directories, and commits them all.
  @discardableResult
  func commit(files: [String: String], _ message: String) async throws -> String {
    for (path, text) in files {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
    try await git("add", "-A")
    try await git("commit", "-q", "-m", message)
    return try await git("rev-parse", "HEAD")
  }

  /// Started, with a surface of `files` recorded; returns the surface sha.
  func surfaced(files: [String: String], slices: Int) async throws -> (SprintContext, String) {
    let context = try await started(slices: slices)
    let surface = try await commit(files: files, "surface")
    let outcome = await SprintCommandRun.surface(commit: surface, context: context)
    try #require(outcome.refusal == nil, "\(outcome.message)")
    return (context, surface)
  }

  /// Commits `files` as slice `number` and runs `sprint slice` on a green push gate from the
  /// surface.
  func slice(_ number: Int, files: [String: String], context: SprintContext) async throws
    -> SprintOutcome
  {
    try await commit(files: files, "slice \(number)")
    return await SprintCommandRun.slice(
      number, gate: try await gate("check push"), context: context)
  }

  /// The rehearsal's `Packages/<package>/Package.swift`, as its surface or slice 4 committed it.
  static func rehearsalManifest(_ side: String, _ package: String) throws -> [String: String] {
    let path = "Packages/\(package)/Package.swift"
    return [path: try Fixture.text("sprint-manifests/\(side)/\(path).txt")]
  }

  static func rehearsalManifests(_ side: String, _ packages: String...) throws
    -> [String: String]
  {
    try packages.reduce(into: [:]) { files, package in
      files.merge(try rehearsalManifest(side, package)) { $1 }
    }
  }
}

@Suite("sprint commands")
struct SprintCommandTests {
  @Test(
    "a sprint that starts, surfaces, passes its slices and finishes fast-forwards main to the branch with no merge commit — catches finish merging, rebasing or leaving main behind"
  )
  func happyPathFastForwardsMain() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let base = try await repo.sha("main")
    let (context, surface) = try await repo.surfaced(slices: 2)
    try await repo.commit("Sources/App/Feature.swift", SprintRepo.behaviour, "slice 1")
    let first = await SprintCommandRun.slice(
      1, gate: try await repo.gate("check push"), context: context)
    try await repo.commit("Sources/App/More.swift", "func more() -> Int {\n  3\n}\n", "slice 2")
    let second = await SprintCommandRun.slice(
      2, gate: try await repo.gate("check ready"), context: context)
    let head = try await repo.sha("HEAD")
    let ready = try await repo.gate("check ready", proofBases: [surface])

    let finished = await SprintCommandRun.finish(gate: ready, context: context)

    #expect(first.refusal == nil, "\(first.message)")
    #expect(second.refusal == nil, "\(second.message)")
    #expect(finished.refusal == nil, "\(finished.message)")
    #expect(finished.verdict == .green)
    #expect(try await repo.sha("main") == head)
    #expect(try await repo.git("rev-list", "--count", "\(base)..main") == "3")
    #expect(try await repo.git("rev-list", "--merges", "--count", "main") == "0")
    let run = try #require(try context.store.read())
    #expect(run.step == .finished)
    #expect(run.finalGateRun == ready)
    #expect(run.next == .start)
  }

  @Test(
    "start refuses when main has no green push gate at its HEAD, creating no branch — catches a sprint cut from an unchecked or red main"
  )
  func startNeedsGreenMain() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let context = try await repo.context()
    let unchecked = await SprintCommandRun.start(
      slug: SprintRepo.slug, specPage: "spec.md", slices: 1, context: context)
    _ = try await repo.gate("check push", .red)
    let red = await SprintCommandRun.start(
      slug: SprintRepo.slug, specPage: "spec.md", slices: 1, context: context)

    #expect(unchecked.refusal == .mainNotGreen, "\(unchecked.message)")
    #expect(red.refusal == .mainNotGreen, "\(red.message)")
    #expect(red.verdict == .red)
    #expect(red.verdict.exitCode == 1)
    #expect(try context.store.read() == nil)
    let branches = try await repo.git("branch", "--list", SprintRepo.branch)
    #expect(branches.isEmpty)
  }

  @Test(
    "start creates sprint/<slug> at main and records the base, and refuses a missing spec page or an existing branch — catches a sprint recorded against the wrong base or over another branch"
  )
  func startCreatesBranch() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    _ = try await repo.gate("check push")
    let context = try await repo.context()
    let missing = await SprintCommandRun.start(
      slug: SprintRepo.slug, specPage: "absent.md", slices: 1, context: context)
    try await repo.git("branch", "sprint/taken")
    let taken = await SprintCommandRun.start(
      slug: "taken", specPage: "spec.md", slices: 1, context: context)
    let badSlug = await SprintCommandRun.start(
      slug: "Bad Slug", specPage: "spec.md", slices: 1, context: context)
    let started = await SprintCommandRun.start(
      slug: SprintRepo.slug, specPage: "spec.md", slices: 2, context: context)

    #expect(missing.refusal == .specPageMissing, "\(missing.message)")
    #expect(taken.refusal == .branchExists, "\(taken.message)")
    #expect(badSlug.refusal == .invalidSlug, "\(badSlug.message)")
    #expect(started.refusal == nil, "\(started.message)")
    let main = try await repo.sha("main")
    #expect(try await repo.sha(SprintRepo.branch) == main)
    let run = try #require(started.run)
    #expect(run.baseCommit == main)
    #expect(run.slices.count == 2)
    #expect(try context.store.read() == run)
  }

  @Test(
    "surface refuses a commit with behaviour and records nothing — catches a surface with logic becoming the proof base"
  )
  func surfaceWithBehaviourRefuses() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let context = try await repo.started()
    let surface = try await repo.commit(
      "Sources/App/Feature.swift", SprintRepo.behaviour, "surface")

    let outcome = await SprintCommandRun.surface(commit: surface, context: context)

    #expect(outcome.refusal == .surfaceBehaviour, "\(outcome.message)")
    #expect(outcome.message.contains("feature"), "\(outcome.message)")
    #expect(outcome.verdict.exitCode == 1)
    #expect(try context.store.read()?.step == .started)
  }

  @Test(
    "surface refuses a commit that isn't the first on the sprint branch — catches behaviour committed before the surface escaping surface-check"
  )
  func surfaceMustBeFirstCommit() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let context = try await repo.started()
    try await repo.commit("Sources/App/Early.swift", "func early() -> Int {\n  7\n}\n", "early")
    let surface = try await repo.commit("Sources/App/Feature.swift", SprintRepo.clean, "surface")

    let outcome = await SprintCommandRun.surface(commit: surface, context: context)

    #expect(outcome.refusal == .surfaceOffBranch, "\(outcome.message)")
    #expect(try context.store.read()?.step == .started)
  }

  @Test(
    "slice refuses a gate run recorded at an earlier commit than the branch HEAD — catches a stale green gate vouching for new code"
  )
  func sliceRefusesStaleGate() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, _) = try await repo.surfaced()
    let gate = try await repo.gate("check push")
    try await repo.commit("Sources/App/Feature.swift", SprintRepo.behaviour, "slice 1")

    let outcome = await SprintCommandRun.slice(1, gate: gate, context: context)

    #expect(outcome.refusal == .gateStale, "\(outcome.message)")
    #expect(try context.store.read()?.step == .surfaced)
  }

  @Test(
    "slice refuses a RED gate run and a BLOCKED one at HEAD — catches a failing or unrun gate passing a slice"
  )
  func sliceRefusesRedAndBlockedGates() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, _) = try await repo.surfaced()
    try await repo.commit("Sources/App/Feature.swift", SprintRepo.behaviour, "slice 1")

    let red = await SprintCommandRun.slice(
      1, gate: try await repo.gate("check push", .red), context: context)
    let blocked = await SprintCommandRun.slice(
      1, gate: try await repo.gate("check push", .blocked), context: context)

    #expect(red.refusal == .gateRed, "\(red.message)")
    #expect(blocked.refusal == .gateBlocked, "\(blocked.message)")
    #expect(try context.store.read()?.step == .surfaced)
  }

  @Test(
    "slice refuses a gate run below push, and a run that isn't a check — catches the fast inner loop standing in for the slice gate"
  )
  func sliceRefusesTierBelowPush() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, _) = try await repo.surfaced()
    try await repo.commit("Sources/App/Feature.swift", SprintRepo.behaviour, "slice 1")

    let fast = await SprintCommandRun.slice(
      1, gate: try await repo.gate("check fast"), context: context)
    let lint = await SprintCommandRun.slice(
      1, gate: try await repo.gate("test"), context: context)

    #expect(fast.refusal == .gateTier, "\(fast.message)")
    #expect(lint.refusal == .gateTier, "\(lint.message)")
    #expect(try context.store.read()?.step == .surfaced)
  }

  @Test(
    "slice refuses a run id the history doesn't hold, and a slice out of the page's order — catches a caller-made id or a skipped slice being trusted"
  )
  func sliceRefusesUnknownRunAndWrongOrder() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, _) = try await repo.surfaced(slices: 2)
    try await repo.commit("Sources/App/Feature.swift", SprintRepo.behaviour, "slice 1")
    let gate = try await repo.gate("check push")

    let unknown = await SprintCommandRun.slice(
      1, gate: "20260927T000000Z-deadbeef", context: context)
    let skipped = await SprintCommandRun.slice(2, gate: gate, context: context)

    #expect(unknown.refusal == .gateUnknown, "\(unknown.message)")
    #expect(skipped.refusal == .outOfOrder, "\(skipped.message)")
    #expect(skipped.message.contains("slice 1"), "\(skipped.message)")
    #expect(try context.store.read()?.step == .surfaced)
  }

  @Test(
    "finish refuses when main moved since start, and main stays where it moved to — catches finish overwriting someone else's commit on main"
  )
  func finishRefusesMovedMain() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, surface) = try await repo.sliced()
    let ready = try await repo.gate("check ready", proofBases: [surface])
    try await repo.git("switch", "-q", "main")
    let moved = try await repo.commit("Sources/App/Other.swift", "func other() {}\n", "other")
    try await repo.git("switch", "-q", SprintRepo.branch)

    let outcome = await SprintCommandRun.finish(gate: ready, context: context)

    #expect(outcome.refusal == .mainMoved, "\(outcome.message)")
    #expect(try await repo.sha("main") == moved)
    #expect(try context.store.read()?.step == .slicing(1))
  }

  @Test(
    "finish refuses a green push run in place of the ready gate — catches a sprint finishing without reach, stress, prove and mutate"
  )
  func finishRefusesRunBelowReady() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, surface) = try await repo.sliced()
    let base = try await repo.sha("main")
    let push = try await repo.gate("check push", steps: ["prove"], proofBases: [surface])

    let outcome = await SprintCommandRun.finish(gate: push, context: context)

    #expect(outcome.refusal == .gateNotReady, "\(outcome.message)")
    #expect(try await repo.sha("main") == base)
  }

  @Test(
    "finish refuses a green ready run that never proved at the sprint's surface, with no proof base or another one — catches new tests that were never shown to fail without their code"
  )
  func finishRefusesReadyRunWithoutSurfaceProof() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, _) = try await repo.sliced()
    let base = try await repo.sha("main")
    let unproven = try await repo.gate("check ready")
    let elsewhere = try await repo.gate("check ready", proofBases: [base])

    let first = await SprintCommandRun.finish(gate: unproven, context: context)
    let second = await SprintCommandRun.finish(gate: elsewhere, context: context)

    #expect(first.refusal == .gateProofBase, "\(first.message)")
    #expect(second.refusal == .gateProofBase, "\(second.message)")
    #expect(try await repo.sha("main") == base)
    #expect(try context.store.read()?.step == .slicing(1))
  }

  @Test(
    "finish refuses a RED ready run and a stale one, leaving main at its base — catches main moving to a sprint whose final gate failed or ran elsewhere"
  )
  func finishRefusesRedAndStaleReadyRuns() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, surface) = try await repo.sliced()
    let base = try await repo.sha("main")
    let red = try await repo.gate("check ready", .red, proofBases: [surface])
    let stale = try await repo.gate("check ready", proofBases: [surface])
    try await repo.commit("Sources/App/Late.swift", "func late() {}\n", "late")

    let redOutcome = await SprintCommandRun.finish(gate: red, context: context)
    let staleOutcome = await SprintCommandRun.finish(gate: stale, context: context)

    #expect(redOutcome.refusal == .gateRed, "\(redOutcome.message)")
    #expect(staleOutcome.refusal == .gateStale, "\(staleOutcome.message)")
    #expect(try await repo.sha("main") == base)
  }

  @Test(
    "a checkout on another sprint's branch can't finish this sprint, and a second start waits for the first to finish — catches 1 sprint's commands acting on another's branch"
  )
  func secondSlugCannotActOnFirstSprint() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, surface) = try await repo.sliced()
    let base = try await repo.sha("main")
    try await repo.git("switch", "-q", "-c", "sprint/other")
    let ready = try await repo.gate("check ready", proofBases: [surface])

    let finish = await SprintCommandRun.finish(gate: ready, context: context)
    let start = await SprintCommandRun.start(
      slug: "other", specPage: "spec.md", slices: 1, context: context)

    #expect(finish.refusal == .wrongBranch, "\(finish.message)")
    #expect(start.refusal == .outOfOrder, "\(start.message)")
    #expect(try await repo.sha("main") == base)
    #expect(try context.store.read()?.slug == SprintRepo.slug)
  }

  @Test(
    "finish refuses while another worktree has main checked out, and when the branch doesn't descend from main — catches a fast-forward that desyncs a checkout or isn't one"
  )
  func finishRefusesCheckedOutMainAndNonFastForward() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, surface) = try await repo.sliced()
    let base = try await repo.sha("main")
    let ready = try await repo.gate("check ready", proofBases: [surface])
    let other = repo.root.deletingLastPathComponent()
      .appending(path: "swiftgate-sprint-main-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: other) }
    try await repo.git("worktree", "add", "-q", other.path, "main")
    let checkedOut = await SprintCommandRun.finish(gate: ready, context: context)
    try await repo.git("worktree", "remove", "--force", other.path)
    let head = try await repo.sha("HEAD")
    let unrelated = try await repo.git(
      "commit-tree", "\(head)^{tree}", "-m", "rewritten history")
    try await repo.git("reset", "-q", "--hard", unrelated)
    let rewritten = try await repo.gate("check ready", proofBases: [surface])
    let notForward = await SprintCommandRun.finish(gate: rewritten, context: context)

    #expect(checkedOut.refusal == .mainCheckedOut, "\(checkedOut.message)")
    #expect(notForward.refusal == .notFastForward, "\(notForward.message)")
    #expect(try await repo.sha("main") == base)
  }

  @Test(
    "a finish that moved main but crashed before recording it completes when run again — catches a crash leaving a sprint that can never finish"
  )
  func finishRecoversAfterMainMoved() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, surface) = try await repo.sliced()
    let base = try await repo.sha("main")
    let head = try await repo.sha("HEAD")
    let ready = try await repo.gate("check ready", proofBases: [surface])
    try await repo.git("update-ref", "refs/heads/main", head, base)

    let outcome = await SprintCommandRun.finish(gate: ready, context: context)

    #expect(outcome.refusal == nil, "\(outcome.message)")
    #expect(try context.store.read()?.step == .finished)
    #expect(try await repo.sha("main") == head)
  }

  @Test(
    "status names the next step from the recorded state after a slice crashed mid-write — catches a crash losing or corrupting the sprint"
  )
  func statusAfterCrashNamesNextStep() async throws {
    struct Crash: Error {}
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, surface) = try await repo.surfaced()
    try await repo.commit("Sources/App/Feature.swift", SprintRepo.behaviour, "slice 1")
    let gate = try await repo.gate("check push")
    let crashing = SprintStore(
      layout: try await repo.layout(), lock: nil, timeout: .seconds(5),
      beforeRename: { _ in throw Crash() })

    let crashed = await SprintCommandRun.slice(
      1, gate: gate, context: try await repo.context(store: crashing))
    let status = await SprintCommandRun.status(context: context)
    let json = SprintCommandRun.render(status, format: .json)

    #expect(crashed.refusal == .stateIO, "\(crashed.message)")
    #expect(crashed.verdict == .blocked)
    #expect(status.refusal == nil)
    #expect(status.run?.next == .slice(1))
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["command"] as? String == "sprint status")
    #expect(object["verdict"] as? String == "GREEN")
    #expect(object["next"] as? String == "slice 1")
    #expect(
      object["nextCommand"] as? String == "swiftgate sprint slice 1 --gate <push run id>")
    let sprint = try #require(object["sprint"] as? [String: Any])
    #expect(sprint["slug"] as? String == SprintRepo.slug)
    #expect(sprint["branch"] as? String == SprintRepo.branch)
    #expect(sprint["surfaceCommit"] as? String == surface)
    #expect(sprint["step"] as? String == "surfaced")
    #expect(sprint["slicesPassed"] as? Int == 0)
  }

  @Test(
    "status with no sprint recorded says to start one, and a refusal renders its rule id — catches a skill unable to tell what to run next"
  )
  func statusWithoutSprintAndRefusalText() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let context = try await repo.context()

    let status = await SprintCommandRun.status(context: context)
    let refused = await SprintCommandRun.surface(commit: "HEAD", context: context)
    let text = SprintCommandRun.render(refused, format: .human)
    let json = SprintCommandRun.render(status, format: .json)

    #expect(status.refusal == nil)
    #expect(status.run == nil)
    #expect(refused.refusal == .outOfOrder)
    #expect(text.contains("sprint.out-of-order"), "\(text)")
    #expect(text.contains("start"), "\(text)")
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["next"] as? String == "start")
    #expect(object["sprint"] == nil)
  }
  @Test(
    "slice refuses a green push run measured from main, and one whose history line names no base, and accepts it measured from the surface — catches a slice gate judging coverage against the wrong base, or an unrecorded base passing"
  )
  func sliceNeedsGateMeasuredFromSurface() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, surface) = try await repo.surfaced()
    try await repo.commit("Sources/App/Feature.swift", SprintRepo.behaviour, "slice 1")

    let fromMain = await SprintCommandRun.slice(
      1, gate: try await repo.gate("check push", base: .ref("main")), context: context)
    let unrecorded = await SprintCommandRun.slice(
      1, gate: try await repo.gate("check push", base: .none), context: context)
    let stepAfterRefusals = try context.store.read()?.step
    let fromSurface = await SprintCommandRun.slice(
      1, gate: try await repo.gate("check push", base: .ref(surface)), context: context)

    #expect(fromMain.refusal == .gateBase, "\(fromMain.message)")
    #expect(fromMain.verdict.exitCode == 1)
    #expect(
      fromMain.message.contains("check --tier push --base \(surface)"), "\(fromMain.message)")
    #expect(unrecorded.refusal == .gateBase, "\(unrecorded.message)")
    #expect(stepAfterRefusals == .surfaced)
    #expect(fromSurface.refusal == nil, "\(fromSurface.message)")
    #expect(try context.store.read()?.step == .slicing(1))
  }

  @Test(
    "a slice's push run records the surface as its base, so the diff it judges holds slice 1's lines and not a surface stub a later slice fills — catches slice 1 failing coverage on stubs it never touched"
  )
  func sliceGateDiffExcludesSurfaceStubs() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let context = try await repo.started(slices: 2)
    try Data(SprintRepo.clean.utf8).write(
      to: repo.root.appending(path: "Sources/App/Feature.swift"))
    let surface = try await repo.commit(
      "Sources/App/Later.swift", "func later() -> Int {\n  0\n}\n", "surface")
    let surfaced = await SprintCommandRun.surface(commit: surface, context: context)
    try #require(surfaced.refusal == nil, "\(surfaced.message)")
    try await repo.commit("Sources/App/Feature.swift", SprintRepo.behaviour, "slice 1")

    let id = try await repo.gate("check push")
    let record = try #require(
      try RunStore(worktreeRoot: repo.root).readHistory().records.last { $0.runID == id })
    let base = try #require(record.base, "the push run recorded no base")
    let fromBase = try await CoverageCheck.addedLines(git: repo.liveGit, base: base).get()
    let fromMain = try await CoverageCheck.addedLines(git: repo.liveGit, base: "main").get()

    #expect(base == surface)
    #expect(fromBase.map(\.path) == ["Sources/App/Feature.swift"])
    #expect(Set(fromMain.map(\.path)) == ["Sources/App/Feature.swift", "Sources/App/Later.swift"])
  }

  @Test(
    "slice refuses the rehearsal's slice that adds a Live target and product to a package the surface created, naming both, and exits 1 — catches a slice adding a target the ready gate's prove can't build"
  )
  func sliceRefusesTheRehearsalsLiveTarget() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, _) = try await repo.surfaced(
      files: try SprintRepo.rehearsalManifests(
        "surface", "AppFeature", "ProfileClient", "ProfileFeature"), slices: 1)

    let outcome = try await repo.slice(
      1,
      files: try SprintRepo.rehearsalManifests(
        "slice", "AppFeature", "ProfileClient", "ProfileFeature"), context: context)

    #expect(outcome.refusal == .targetOutsideSurface, "\(outcome.message)")
    #expect(outcome.verdict.exitCode == 1)
    #expect(
      outcome.message.contains(
        "Packages/ProfileClient/Package.swift adds target ProfileClientLive and product "
          + "ProfileClientLive"), "\(outcome.message)")
    #expect(!outcome.message.contains("ProfileFeature/"), "\(outcome.message)")
    #expect(!outcome.message.contains("AppFeature/"), "\(outcome.message)")
    #expect(outcome.message.contains("Amend the surface with a stub"), "\(outcome.message)")
    #expect(try context.store.read()?.step == .surfaced)
  }

  @Test(
    "slice refuses a slice that adds a whole package the surface lacks, naming its targets and products — catches a new manifest skipped because it has no surface version"
  )
  func sliceRefusesANewPackage() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, _) = try await repo.surfaced(
      files: try SprintRepo.rehearsalManifest("surface", "ProfileClient"), slices: 1)

    let outcome = try await repo.slice(
      1, files: try SprintRepo.rehearsalManifest("surface", "ProfileFeature"), context: context)

    #expect(outcome.refusal == .targetOutsideSurface, "\(outcome.message)")
    #expect(
      outcome.message.contains(
        "Packages/ProfileFeature/Package.swift adds target ProfileCore and product ProfileCore"),
      "\(outcome.message)")
  }

  @Test(
    "a slice that fills declared targets and adds only test targets and dependencies passes, and a later slice adding a target is refused — catches a test target or a filled stub refused"
  )
  func sliceFillingDeclaredTargetsPasses() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, _) = try await repo.surfaced(
      files: try SprintRepo.rehearsalManifests(
        "surface", "AppFeature", "ProfileClient", "ProfileFeature"), slices: 2)

    var filling = try SprintRepo.rehearsalManifests("slice", "AppFeature", "ProfileFeature")
    filling["Packages/ProfileFeature/Sources/ProfileCore/Profile.swift"] =
      "func profile() -> Int {\n  1\n}\n"
    let first = try await repo.slice(1, files: filling, context: context)
    let second = try await repo.slice(
      2, files: try SprintRepo.rehearsalManifest("slice", "ProfileClient"), context: context)

    #expect(first.refusal == nil, "\(first.message)")
    #expect(second.refusal == .targetOutsideSurface, "\(second.message)")
    #expect(try context.store.read()?.step == .slicing(1))
  }

  @Test(
    "a slice that only reorders a manifest's targets and products passes, and a later slice adding one is refused — catches a reordered list read as new declarations"
  )
  func sliceReorderingAManifestPasses() async throws {
    func manifest(_ products: String, _ targets: String) -> [String: String] {
      [
        "Packages/Kit/Package.swift": """
        // swift-tools-version: 6.2
        import PackageDescription

        let package = Package(
          name: "Kit",
          products: [\(products)],
          targets: [\(targets)]
        )

        """
      ]
    }
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, _) = try await repo.surfaced(
      files: manifest(
        #".library(name: "A", targets: ["A"]), .library(name: "B", targets: ["B"])"#,
        #".target(name: "A"), .target(name: "B")"#), slices: 2)

    let reordered = try await repo.slice(
      1,
      files: manifest(
        #".library(name: "B", targets: ["B"]), .library(name: "A", targets: ["A"])"#,
        #".testTarget(name: "BTests"), .target(name: "B"), .target(name: "A")"#),
      context: context)
    let added = try await repo.slice(
      2,
      files: manifest(
        #".library(name: "B", targets: ["B"]), .library(name: "A", targets: ["A"])"#,
        #".target(name: "B"), .target(name: "A"), .target(name: "C")"#), context: context)

    #expect(reordered.refusal == nil, "\(reordered.message)")
    #expect(added.refusal == .targetOutsideSurface, "\(added.message)")
    #expect(
      added.message.contains(": Packages/Kit/Package.swift adds target C. "), "\(added.message)")
  }

  @Test(
    "slice refuses a manifest it can't read at HEAD, naming the file and why — catches an unparsable manifest passed as adding nothing"
  )
  func sliceRefusesAnUnreadableManifest() async throws {
    let repo = try await SprintRepo()
    defer { repo.remove() }
    let (context, _) = try await repo.surfaced(
      files: try SprintRepo.rehearsalManifest("surface", "ProfileClient"), slices: 1)
    let path = "Packages/ProfileClient/Package.swift"
    let broken = try #require(try SprintRepo.rehearsalManifest("surface", "ProfileClient")[path])
      .replacingOccurrences(of: "swiftLanguageModes: [.v6]\n)", with: "swiftLanguageModes: [.v6]\n")

    let outcome = try await repo.slice(1, files: [path: broken], context: context)

    #expect(outcome.refusal == .targetOutsideSurface, "\(outcome.message)")
    #expect(outcome.message.contains("\(path) can't be read at"), "\(outcome.message)")
  }
}
