# Test fixtures

Every file here is real tool output. Never edit one by hand: re-run its capture command.

Commands run from the repository root. Where output embeds absolute paths, the capture pipes it
through `sed "s#$ROOT#/REPO#g"` (with `ROOT=$(pwd)`) so fixtures carry no machine paths; tests
decode them with repository root `/REPO`.

## SwiftPM

Toolchain: Apple Swift 6.2 (swiftlang-6.2.3.3.20), macOS 26.

| File | Capture |
|---|---|
| `SwiftPM/describe-<Package>.json` (APIClient, CounterFeature, GameEngine, HTTPClient, LogClient) | `(cd examples/SampleApp/Packages/<Package> && swift package describe --type json) \| sed "s#$ROOT#/REPO#g"` |
| `SwiftPM/dump-package-GameEngine.json` | `(cd examples/SampleApp/Packages/GameEngine && swift package dump-package) \| sed "s#$ROOT#/REPO#g"` |
| `SwiftPM/dump-package-main-actor-core.json` | `(cd gate/Fixtures/arch/arch.core-main-actor-isolation/bad/Packages/Feed && swift package dump-package) \| sed "s#$ROOT#/REPO#g"` |
| `SwiftPM/describe-no-package.stderr.txt` | `cd "$(mktemp -d)" && swift package describe --type json` (stderr; exit status 1, empty stdout) |
| `SwiftPM/show-codecov-path-GameEngine.txt` | `(cd examples/SampleApp/Packages/GameEngine && swift test --show-codecov-path) \| sed "s#$ROOT#/REPO#g"` |
| `SwiftPM/xunit-GameEngine.xml`, `SwiftPM/xunit-GameEngine-swift-testing.xml` | `X=$(mktemp -d); (cd examples/SampleApp/Packages/GameEngine && swift test --parallel --xunit-output $X/GameEngine.xml)`, then copy both files `$X` contains |

Observed behavior the adapter relies on:

- `swift package describe` prints the package `path` and local (`fileSystem`) dependency paths as
  absolute paths; target `path`s are package-relative. `product_dependencies` name products
  without their package.
- `describe` omits build settings; `dump-package` reports them per target as
  `settings[].kind.defaultIsolation._0` (`"MainActor"`, or `"nonisolated"` for `nil`) or as
  `unsafeFlags._0` argv. Neither command resolves remote dependencies.
- `--xunit-output <dir>/<stem>.xml` writes XCTest results to that path and Swift Testing results to
  `<dir>/<stem>-swift-testing.xml`. With no XCTest tests, the XCTest file still exists with
  `tests="0"`.
- `--show-codecov-path` prints the absolute path of the llvm-cov export JSON on one line; it does
  not require a coverage build to have run.
| `SwiftPM/describe-XUnitProbe.json` | `(cd gate/Fixtures/swifttest/XUnitProbe && swift package describe --type json) \| sed "s#$ROOT#/REPO#g"` |

## SwiftTest (T1 evidence)

`SwiftTest/<scenario>.{xml,-swift-testing.xml,stdout,stderr,status}` and `SwiftTest/pass-codecov.json`
are captured by `gate/Fixtures/swifttest/capture.sh` (run from the repository root), which runs
`swift test --parallel --xunit-output <dir>/<scenario>.xml --filter <regex>` in
`gate/Fixtures/swifttest/XUnitProbe` and copies whatever the run wrote. A scenario with no `.xml`
file is one where `swift test` wrote none.

| Scenario | Filter | What it shows |
|---|---|---|
| `pass` (with `--enable-code-coverage`) | `ProbeTests\.Pass` | one passing XCTest and one Swift Testing case; `pass-codecov.json` is the llvm-cov export from `--show-codecov-path` |
| `zero-codecov.json` only (with `--enable-code-coverage`) | `^EmptyTests\.` | the llvm-cov export of a run that executes no test: `Probe.swift` instrumented, nothing covered |
| `fail` | `ProbeTests\.Fail` | an `XCTAssertEqual` and an `#expect` failure |
| `skip` | `ProbeTests\.Skip` | `XCTSkip` with and without a message; `.disabled` with and without a reason |
| `shared-first-line` | `ProbeTests\.SharedFirstLine` | two `Issue.record` failures whose console lines both read `Issue recorded`; only the `↳` continuation lines (and the report message) tell them apart |
| `crash` | `ProbeTests\.Crash` | an index-out-of-range trap in each framework |
| `zero` | `^EmptyTests\.` | a target with no tests |
| `build-error` | `ProbeTests\.Pass` | a copy of the package (no build output) with a type error in `Probe.swift` |
| `reverted` | `ProbeTests\.Pass` | a copy with `double` computing `value * 3`: the passing tests fail on their assertions, as `prove` expects with a source change reverted |
| `compile-only` | `ProbeTests\.Pass` | a copy without the public `double` the tests call: no report, compile errors located in the test files |
| `stale-module-cache` | `ProbeTests\.Pass` | a copy including `.build/`, so the module cache path is stale (recorded as `/MOVED/XUnitProbe`) |

Observed behavior (Swift 6.2, `--parallel`) the evidence rules rely on:

- Both reports are written whenever tests ran: XCTest to `<stem>.xml`, Swift Testing to
  `<stem>-swift-testing.xml`. With `--no-parallel`, SwiftPM writes no XCTest report at all, so T1
  always runs `--parallel`.
- The XCTest report's `<failure message="failure">` is a placeholder. The assertion text and
  `file:line` are only on stdout: `<abs path>:<line>: error: -[<Target>.<Class> <method>] : <text>`.
- The Swift Testing report carries the issue text plus a ` (error)` suffix but no location; stdout
  has `✘ Test <name> recorded an issue at <File.swift>:<line>:<col>: <text>` (file name only).
- Swift Testing reports skips as `<skipped>reason</skipped>` or `<skipped />`. The XCTest report
  records an `XCTSkip` as a pass and stdout says nothing: XCTest skips are invisible under
  `--parallel`.
- A crash leaves the Swift Testing report truncated after `<testsuites>` and prints
  `Fatal error: …`; the XCTest report records the crashing case as a failure. stderr has
  `error: Exited with unexpected signal code 5`.
- A target with no tests yields reports with `tests="0"`, exit status 0, and the stderr warning
  `No matching test cases were run`.
- A compile error writes no report; stderr has `<abs path>:<line>:<col>: error: <text>`. Toolchain
  or cache failures print `<unknown>:0: error: …` instead.
- Toggling `--enable-code-coverage` rebuilds the package (about 20s for the SampleApp's TCA
  package), so every T1 run enables it.

## Mutation (`mutate`)

`LiveMutationToolchainTests` replays the `SwiftTest` captures above: `swift test --skip-build`
writes the same two xUnit reports as a building `swift test`, and `build-error` stands in for a
rejected `swift build --build-tests` (only its `error:` lines are read).

`gate/Fixtures/mutate` is not captured output but the real package `MutateSelfTests` runs:
`Scorer` at its base commit, `change/Score.swift` (the change under test, nine mutants) and two
suites for it. `weak/` leaves boundary mutants alive, so `mutate` is RED; `strong/` pins every
boundary and return value, so all nine are killed and it is GREEN. The test builds and runs them
for real in scratch worktrees (about 8s each).

## Xcresult (T2/T3 evidence)

Xcode 26.2 (17C48), `xcresulttool` version 24514, schema 0.1.0. The subcommands the gate uses:
`xcrun xcresulttool get test-results tests --path <bundle>` (the test tree) and
`xcrun xcresulttool get build-results --path <bundle>` (build errors). `get test-results summary`
also exists but its failures carry no `file:line`, so the gate does not read it.

`Xcresult/<scenario>.{tests.json,build-results.json,status}` are captured by
`gate/Fixtures/xcresult/capture.sh` (run from the repository root). It clones the pinned
simulator (iPhone 17, iOS 26.2), copies `examples/SampleApp/Packages` to a scratch directory, adds
`gate/Fixtures/xcresult/XcresultProbeTests.swift` to the copy's `CounterUISnapshotTests` target,
and runs `xcodebuild test -scheme CounterFeature-Package -skipMacroValidation
-only-testing:CounterUISnapshotTests/<suite>…` per scenario with `-derivedDataPath` under
`.harness/DerivedData/`. `status` is `xcodebuild`'s exit status. The script replaces the scratch
path with `/SCRATCH`, the clone's UDID with `CLONE-UDID`, its PID with `PID`, and elides the
machine's device list from the "no destination" error; the rest is verbatim.

| Scenario | Selection | What it shows |
|---|---|---|
| `pass` | `CounterViewSnapshotTests` (the real snapshot test), `ProbePassXCTests` | exit 0; both frameworks' cases under a `Unit test bundle` node |
| `fail` | `ProbeFailXCTests`, `ProbeFailSwiftTests`, `ProbePassXCTests` | exit 65; each failure's `Failure Message` is `<File>.swift:<line>: <text>` |
| `skip` | `ProbeSkipXCTests`, `ProbeSkipSwiftTests` | exit 0; skip reasons for both frameworks |
| `crash` | `ProbeCrashXCTests`, `ProbeCrashSwiftTests`, `ProbePassXCTests` | exit 65; the runner restarts after each crash and runs the rest |
| `zero` | `NoSuchSuite` | exit 0; a `Test Plan` node with no children |
| `no-destination` | an all-zero device id | exit 70; empty device, no test nodes, an `Uncategorized` build error |
| `build-error` | `ProbePassXCTests`, with the probe broken to not compile | exit 65; no test nodes; a `Swift Compiler Error` with a `sourceURL` |
| `record` | `CounterViewSnapshotTests`, `ProbeFailXCTests`, with `RECORD=all` (`TEST_RUNNER_SNAPSHOT_TESTING_RECORD=all`) | exit 65; the snapshot case fails with `Issue recorded: Record mode is on. Automatically recorded snapshot: …` beside a real assertion failure |
| `missing-bundle` | `xcresulttool` against a path that does not exist | `.stderr` + `.status` per subcommand (exit 64) |

`Xcresult/ui-pass.{tests,build-results}.json` are captured by `gate/Fixtures/xcresult/capture-ui.sh`
(run from the repository root): a real `swiftgate test --tier t3` of the SampleApp's app scheme
(its one XCUITest, `CounterFlowUITests`), read back with the same two `xcresulttool` subcommands.
The repository path becomes `/REPO`, the clone's name `swift-harness-PID-TOKEN` and its UDID
`CLONE-UDID`. It shows XCUITest cases under a `UI test bundle` node, identified
`<Class>/<method>()`.

Observed behavior the evidence rules rely on:

- Unlike host `swift test --parallel`, the bundle records XCTest skips, with reasons. XCTest:
  `Test skipped` or `Test skipped - <reason>`. Swift Testing: `Test '<name>' skipped` or
  `Test '<name>' skipped: <reason>`.
- A failure's location is a file name only; the rules resolve it against the selected targets'
  sources.
- A crash's message starts `Crash: `. Swift Testing crashes name `file <File>.swift line <n>`;
  XCTest crashes name only the crashing symbol.
- A build error's `sourceURL` is `file://<abs path>#…&StartingLineNumber=<0-based>&…`.
- An unresolved destination records a device whose `deviceId` is empty.

## Doctor

Captured on the machine the gate was built on (Xcode 26.2):
`xcodebuild -version > Doctor/xcodebuild-version.txt`, `swift --version > Doctor/swift-version.txt`
(both verbatim), and `Doctor/Package.resolved-CounterFeature.json`, a verbatim copy of
`examples/SampleApp/Packages/CounterFeature/Package.resolved` (format version 3).

## Simctl

`Simctl/<call>.{stdout,stderr,status}` are captured by `gate/Fixtures/simctl/capture.sh` (run from
the repository root): each file is one real `xcrun simctl` call against a throwaway clone of the
pinned simulator (`clone`, `list-devices` while the clone exists, `bootstatus -b`, `launch` of
`com.apple.Preferences`, `install` of a missing app, `shutdown`, `delete`), plus `clone` and `delete`
of an all-zero UDID. The scratch path is replaced with `/SCRATCH`.

- `simctl clone` prints only the new UDID; `launch` prints `<bundle id>: <pid>`.
- An unknown device exits 148 with `Invalid device: <udid>`.
- `bootstatus -b` boots the device and exits once it has finished booting.

## SwiftFormat

Toolchain `swift format` 6.2.1. Sources under `gate/Fixtures/format/` (excluded from the harness's
own gate) are the inputs.

| File | Capture |
|---|---|
| `SwiftFormat/lint-strict.stderr`, `SwiftFormat/lint-strict.status` | `(cd gate/Fixtures/format && swift format lint --strict Formatted.swift Unformatted.swift Broken.swift) 2>&1 >/dev/null \| sed "s#$ROOT#/REPO#g"`; the status file holds the exit status |

Observed behavior the adapter relies on:

- Diagnostics go to stderr as `<path>:<line>:<column>: error: [<Rule>] <message>` (`warning:`
  without `--strict`), with the path as given on the command line. A file that does not parse is
  reported with its absolute path and no `[Rule]`.
- Exit status is 1 when any diagnostic is printed under `--strict`, else 0. A path that does not
  exist is silently skipped with status 0, so the gate passes only existing files.

## Hooks

`Hooks/*.json` are Claude Code hook stdin payloads. They are built from the documented schema,
not captured from a live session (capturing needs a paid nested `claude` run): each carries the
fields the docs list for its event, with the docs' example values, paths rooted at `/REPO`, and a
fixed `session_id`. Tests swap `/REPO` for a probe repository. Re-check them against the docs
whenever Claude Code's hook contract changes.

Sources, fetched 2026-09-24 as Markdown (`curl -sL <url>.md`):

- Hooks reference, https://code.claude.com/docs/en/hooks — common input fields; SessionStart,
  PreToolUse (Bash/Edit/Write `tool_input`), PostToolUse and Stop inputs; JSON output and decision
  control; exit-code semantics; timeouts.
- Plugins reference, https://code.claude.com/docs/en/plugins-reference, and plugin components,
  https://code.claude.com/docs/en/plugins/components — `hooks/hooks.json` format and
  `${CLAUDE_PLUGIN_ROOT}`.

Contract points the hooks rely on:

- Every payload has `session_id`, `transcript_path`, `cwd`, `hook_event_name`; tool events add
  `tool_name`, `tool_input`, `tool_use_id`. File-tool `tool_input.file_path` is always absolute.
- Inside a subagent every event also carries `agent_id` (and `agent_type`); the main thread never
  does. That is how a worker is told apart from the orchestrator.
- Stop carries `stop_hook_active`: `true` when Claude is continuing because a Stop hook blocked.
  Claude Code ends the turn itself after 8 consecutive blocks; swiftgate releases after 3.
- A hook decides by exiting 0 with JSON on stdout. PreToolUse denies with
  `hookSpecificOutput.permissionDecision: "deny"` plus `permissionDecisionReason` (shown to
  Claude). PostToolUse and Stop use top-level `decision: "block"` with `reason`.
  `hookSpecificOutput.additionalContext` adds context (SessionStart, PreToolUse, PostToolUse);
  `systemMessage` shows the user a message without continuing the turn.
- Exit 2 also blocks, with stderr as the reason; any other non-zero exit is a non-blocking error,
  so swiftgate uses exit 1 only for a malformed payload. A hook that times out renders no
  decision, and on PreToolUse the call proceeds.
- `additionalContext`, `systemMessage` and plain stdout are capped at 10,000 characters.
- Plugin hooks live in `hooks/hooks.json` under a top-level `hooks` key, in the `settings.json`
  shape. With `args` set, the hook runs in exec form: `command` and each `args` element have
  `${CLAUDE_PLUGIN_ROOT}` substituted and no shell is involved. `timeout` is in seconds
  (default 600 for command hooks).

## Bootstrap

Xcode 26.2 (17C48), run from `examples/SampleApp`:

| File | Capture |
|---|---|
| `Bootstrap/xcodebuild-list-project.json` | `xcrun xcodebuild -list -json -project SampleApp.xcodeproj` (verbatim stdout, exit 0) |
| `Bootstrap/xcodebuild-list-missing.{stdout,stderr,status}` | `xcrun xcodebuild -list -json -project Missing.xcodeproj`; the result-bundle path under the user temp directory is replaced with `/TMP/` |

Observed behavior the adapter relies on:

- A project listing is `{"project": {"name", "schemes", "targets", "configurations"}}`. Package
  products of local packages appear as schemes beside the app's, so the app scheme is the one named
  after the project, or else the only scheme that is also a target.
- Listing resolves the project's packages first (16s cold on the sample app).
- A missing project exits 66 with the error on stderr.

## Judge

Claude Code 2.1.282, run from a scratch directory with the schema in
`Judge/claude-capture-schema.json` (the shape `ClaudeJudgePrompt.schema` builds for a one-question
set) and the prompt in `Judge/claude-capture-prompt.txt` on stdin:

| File | Capture |
|---|---|
| `Judge/claude-result.json` | `claude -p --output-format json --json-schema "$(cat claude-capture-schema.json)" --restricted --tools "" --strict-mcp-config --no-session-persistence --model haiku < claude-capture-prompt.txt` (verbatim stdout, exit 0) |
| `Judge/claude-unknown-model.json` | the same with `--model no-such-model` (verbatim stdout, exit 1; stderr was `[claude-code:unrecognized_model] {"model":"no-such-model","query_source":"sdk"}`) |

Observed behavior the adapter relies on:

- `--output-format json` prints one result envelope. With `--json-schema` the validated reply is
  the `structured_output` object (and also JSON text in `result`).
- A failed call still prints an envelope, with `is_error: true` and the message in `result`, and
  exits 1.
- `--restricted` ignores user, project and local settings (so plugin hooks don't run inside the
  judge) and `--tools ""` removes every built-in tool.
