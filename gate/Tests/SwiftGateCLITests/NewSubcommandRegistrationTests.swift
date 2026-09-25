import ArgumentParser
import Testing

@testable import SwiftGateCLI

/// The design/plan/evidence commands are stubs until each behavior task lands (spec §6.1); this
/// suite is what stops a stub from silently becoming a no-op gate pass, and what stops a skill
/// from calling a command that was never wired into `SwiftGate`'s subcommand tree.
@Suite("new subcommand registration")
struct NewSubcommandRegistrationTests {
  /// One entry per §6.1 command, plus `plan claim`/`plan release` (Decisions table). Each
  /// argument list is a full path to a leaf command, never a bare command group.
  /// `leafCommandName` is that leaf's own `CommandConfiguration.commandName`, so a parse that
  /// silently resolves to the wrong command (e.g. a help command, or a same-named sibling) fails
  /// the assertion instead of merely not throwing.
  static let invocations: [(name: String, arguments: [String], leafCommandName: String)] = [
    ("evidence check", ["evidence", "check"], "check"),
    ("evidence check --at", ["evidence", "check", "--at", "HEAD~1"], "check"),
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
    ("probe", ["probe", "--design", "docs/designs/example.md"], "probe"),
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
    ("plan-schedule", ["plan-schedule", "ledger.json"], "plan-schedule"),
    ("plan-lint", ["plan-lint"], "plan-lint"),
    ("context-pack", ["context-pack", "--role", "worker"], "context-pack"),
    ("index set", ["index", "set", "example-plan", "designing", "resume text"], "set"),
    ("calibrate design", ["calibrate", "design"], "design"),
  ]

  /// Invocations that do real work now. Some act on this checkout's real, shared plan state
  /// under the git common dir; `design-scope` instead exits 2 for a real reason (no
  /// `--frame-answers` given) that the generic "not implemented" check can't tell apart from a
  /// stub. Either way their behaviour is covered by their own suites (`PlanClaimCommandTests`,
  /// `IndexSetCommandTests`, `DesignDiffCommandTests`, `DesignScopeCommandTests`). Listed by
  /// exact invocation name so a still-stubbed sibling never drops out of the stub check by
  /// sharing a prefix.
  static let implemented: Set<String> = [
    "plan claim", "plan release", "plan release --force", "index set", "design-diff",
    "design-diff --chain", "design-scope", "evidence capture",
    "plan-schedule",
    "prose",
    "context-pack",
    "design-lint",
    "docs-lint",
  ]

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
