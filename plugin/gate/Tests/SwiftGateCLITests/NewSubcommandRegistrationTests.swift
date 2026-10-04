import ArgumentParser
import Foundation
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

/// The design/plan/evidence commands are stubs until each behavior task lands (spec §6.1); this
/// suite is what stops a stub from silently becoming a no-op gate pass, and what stops a skill
/// from calling a command that was never wired into `SwiftGate`'s subcommand tree.
@Suite("new subcommand registration")
struct NewSubcommandRegistrationTests {
  /// One entry per §6.1 command, plus `plan claim`/`plan release`/`plan set` (Decisions table). Each
  /// argument list is a full path to a leaf command, never a bare command group.
  /// `leafCommandName` is that leaf's own `CommandConfiguration.commandName`, so a parse that
  /// silently resolves to the wrong command (e.g. a help command, or a same-named sibling) fails
  /// the assertion instead of merely not throwing.
  static let invocations: [(name: String, arguments: [String], leafCommandName: String)] = [
    ("evidence check", ["evidence", "check", "--design", "docs/designs/example.md"], "check"),
    (
      "evidence check --at",
      ["evidence", "check", "--design", "docs/designs/example.md", "--at", "HEAD~1"], "check"
    ),
    (
      "evidence capture",
      ["evidence", "capture", "--design", "docs/designs/example.md", "--", "swift", "build"],
      "capture"
    ),
    ("evidence find", ["evidence", "find", "swift-argument-parser"], "find"),
    (
      "evidence find --pkg",
      ["evidence", "find", "swift-argument-parser", "--pkg", "swift-argument-parser@1.8.2"],
      "find"
    ),
    (
      "probe",
      [
        "probe", "--design", "docs/designs/example.md", "--package", "Packages/Example",
        "--target", "Example",
      ],
      "probe"
    ),
    ("design-scope", ["design-scope"], "design-scope"),
    ("design-lint", ["design-lint", "docs/designs/example.md"], "design-lint"),
    (
      "design-diff", ["design-diff", "docs/designs/old.md", "docs/designs/new.md"], "design-diff"
    ),
    ("design-diff --chain", ["design-diff", "--chain", "plan.json"], "design-diff"),
    ("design-render", ["design-render", "docs/designs/example.md"], "design-render"),
    ("docs-lint", ["docs-lint"], "docs-lint"),
    ("prose", ["prose", "docs/a.md", "docs/b.md"], "prose"),
    ("plan claim", ["plan", "claim", "example-plan", "--session", "session-123"], "claim"),
    ("plan release", ["plan", "release", "example-plan"], "release"),
    ("plan release --force", ["plan", "release", "example-plan", "--force"], "release"),
    (
      "plan set",
      [
        "plan", "set", "example-plan", "--session", "session-123", "--tier", "deep", "--resume",
        "resume text",
      ],
      "set"
    ),
    ("plan-schedule", ["plan-schedule", "ledger.json"], "plan-schedule"),
    ("plan-lint", ["plan-lint", "example-plan"], "plan-lint"),
    ("context-pack", ["context-pack", "--role", "worker"], "context-pack"),
    (
      "index set",
      ["index", "set", "example-plan", "designing", "resume text", "--session", "session-123"],
      "set"
    ),
    ("calibrate design", ["calibrate", "design"], "design"),
    ("judge", ["judge"], "tests"),
    ("judge --ready", ["judge", "--ready"], "tests"),
    ("judge tests --ready", ["judge", "tests", "--ready"], "tests"),
    ("judge ask", ["judge", "ask", "--input", "-"], "ask"),
    (
      "judge ask --backend",
      [
        "judge", "ask", "--input", "input.json", "--backend", "jev", "--model", "jev-1.13.0",
        "--send-to", "api.typesafe.ai", "--no-cache",
      ],
      "ask"
    ),
    (
      "judge bench",
      [
        "judge", "bench", "--dataset", "test-quality", "--backend", "claude:claude-sonnet-5-5",
        "--backend", "jev:jev-1.13.0#test-quality@2-jev", "--repeats", "3", "--concurrency", "1",
        "--send-to", "api.typesafe.ai", "--out", "bench.json",
      ],
      "bench"
    ),
    (
      "judge bench --estimate",
      [
        "judge", "bench", "--dataset", "test-quality", "--backend", "claude:claude-sonnet-5-5",
        "--estimate", "--usage-from", "smoke.json",
      ],
      "bench"
    ),
    (
      "judge bench-render", ["judge", "bench-render", "bench.json", "--out", "page.md"],
      "bench-render"
    ),
    (
      "build start",
      ["build", "start", "example-plan", "--preset", "interview", "--session", "session-123"],
      "start"
    ),
    ("build next", ["build", "next", "example-plan", "--session", "session-123"], "next"),
    ("build merge", ["build", "merge", "example-plan", "example-task"], "merge"),
    (
      "build merge --undo",
      ["build", "merge", "--undo", "example-plan", "example-task", "--session", "session-123"],
      "merge"
    ),
    (
      "build merge --fix",
      ["build", "merge", "--fix", "example-plan", "example-task", "--session", "session-123"],
      "merge"
    ),
    (
      "build check-return",
      [
        "build", "check-return", "return.json", "--plan", "example-plan", "--session",
        "session-123",
      ],
      "check-return"
    ),
    ("build finish", ["build", "finish", "example-plan", "--session", "session-123"], "finish"),
    ("build proof-bases", ["build", "proof-bases", "example-plan"], "proof-bases"),
    (
      "build record-gate",
      [
        "build", "record-gate", "example-plan", "--kind", "final", "--run-id", "r1", "--session",
        "session-123",
      ],
      "record-gate"
    ),
    (
      "ledger set",
      ["ledger", "set", "example-plan", "example-task", "done", "--session", "session-123"],
      "set"
    ),
    (
      "worktree create",
      ["worktree", "create", "example-plan", "example-task", "--session", "session-123"], "create"
    ),
    ("worktree warm-check", ["worktree", "warm-check"], "warm-check"),
    (
      "worktree remove",
      ["worktree", "remove", "example-plan", "example-task", "--session", "session-123"], "remove"
    ),
    ("module-graph", ["module-graph"], "module-graph"),
    (
      "evidence cache record",
      ["evidence", "cache", "record", "--design", "docs/designs/example.md"], "record"
    ),
    ("surface-check", ["surface-check", "HEAD"], "surface-check"),
    ("surface-check --json", ["surface-check", "HEAD", "--json"], "surface-check"),
    (
      "sprint start",
      ["sprint", "start", "notes-search", "--spec-page", "spec.md", "--slices", "3"], "start"
    ),
    ("sprint surface", ["sprint", "surface", "HEAD"], "surface"),
    ("sprint slice", ["sprint", "slice", "1", "--gate", "r1"], "slice"),
    ("sprint finish", ["sprint", "finish", "--gate", "r1"], "finish"),
    ("sprint status", ["sprint", "status"], "status"),
    ("sprint status --json", ["sprint", "status", "--json"], "status"),
    ("spec-page check", ["spec-page", "check", "page.md", "--spec", "spec.md"], "check"),
    (
      "spec-page check --json",
      ["spec-page", "check", "page.md", "--spec", "spec.md", "--json"], "check"
    ),
    (
      "design-telemetry",
      [
        "design-telemetry", "--run", ".harness/runs/design-example", "--run-id",
        "design-20260928T010000Z", "--phase", "research", "--workflow-result", "result.json",
        "--started-at", "2026-09-28T01:00:00Z", "--session", "session-123",
      ],
      "design-telemetry"
    ),
    ("discover", ["discover"], "discover"),
    (
      "discover --apply",
      [
        "discover", "--apply", "--set", "web.lint=npx eslint {files}", "--drop", "api.lint",
        "--reason", "no linter configured", "--json",
      ],
      "discover"
    ),
    ("claude", ["claude", "--resume", "-p", "hello"], "claude"),
    ("run", ["run", "spec.md"], "start"),
    ("run start", ["run", "start", "spec.md", "--json"], "start"),
    ("run report", ["run", "report", "example-plan", "--json"], "report"),
    ("warmup", ["warmup", "--areas", "api,web"], "warmup"),
    (
      "xcode add-file",
      ["xcode", "add-file", "App/Sources/New.swift", "--target", "App"], "add-file"
    ),
    (
      "allow",
      ["allow", "neutral.unsafe-shortcut", "api/handlers.py:12", "--reason", "parser checked"],
      "allow"
    ),
    ("plan import", ["plan", "import", "example-plan"], "import"),
    ("report --html", ["report", "--html", "20261003T120000Z-1a2b3c4d"], "report"),
    (
      "report --json --out",
      ["report", "--json", "20261003T120000Z-1a2b3c4d", "--out", "run.json"], "report"
    ),
    ("view", ["view"], "view"),
    (
      "view --build-run --port",
      ["view", "--build-run", "20261003T120000Z-1a2b3c4d", "--port", "8123"], "view"
    ),
    (
      "events span start",
      [
        "events", "span", "start", "--phase", "worker", "--build-run",
        "20261003T120000Z-1a2b3c4d", "--task", "example-task", "--role", "build-worker",
        "--parent", "0123456789abcdef",
      ],
      "start"
    ),
    ("events span end", ["events", "span", "end", "0123456789abcdef", "--outcome", "ok"], "end"),
  ]

  /// Invocations that do real work now. Some act on this checkout's real, shared plan state
  /// under the git common dir; `design-scope` instead exits 2 for a real reason (no
  /// `--frame-answers` given) that the generic "not implemented" check can't tell apart from a
  /// stub. Either way their behaviour is covered by their own suites (`PlanClaimCommandTests`,
  /// `IndexSetCommandTests`, `PlanStateAuthorityTests`, `LedgerSetCommandTests`, `DesignDiffCommandTests`, `DesignScopeCommandTests`, `BuildCheckReturnTests`, `BuildMergeTests`). Listed by
  /// exact invocation name so a still-stubbed sibling never drops out of the stub check by
  /// sharing a prefix.
  static let implemented: Set<String> = [
    "plan claim", "plan release", "plan release --force", "plan set", "index set", "design-diff",
    "run report",
    "design-diff --chain", "design-scope", "evidence capture",
    "plan-schedule",
    "prose",
    "context-pack",
    "design-lint",
    "docs-lint",
    "evidence check", "evidence check --at",
    "evidence find", "evidence find --pkg",
    "probe",
    "plan-lint",
    "design-render",
    "calibrate design",
    "judge", "judge --ready", "judge tests --ready", "judge ask", "judge ask --backend",
    "judge bench", "judge bench --estimate", "judge bench-render",
    "build start", "build next", "build finish", "build check-return", "build proof-bases",
    "build record-gate",
    "build merge",
    "build merge --undo", "build merge --fix",
    "ledger set",
    "worktree create", "worktree warm-check", "worktree remove",
    "module-graph",
    "evidence cache record",
    "surface-check", "surface-check --json",
    "sprint start", "sprint surface", "sprint slice", "sprint finish", "sprint status",
    "sprint status --json",
    "spec-page check", "spec-page check --json",
    "design-telemetry",
    "discover", "discover --apply",
    "allow",
    "claude",
    "plan import",
  ]

  @Test(
    "check --tier slice, merge and final in a brownfield clone exit BLOCKED with swiftgate.not-run naming the tier — catches a stub tier that passes",
    arguments: [CheckTier.slice, .merge, .final])
  func brownfieldTiersBlock(_ tier: CheckTier) async throws {
    let clone = FileManager.default.temporaryDirectory.appending(
      path: "brownfield-check-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: clone) }
    let state = clone.appending(path: ".git/swift-harness", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data("schema = 1\n".utf8).write(to: state.appending(path: "config.toml"))

    let parts = try await BrownfieldCheck.run(
      root: clone, tier: tier, base: "main",
      context: GateRun.Context(runID: "r", directory: clone.appending(path: "run")))
    let report = try RunReport(
      runID: "r", durationMilliseconds: 0, tiers: parts.tiers, findings: parts.findings)

    #expect(report.verdict == .blocked)
    #expect(report.verdict.exitCode == 2)
    #expect(
      parts.findings.contains {
        $0.ruleID == "swiftgate.not-run" && $0.message.contains("--tier \(tier.rawValue)")
      })
  }

  @Test(
    "every §6.1 command parses its documented arguments and resolves to the right leaf command — catches a skill calling an unregistered command",
    arguments: invocations)
  func parsesArguments(
    _ invocation: (name: String, arguments: [String], leafCommandName: String)
  ) async throws {
    let parsed = try await SwiftGate.asyncParseAsRoot(invocation.arguments)
    #expect(
      type(of: parsed).configuration.commandName == invocation.leafCommandName,
      "\(invocation.name) resolved to \(type(of: parsed).configuration.commandName ?? "<nil>")")
  }

  static let stubInvocations = invocations.filter { !implemented.contains($0.name) }

  @Test(
    "every stub subcommand exits 2, never 0 — catches a stub passing a gate before it does real work",
    arguments: stubInvocations)
  func stubsExitBlocked(
    _ invocation: (name: String, arguments: [String], leafCommandName: String)
  ) async throws {
    var parsed = try await SwiftGate.asyncParseAsRoot(invocation.arguments)
    do {
      if var asyncCommand = parsed as? AsyncParsableCommand {
        try await asyncCommand.run()
      } else {
        try parsed.run()
      }
      Issue.record("\(invocation.name) exited 0 instead of reporting not-implemented")
    } catch let exitCode as ExitCode {
      #expect(exitCode.rawValue == 2, "\(invocation.name) exited \(exitCode.rawValue), not 2")
    }
  }

  @Test(
    "plan-schedule with no argument fails to parse, naming the missing ledger — catches a cwd default silently reading the wrong file"
  )
  func planScheduleRequiresLedgerArgument() async throws {
    await #expect(throws: (any Error).self) {
      _ = try await SwiftGate.asyncParseAsRoot(["plan-schedule"])
    }
    do {
      _ = try await SwiftGate.asyncParseAsRoot(["plan-schedule"])
      Issue.record("plan-schedule with no argument parsed instead of failing")
    } catch {
      #expect(!(error is ExitCode), "parse failure should not be a bare ExitCode")
      #expect(String(describing: error).contains("ledger"), "\(error)")
    }
  }
}
