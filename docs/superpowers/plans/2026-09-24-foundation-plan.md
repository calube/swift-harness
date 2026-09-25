# Foundation — implementation plan

<!-- RESUME
Status: M0 complete 2026-09-24.
Spec: docs/superpowers/specs/2026-09-24-swift-harness-foundation-design.md (approved).
Next action: Wave B (T1.1, T2.1, T5.0, T6.1). TCA×Swift compatibility resolved (spec §6.2 toolchain notes).
Open items:
  - T4.4: confirm current Claude Code hook input schema (Stop re-entry field, subagent identity) before coding.
  - T5.0: sample app needs an .xcodeproj — hand-written synchronized-folder pbxproj, fallback = user creates via Xcode template (~2 min).
  - T4.1 / T5.1: confirm `swift test` structured-output flags and `xcresulttool` subcommands on the installed toolchain before coding the parsers.
Progress: T0.1 25fa917 · T0.2 b997429 · T0.3 (this commit; cached exec 52ms)
-->

## Decisions made while planning

| # | Decision | Evidence | Reversal |
|---|---|---|---|
| D1 | Custom rules (determinism bans, suppression reasons, client boundaries) live in `swiftgate lint` on SwiftSyntax, not SwiftLint custom regex rules. SwiftLint is optional, style-only; `doctor` warns if absent. | SwiftLint not installed; regex rules can't tell `Date()` in a Core module from one in a Live module or a string literal; one tool = one self-test surface | Re-enable SwiftLint custom rules in the template |
| D2 | Formatting via toolchain `swift format` (no separate install). | `swift format --version` → 6.2.1 | Swap formatter in `FormatRunner` |
| D3 | TOML via `mattt/swift-toml` 2.x behind a `ConfigDecoding` protocol. | 2.0.0 released 2026-02-01, MIT; TOMLKit last pushed 2025-01 | Swap the adapter |
| D4 | `swift-syntax` pinned `602.0.0..<603.0.0`. | Toolchain is Swift 6.2; 604.0.0 tracks Swift 6.4 | Bump with toolchain |
| D5 | `swift-argument-parser` from 1.8.2. | latest release 2026-06-04 | — |
| D6 | Gate package: tools-version 6.2, Swift 6 language mode, `platforms: [.macOS(.v15)]`, Swift Testing for its own tests. | spec §3 | — |

## How to work this plan

- **TDD per task:** write the failing test (named for the regression it catches), run it red, implement,
  run green, commit. Commit message: `feat(gate): <behavior>` / `test(gate): …` / `docs: …`.
- **Harness self-gate** until `swiftgate` can gate itself (end of M4):
  `cd gate && swift build && swift test && swift format lint --strict -r Sources Tests`.
  From M4 on: `bin/swiftgate check --tier fast` in the harness repo as well.
- **Fixtures are real.** Every adapter fixture is captured from a real tool run (command recorded in
  `gate/Tests/Fixtures/README.md` next to it), never hand-authored.
- **Waves** list tasks that can run concurrently (disjoint write sets). The orchestrating session
  owns this file; workers report back and never edit it.

## Wave map

| Wave | Tasks | Depends on |
|---|---|---|
| A | T0.1 → T0.2 → T0.3 (serial) | — |
| B | T1.1, T2.1, T5.0, T6.1 | A |
| C | T1.2, T1.3, T1.4, T1.5, T2.2, T2.3, T2.4 | B (T1.3/T1.4 also need T5.0's packages for fixtures) |
| D | T3.1, T3.2, T3.3, T3.4, T3.5 | C |
| E | T3.6, T4.1, T4.3 | D |
| F | T4.2, T4.4, T5.1, T5.2 | E |
| G | T5.3, T5.4, T5.5, T6.2 | F |
| H | T5.6, T7.1, T7.2, T7.3, T7.4 | G |
| I | T7.5 → T7.6 | H |

---

## M0 — Skeleton

### T0.1 Plugin manifest and layout
- Files: `.claude-plugin/plugin.json`, `README.md`, `.gitignore`, empty `skills/ agents/ workflows/ hooks/ templates/ docs/`.
- Verify: `plugin-dev:plugin-validator` agent passes; `claude plugin validate .` if available.
- Commit: `chore: plugin skeleton`.

### T0.2 `gate/` package + `swiftgate --version`
- Files: `gate/Package.swift` (D3–D6), targets `SwiftGateDomain`, `SwiftGateAdapters`, `SwiftGateCLI` (executable `swiftgate`), test targets per library.
- Test first: `versionCommandPrintsSemver` — catches a broken CLI entrypoint (every hook would fail silently).
- Verify: `swift run swiftgate --version`.

### T0.3 `bin/swiftgate` shim
- Behavior: hash `gate/Sources/**` + `Package.resolved` → if cached binary for that hash missing, `swift build -c release` into `${XDG_CACHE_HOME:-~/.cache}/swift-harness/<hash>/`; exec it with args. Prints build notice to stderr only.
- Test first (`tests/shim_test.sh`, run by `swift test` via a process test): stale hash rebuilds; unchanged hash execs cached binary with no build (< 100ms).
- Commit: `feat: swiftgate shim with source-hash cache`.

## M1 — Domain (pure)

### T1.1 Verdict, Finding, RunReport, JSON schema v1
- `Verdict` (`green/red/blocked`), `Finding` (rule, severity, file, line, message, failureScenario?), `RunReport` (schemaVersion, tiers, durations, counts, findings).
- Tests: encoding is stable (golden JSON via `expectNoDifference`) — catches silent schema drift that breaks hooks/skills; `blocked` never downgrades to `green` when merged with `green`.

### T1.2 Config model + loader
- `Config` per spec §5.4 (xcode, schemes, packages, simulator, budgets, pyramid, flows, mutation, clients, modules, judge).
- Validation errors: unknown `kind`, non-default kind without `reason`, `host_testable=false` without reason, `flows` > `max_flows`, unknown keys.
- Tests: one fixture per error class + a full valid fixture — catches config typos silently disabling a rule.

### T1.3 ModuleGraph
- Input: `swift package describe --type json` output (fixtures captured from T5.0's packages).
- Classifies each target: `Core` / `UI` / `Client` / `ClientLive` / `App` / `Test` by naming convention + config overrides; exposes imports and reverse deps.
- Tests: classification of every sample target; reverse-dep closure.

### T1.4 TierPlan
- Input: changed paths + ModuleGraph + tier → affected packages/test targets.
- Tests: change in `APIClient` selects dependents' tests; `Package.swift` change selects the whole package; doc-only change selects nothing (fast tier skips).

### T1.5 Renderer
- Human output ≤ 30 lines (verdict, top failures, `file:line`, pointer to `.harness/runs/<id>/`), `--json` full report.
- Tests: 500 findings still render ≤ 30 lines with an overflow count — catches context blow-up in hooks.

## M2 — Adapters

### T2.1 ProcessRunner
- Protocol + live impl (argv only, never shell strings; timeout; stdout/stderr capture; env overlay) + fake.
- Tests: timeout kills child and returns `blocked`-classifiable error; env overlay doesn't leak parent `SNAPSHOT_TESTING_RECORD`.

### T2.2 Git
- Changed files since ref, staged hunks with added-line ranges, per-file content hash, merge-base.
- Tests against a temp repo created in-test.

### T2.3 SwiftPM
- `describe`, `test` (filter, `--parallel`, coverage flag, structured output path), codecov path.
- Fixture capture from T5.0 packages.

### T2.4 FileLock + run store
- Machine-wide counting lock (`~/.cache/swift-harness/locks/sim.<n>`, flock-based), stale-owner detection by PID.
- Run store: `.harness/runs/<id>/`, `history.jsonl` append.
- Tests: third acquirer waits when cap = 2; dead-PID lock reclaimed.

## M3 — T0 checks (SwiftSyntax)

Common: `Rule` protocol (id, scope: module kinds/paths, visit → findings), inline allow parsing
(`// swiftgate:allow <rule> — <reason>`; bare allow → finding), per-rule fixture under
`gate/Fixtures/rules/<rule-id>/{bad,good}/`.

### T3.1 `lint`
Rules: `det.date-init`, `det.uuid-init`, `det.task-sleep`, `det.async-after`, `det.random` (Core/Client
interfaces only); `client.urlsession-shared`, `client.vendor-module` (outside `*Live`);
`obs.direct-logger`, `obs.direct-signposter`, `obs.print` (outside Log/Tracing Live);
`safety.try-bang`, `safety.as-bang`, `safety.unchecked-sendable`, `safety.nonisolated-unsafe`,
`safety.preconcurrency` (need same-line reason); `tca.banned-api` (spec §6.2 banned list);
`snap.record-mode` (`record:` other than `.never`/nil).
Tests: every rule red on `bad`, green on `good`; string literals/comments containing `Date()` don't fire.

### T3.2 `arch`
- Core imports no SwiftUI/UIKit; `*Live` imported only by App targets; Live doesn't import features;
  Core of kind `feature` contains a `@Reducer` (else undeclared-kind finding); every
  `@DependencyClient` type has a `TestDependencyKey` conformance with `testValue`;
  config kinds match the graph.

### T3.3 `testlint`
- Spec §7.4 static rules: no-assertion, tautology, existence-only, asserts-own-double, `try?`/empty
  catch, sleep, duplicate body (normalized AST hash), unnamed `@Test`, unjustified non-exhaustive
  `TestStore`, XCUITest outside `[[flows]]`, T2 test with no view/snapshot and Core-only imports.

### T3.4 `comments --staged`
- Spec §7.5 blocking + warning rules on comments in added lines (via T2.2 hunks).
- Tests include: `// MARK:` kept; `#warning` kept; commented-out Swift statement blocked; prose that
  merely contains a keyword not blocked.

### T3.5 `impact`
- Changed Core/Client/Live source without a test change in the same module → finding unless
  `.harness/impact-exemptions.json` entry with reason.

## M4 — Fast tier, coverage, hooks

### T3.6 `self-test`
- Iterates `gate/Fixtures/`: every `bad` → `red` with the expected rule id; every `good` and the
  clean sample → `green`. Fails if any rule has no fixture (checker hygiene, spec §6.3 §8).

### T4.1 `test --tier t1`
- Pre-step: confirm on the installed toolchain which structured output `swift test` offers for both
  XCTest and Swift Testing (xUnit output and/or event stream); record findings in fixtures README.
- Evidence rules: executed > 0 per selected target; skips must carry a reason; any failure → `red`
  with assertion text + `file:line`; runner crash → `blocked` only if environmental.

### T4.3 `coverage`
- `swift test --enable-code-coverage` → llvm-cov export JSON ∩ changed lines of Core/Client/Live;
  threshold from config; per-module T1 presence check.

### T4.2 `check --tier fast`
- Compose T0 + T1 via TierPlan; budgets; history record; `stats` (p50/p95 per tier).
- Harness from here gates itself with `bin/swiftgate check --tier fast`.

### T4.4 Hooks
- Pre-step: verify current hook input/output schema (Stop re-entry flag, PreToolUse decision shape,
  subagent identity field) against Claude Code docs; save sample payloads as fixtures.
- `hooks/hooks.json` → `${CLAUDE_PLUGIN_ROOT}/bin/swiftgate hook <event>`.
- `session-start`, `pre-tool-use` (Bash guards incl. raw `xcodebuild`; Edit guards; `git commit`
  → judge comment pass, advisory; ledger/index writes from non-orchestrator blocked),
  `post-tool-use` (single-file format + lint), `stop` (fast tier, hash-skip, 3-strike release
  stamped RED, `blocked` not a strike).
- Every hook: no-op without `.swiftgate.toml`; budget-tested with recorded payloads.

## M5 — Xcode-dependent (Xcode 26.2)

### T5.0 `examples/SampleApp`
- Thin app target + `Packages/`: `CounterFeature` (Core TCA + UI), `GameEngine` (engine kind),
  `APIClient`/`APIClientLive`, `HTTPClient`/`HTTPClientLive`, `LogClient`/`LogClientLive`.
  Point-Free deps at spec §6.2 pins; no direct `swift-issue-reporting` dependency on Swift 6.2;
  Core packages without MainActor default isolation (TCA #3768). Reference graph that resolves and builds
  on 26.2 was proven in a scratch package during research — reuse its pins.
- App project: hand-written synchronized-folder `.xcodeproj`; fallback: user creates it from the Xcode
  template and the task continues from there.
- Verify: builds for the iOS 26.2 simulator; `swift test` green on every Core package.

### T5.1 XcresultReader
- Pre-step: confirm `xcrun xcresulttool` subcommands for test results on 26.2.
- Capture fixtures from SampleApp runs: pass, fail, skip, crash, zero-tests. Tests parse each.

### T5.2 Simctl adapter
- Clone pinned base device, boot, install, launch, delete; orphan sweep (dead owner PID); lock from T2.4.

### T5.3 `test --tier t2|t3`
- `xcodebuild test` via ProcessRunner with per-worktree `-derivedDataPath`, cloned destination,
  `SNAPSHOT_TESTING_RECORD=never`, `-skipMacroValidation`, retry flags refused; T3 flows mapped to `[[flows]]`.

### T5.4 `snapshots record`, `doctor`, `gc`
- `record` only on the pinned device/OS; `doctor` checks Xcode pin, runtimes, disk, symlink,
  SwiftLint presence (warn), direct `swift-issue-reporting` dep on toolchain < 6.4 (red),
  MainActor default isolation on a Core target (red), recorded Xcode-upgrade hazards (warn); `gc` prunes DerivedData + runs by age.

### T5.5 `prove`, `stress`, per-test reach
- `prove`: scratch worktree, reverse-apply source diff, new tests must fail on assertion.
- `stress`: new/changed tests ×N shuffled. Reach: single-test coverage > 0 in target module.

### T5.6 `mutate`
- SwiftSyntax mutators (negate conditional, boundary, return default, remove call, remove
  `send`/effect) on changed lines; affected T1 run per mutant; cap + sampling; equivalent-mutant
  annotation; parallelism = CPU count − 1.
- Tests: a fixture with a weak test leaves a surviving mutant → `red`; strong test kills all.

## M6 — Docs

### T6.1 `docs/standards.md`
- From spec §6 with §6.2 verified baseline; every rule: do / tell / source; links each mechanical rule
  to its `swiftgate` rule id.

### T6.2 `docs/testing-playbook.md`
- From spec §7; worked examples drawn from SampleApp tests (TestStore, engine replay, snapshot, flow).

## M7 — Skills, workflow, bootstrap, E2E

### T7.1 Templates + `/swift-harness:bootstrap`
- Stamps spec §4.2 files; idempotent; shows diff before writing; registers repo in
  `~/.swift-harness/projects.json`; installs `~/.local/bin/swiftgate` symlink; `lefthook install`.
- Test: bootstrap twice on a temp copy of SampleApp → second run is a no-op.

### T7.2 Skills
- `architecture` (kind recommendation via fit signals + Core/UI or Client/Live scaffold),
  `tdd`, `test-gate`, `validate` (thin), `comment-audit`, `status`.
- Review each with `plugin-dev:skill-reviewer`.

### T7.3 Review agents + `review` workflow
- `agents/`: concurrency, architecture, test-quality, api-errors, swiftui, verifier.
- `swiftgate review-synth`: deterministic dedupe + verdict rule (spec §9.1–9.2) with tests.
- `workflows/review.js`: gather → pipelined review/verify → synth; `NOT REVIEWED` handling.
- `skills/review` entry point.

### T7.4 Judge seam
- `Judge` protocol (typed questions → probabilities), Claude backend (structured output via CLI),
  hash cache, thresholds; `gate/Fixtures/judge/` labeled set; `self-test --judge` precision/recall.

### T7.5 SampleApp end-to-end
- Bootstrap SampleApp; run `check` at fast/push/ready; seed one violation per tier and confirm
  `red`; run `/swift-harness:review` on a seeded diff and confirm verdict.

### T7.6 Install + dogfood
- Install the plugin locally; open a session in SampleApp; confirm SessionStart context, PostToolUse
  lint, Stop blocking on a seeded failure, pre-commit comment block, pre-push gate.
- Update the spec RESUME header: Foundation complete → sub-project 2 spec next.
