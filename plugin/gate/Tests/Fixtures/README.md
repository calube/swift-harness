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
| `macro-compile-error` | `ProbeTests\.Pass` | a copy with a `#expect(try …)` call added to `PassTests.swift` inside a non-throwing test: no report, a macro expansion diagnostic with no file:line of its own |
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
  or cache failures print `<unknown>:0: error: …` instead. A `#expect`/`#require` macro that fails
  to expand (for example `try` in a non-throwing test) prints `macro expansion #<name>:<line>:<col>:
  error: <text>` instead of a file location, followed by `` `- <abs path>:<line>:<col>: note:
  expanded code originates here`` naming the real test file.
- Toggling `--enable-code-coverage` rebuilds the package (about 20s for the SampleApp's TCA
  package), so every T1 run enables it.

`SwiftTest/resolved-file-missing.{stdout,stderr,status}` and
`SwiftTest/resolved-file-stale.{stdout,stderr,status}` are `--only-use-versions-from-resolved-file`
rejecting a package `XUnitProbe` can't reproduce (it has no dependencies), so they come from a
throwaway pair of real git repos instead of `capture.sh`:

```
D=$(mktemp -d); mkdir -p "$D/Dep" "$D/Consumer"
(cd "$D/Dep" && git init -q -b main && printf '// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "Dep", products: [.library(name: "Dep", targets: ["Dep"])], targets: [.target(name: "Dep")])\n' > Package.swift && mkdir Sources && mkdir Sources/Dep && echo 'public func depHello() -> String { "hello" }' > Sources/Dep/Dep.swift && git add -A && git -c user.name=e -c user.email=e@e commit -qm v1 && git tag 1.0.0)
(cd "$D/Consumer" && git init -q -b main && printf '// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "Consumer", dependencies: [.package(url: "file://%s/Dep", exact: "1.0.0")], targets: [.target(name: "Consumer", dependencies: [.product(name: "Dep", package: "Dep")])])\n' "$D" > Package.swift && mkdir Sources && mkdir Sources/Consumer && printf 'import Dep\npublic func greeting() -> String { depHello() }\n' > Sources/Consumer/Consumer.swift)
# resolved-file-missing: no Package.resolved at all
(cd "$D/Consumer" && swift test --only-use-versions-from-resolved-file --parallel --xunit-output /tmp/x.xml)
# resolved-file-stale: resolve once, then add a second dependency without re-resolving
(cd "$D/Consumer" && swift package resolve)
mkdir -p "$D/Dep2" && (cd "$D/Dep2" && git init -q -b main && printf '// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "Dep2", products: [.library(name: "Dep2", targets: ["Dep2"])], targets: [.target(name: "Dep2")])\n' > Package.swift && mkdir Sources && mkdir Sources/Dep2 && echo 'public func dep2Hello() -> String { "hello2" }' > Sources/Dep2/Dep2.swift && git add -A && git -c user.name=e -c user.email=e@e commit -qm v1 && git tag 1.0.0)
(cd "$D/Consumer" && printf '// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "Consumer", dependencies: [.package(url: "file://%s/Dep", exact: "1.0.0"), .package(url: "file://%s/Dep2", exact: "1.0.0")], targets: [.target(name: "Consumer", dependencies: [.product(name: "Dep", package: "Dep")])])\n' "$D" "$D" > Package.swift && swift test --only-use-versions-from-resolved-file --parallel --xunit-output /tmp/x.xml)
```

The capture pipes stderr through `sed "s#$D#/FIXTURE#g"` for both; `status` is the exit code (`1`),
`stdout` is empty, and neither writes an xUnit report.

`SwiftTest/emptied-target.{stdout,stderr,status}` is a package whose library target lost every
source file, as a package added since the merge base looks once `prove` reverts its sources.
`XUnitProbe` has no product, and with no product SwiftPM reports a missing module in the tests
instead, so the capture adds a `Probe` library product to a copy and deletes its `Sources`, from the
repository root:

```
W=$(mktemp -d) && mkdir -p "$W/XUnitProbe" && rsync -a --exclude .build plugin/gate/Fixtures/swifttest/XUnitProbe/ "$W/XUnitProbe/" && sed -i '' 's/  platforms: \[.macOS(.v15)\],/&\n  products: [.library(name: "Probe", targets: ["Probe"])],/' "$W/XUnitProbe/Package.swift" && /bin/rm -rf "$W/XUnitProbe/Sources" && (cd "$W/XUnitProbe" && swift test --parallel --xunit-output "$W/emptied-target.xml" --filter 'ProbeTests\.Pass' >"$W/emptied-target.stdout" 2>"$W/emptied-target.stderr"; echo "$?" >"$W/emptied-target.status")
for f in stdout stderr status; do sed "s#$W#/FIXTURE#g" "$W/emptied-target.$f" > plugin/gate/Tests/Fixtures/SwiftTest/emptied-target.$f; done
```

SwiftPM refuses the manifest before building: `status` is `1`, `stdout` is empty, SwiftPM writes no
xUnit report, and stderr ends `error: 'xunitprobe': target 'Probe' referenced in product 'Probe' is
empty` (Swift 6.2).

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

`plugin/gate/Fixtures/xcresult/capture-app-build.sh` captures
`Xcresult/app-build-{pass,error}.build-results.json`: a scratch git copy of `examples/SampleApp`
runs `swiftgate check --tier fast --base HEAD --app-build` as committed (`pass`, GREEN), then again
with a commit that adds `static let broken: Int = "not a number"` to `App/SampleApp.swift`
(`error`, RED, `--base HEAD~1`). The script reads each back with
`xcrun xcresulttool get build-results` from the run's `app-build/SampleApp.xcresult`. The scratch path becomes `/SCRATCH`, in both its
`/private/var` and its `/var` spelling: xcodebuild blames files under `/var`. A generic
`iOS Simulator` build bundle holds build results and no test tree.

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

`plugin/gate/Fixtures/simctl/capture-booted-base.sh` (run from anywhere) captures
`Simctl/{clone-booted,create,list-devices-booted-base}.{stdout,stderr,status}`. It creates a
throwaway `swiftgate capture base` (iPhone 17, iOS 26.2), boots it with `bootstatus -b`, then records
`clone <base> swift-harness-<pid>-booted`, `create swift-harness-<pid>-created
com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-26-2`, and
`list devices --json` while the base runs and the created device exists. On exit it shuts down
and deletes only the devices it made.

- `simctl clone` of a booted device exits 149 with `SimError` code 405, `Unable to clone device in
  current state: Booted`, and makes nothing.
- `simctl create` prints only the new UDID. The device list gives each device's
  `deviceTypeIdentifier`.

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

`Hooks/*.json` are Claude Code hook stdin payloads. Seven are captured from live headless
sessions (Claude Code 2.1.282, 2026-09-25) in a bootstrapped SampleApp copy, with the plugin
loaded by `--plugin-dir` and recording on:

```
SWIFTGATE_HOOK_RECORD_DIR=<dir> claude -p '<prompt>' --plugin-dir <harness checkout> \
  --permission-mode acceptEdits --setting-sources project,local \
  --output-format stream-json --verbose --include-hook-events
```

`session-start`, `pre-tool-use-bash-xcodebuild` (prompt: run a raw `xcodebuild … test`),
`pre-tool-use-edit-swift`, `post-tool-use-edit-swift`, `stop`, `stop-reentry` (prompt: add a
literal `Date()` to CounterCore's reducer and stop without fixing) and `pre-tool-use-bash-allowed`
(a `swiftgate check` the model ran). Scrubbing: the repository path becomes `/REPO`, the
transcript directory `/HOME/.claude/projects/-REPO/`, and every `session_id` the fixed
`8f2c1d7e-…` the tests key on; nothing else changed.

The rest (`pre-tool-use-bash-git-commit`, `pre-tool-use-edit-snapshot`,
`pre-tool-use-write-*`, `post-tool-use-write-markdown`, `session-start-resume`) are still built
from the documented schema: no live session produced a Write, a subagent or a resume. Tests swap
`/REPO` for a probe repository. Re-record whenever Claude Code's hook contract changes.

Live payloads differ from the documented examples only in fields swiftgate does not read:
SessionStart has no `model` in a headless session; Bash `tool_input` omits `timeout` and
`run_in_background` unless the model sets them; PostToolUse carries `effort` and a full
`tool_response` (`originalFile`, `structuredPatch`, `oldString`, `newString`, `replaceAll`,
`userModified`).

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

## Jev

TypeSafe's `POST https://api.typesafe.ai/v1/systemone`, captured 2026-09-30 with `curl` 8.7.1 and
the user's key in `TYPESAFE_API_KEY`. Each command runs from `plugin/gate/Tests/Fixtures/Judge`
under `bash`; the key reaches `curl` through a process substitution, so it never appears in an
argument list, and the capture keeps no request or response headers. `<name>` is the file stem below.

```sh
curl -sS -o jev-<name>.reply.json -w '%{http_code}\n' \
  -H @<(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY") \
  -H 'Content-Type: application/json' \
  --data-binary @jev-request-<name>.json https://api.typesafe.ai/v1/systemone > jev-<name>.status
```

A script builds the request inputs from real subjects, in the shape design §4.1 gives:
`state` holds `subject_kind` (the question set's `subjectDescription`), `subject`, `context` and,
for tests, `declared_tier`; each question's `instructions` is its `JudgeQuestion.text` unchanged.

| Request | Subject | Questions |
|---|---|---|
| `jev-request-test-quality.json` | `gate/Fixtures/judge/cases/counter-increment` (`Test.swift.txt` as `subject`, `Change.diff` as `context`), `declared_tier` `T1` | `test-quality@1`: 2 Noul, 1 Choice (`criteria` `{T1: null, T2: null, T3: null}`), 1 Score (`criteria` `["vague", "partial", "specific"]`) |
| `jev-request-alias.json` | the same for `own-double`, with `model` `jev-latest` | `test-quality@1` |
| `jev-request-invalid.json` | `own-double` | only `tier`, a Choice with its `criteria` removed |
| `jev-request-comments.json` | the comment `// Length-prefixing each field …` in `plugin/gate/Sources/SwiftGateDomain/Judge/Judge.swift` as it reads at commit `618c180`, with the 6 lines after it as `context` (the commit comment judge's slice) | `comments@1`: 2 Noul |

| File | Capture | Status | Served `model` |
|---|---|---|---|
| `jev-test-quality.reply.json`, `.status` | the command above, `<name>` = `test-quality` | 200 | `jev-1.13.0` |
| `jev-comments.reply.json`, `.status` | `<name>` = `comments` | 200 | `jev-1.13.0` |
| `jev-alias.reply.json`, `.status` | `<name>` = `alias` (requests `jev-latest`) | 200 | `jev-1.13.0` |
| `jev-invalid.reply.json`, `.status` | `<name>` = `invalid` | 422 | none |
| `jev-bad-key.reply.json`, `.status` | `TYPESAFE_API_KEY=invalid`, then the command with `-o jev-bad-key.reply.json`, `--data-binary @jev-request-test-quality.json` and `> jev-bad-key.status` | 401 | none |
| `jev-oversize.reply.json`, `.status` | the request isn't kept (157 KB): `git ls-tree -r --name-only 1075aa6 -- ../../../Sources/SwiftGateDomain \| grep '\.swift$' \| sort \| while read p; do git show "1075aa6:$p"; done \| python3 -c 'import json,sys; r=json.load(open("jev-request-test-quality.json")); r["state"]["subject"]=sys.stdin.read()[:150000]; json.dump(r,open(sys.argv[1],"w"))' "$TMPDIR/jev-request-oversize.json"`, then the command with `--data-binary @"$TMPDIR/jev-request-oversize.json"` and `-o jev-oversize.reply.json`, `> jev-oversize.status` | 400 | none |

Observed behavior the adapter relies on:

- A `.status` file holds the HTTP status and a newline; the reply body is what the server sent,
  byte for byte, compact JSON with no trailing newline.
- The server answers `jev-latest` with `jev-1.13.0`: the reply's `model` is the resolved id, never the alias.
- Question keys with hyphens (`fails-if-broken`, `name-specificity`) come back unchanged as the
  keys of `answers`. The server may reorder the options inside `probabilities` (`T3` came first).
- A Noul answer is `{"type": "noul", "noul": p}`, with no `confidence`.
- A Choice answer is `{"type": "choice", "choice", "confidence", "probabilities"}`, with
  `probabilities` keyed by the option names sent in `criteria`.
- A Score answer is `{"type": "score", "score", "confidence", "legend", "probabilities"}`.
  The level index, as a string, keys `legend` and `probabilities`, `"0"` first, and
  `legend["i"]` is the text of level `i` in the order `criteria` listed them. `score` is the
  probability-weighted index and `confidence` can be 0 while `probabilities` are spread.
- No answer carries a reason, rationale or any text beyond the option and level names.
- `usage` is `{"input_tokens", "output_tokens"}`; output tokens appear even though TypeSafe
  prices them at 0.
- A 422 body is `{"detail": [{"type", "loc", "msg", "input"}]}`, and `loc` names the question key
  and the missing field (`["body", "questions", "tier", "choice", "criteria"]`).
- A bad key is 401 with `{"detail": {"error_type": "authentication_error", "message"}}`.
- A state over the model's limit is 400, not 422, with `{"detail": {"error_type":
  "max_tokens_exceeded"}}` and no count; the adapter's own estimate refuses it before sending.

### `test-quality@2-jev` and described Score levels

Captured 2026-09-30 17:39 UTC with the same `curl`, key and command as above (design §13.2 to §13.4).
The request inputs come from code, not by hand. `test_name` and `assertions` are what the gate's
own parser returns: `SwiftGateDomain/Judge/JudgeTestSubjectParts.swift` compiled on its own into a
helper that reads a test's source on stdin.

```sh
cat > "$SCRATCH/main.swift" <<'SWIFT'
import Foundation
let source = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
struct Parts: Encodable {
  let test_name: JudgeTestName
  let assertions: [String]
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let parts = Parts(test_name: JudgeTestName.parse(source: source), assertions: JudgeAssertions.extract(source: source))
FileHandle.standardOutput.write(try encoder.encode(parts))
SWIFT
swiftc -O -o "$SCRATCH/judge-parts" \
  ../../../Sources/SwiftGateDomain/Judge/JudgeTestSubjectParts.swift "$SCRATCH/main.swift"
python3 "$SCRATCH/build_requests.py" "$SCRATCH/judge-parts" "$(git rev-parse --show-toplevel)"
```

`build_requests.py`, run from this directory:

```python
import json, subprocess, sys

parts_tool, root = sys.argv[1], sys.argv[2]
cases = root + "/plugin/gate/Fixtures/judge/cases/"
study = json.load(open(root + "/evals/results/2026-09-30-jev-question-design/questions.json"))
base = json.load(open("jev-request-test-quality.json"))


def sub_questions():
    out = {}
    for q in study["questions"]:
        for sub in q["jev"]["subQuestions"]:
            key = q["id"] if q["id"] == "tier" else q["id"] + "." + sub["id"]
            body = {k: v for k, v in sub.items() if k != "id"}
            if q["id"] == "tier":
                body = dict(base["questions"]["tier"])
            out[key] = body
    return out


def native(case):
    source = open(cases + case + "/Test.swift.txt").read()
    parts = json.loads(subprocess.run([parts_tool], input=source.encode(), capture_output=True, check=True).stdout)
    state = {
        "subject_kind": base["state"]["subject_kind"],
        "test_name": {k: parts["test_name"].get(k) for k in ("full", "behavior", "catches")},
        "test_source": source,
        "assertions": parts["assertions"],
        "code_under_test": open(cases + case + "/Change.diff").read(),
        "declared_tier": "T1",
    }
    return {"model": base["model"], "state": state, "questions": sub_questions()}


def levels():
    request = json.loads(json.dumps(base))
    question = request["questions"]["name-specificity"]
    clauses = question["instructions"].split("? ", 1)[1].rstrip(".").split("; ")
    assert [c.split(":")[0] for c in clauses] == question["criteria"], clauses
    question["criteria"] = clauses
    return request


def write(name, request):
    with open("jev-request-" + name + ".json", "w") as f:
        json.dump(request, f, indent=2, ensure_ascii=False)
        f.write("\n")


write("test-quality-2-jev-good", native("counter-increment"))
write("test-quality-2-jev-useless", native("own-double"))
write("test-quality-levels", levels())
```

The sub-questions come from the study's `questions.json` unchanged, and equal the JSON block in
design §13.3 key for key. Both cases declare `T1` in `gate/Fixtures/judge/labels.json`. `tier` is
the `@1` question as the adapter already sends it.

| Request | Subject | Questions |
|---|---|---|
| `jev-request-test-quality-2-jev-good.json` | `counter-increment`: `test_source` from `Test.swift.txt`, `code_under_test` from `Change.diff`, `declared_tier` `T1` | `test-quality@2-jev`: 6 sub-questions keyed `<question id>.<sub-question id>` (5 Noul, 1 Choice) and `tier` |
| `jev-request-test-quality-2-jev-useless.json` | `own-double`, the same way | the same |
| `jev-request-test-quality-levels.json` | `jev-request-test-quality.json` with only `name-specificity`'s `criteria` changed: each level with its clause from the question's text, as in `"vague: names no symptom or restates the behavior"` | `test-quality@1` |

| File | Capture | Status | Served `model` |
|---|---|---|---|
| `jev-test-quality-2-jev-good.reply.json`, `.status` | `<name>` = `test-quality-2-jev-good` | 200 | `jev-1.13.0` |
| `jev-test-quality-2-jev-useless.reply.json`, `.status` | `<name>` = `test-quality-2-jev-useless` | 200 | `jev-1.13.0` |
| `jev-test-quality-levels.reply.json`, `.status` | `<name>` = `test-quality-levels` | 200 | `jev-1.13.0` |

Observed behavior the `@2-jev` rendering relies on:

- Dotted question keys (`fails-if-broken.runs-changed-code`) come back unchanged as the keys of
  `answers`, in the order sent; `tier` sits beside them under its own id.
- The server takes a Noul with an object `instructions` (`question` and `focus`) and object
  `criteria` (`true`/`false` with `what`, `examples` or `not_for`), and a Noul with no `criteria`
  (`log-text`). A Choice keyed by option names with object values answers with `probabilities`
  keyed by those names.
- The combination rules separate the 2 cases: `fails-if-broken` gives `p_no` 0.06 for
  `counter-increment` and 0.90 for `own-double` (from `runs-changed-code` 0.1), and
  `asserts-implementation` gives `p_yes` 0.11 and 0.05.
- `name-specificity.catches-adds` answers `condition` (0.79) for `counter-increment`, whose
  label is `specific`, and `nothing` (0.90) for `own-double`.
- A Score `legend` echoes each level string as sent, byte for byte, description included:
  `legend["0"]` is `"vague: names no symptom or restates the behavior"`. A legend check compares
  it with the sent strings, not the bare level names.
- `usage.output_tokens` is 203 for both `@2-jev` requests and 99 for both `@1` requests, so it
  tracks the question count, not the answers.

## Review

| File | Capture |
|---|---|
| `Review/d7-api-errors.json`, `Review/d7-architecture.json` | Verbatim copies of `review-findings/api-errors.json` and `review-findings/architecture.json` from a real run of `workflows/review.js` on the SampleApp "Review input" change (see `docs/e2e-report.md`). Neither file contains a machine path, so nothing was scrubbed. |

Observed behavior synthesis relies on: two reviewers citing the same rule at the same line invent
different `category` strings (`live-client-logic`, `logic-in-live-client`), so standards
violations dedupe on `rule`, not `category`.

| File | Capture |
|---|---|
| `Review/dismiss-race/{api-errors,architecture,concurrency,test-quality}.json` | Verbatim copies of `review-findings/<focus>.json` from the swift-harness-evals `review-dismiss-without-cancel` trial of 2026-09-27 (evals-round-7, `/swift-harness:review` at harness `2f39ae8`). No machine path appears in them. |
| `Review/dismiss-without-cancel.patch`, `Review/clean-reset.patch` | `examples/SampleApp` copied to a scratch directory, `git init` + commit, then the evals case's `change.patch` applied and committed, then the exact diff `LiveGit.unifiedDiff` runs: `git diff --unified=3 --no-color --no-ext-diff --no-textconv --relative --find-renames --src-prefix=a/ --dst-prefix=b/ HEAD~1 -- .`. Tests render them with `NumberedDiff.render` to get `diff-numbered.txt`. |

| File | Capture |
|---|---|
| `Review/dismiss-rule-pair/{concurrency,api-errors}.json` | Verbatim copies of `review-findings/<focus>.json` from the swift-harness-evals `review-dismiss-without-cancel` trial of 2026-09-27 (the review-accuracy confirming run, `/swift-harness:review` at harness `0a99c70`, run `20260927T151548Z-aabadbfd`), taken from that trial's `kept/.harness/runs/<run>/review-findings/`. No machine path appears in them. |

Observed behavior synthesis relies on: the concurrency reviewer filed the dismiss race as a `defect`
that cites rule `C3`. The api-errors reviewer filed the same race at the same lines and
`severity_rule` as a `defect` with no rule and another category (`api-misuse`). So a defect may
carry a rule, and a rule-less copy of a finding must never replace the copy that cites one.

Observed behavior synthesis relies on: 1 user-visible race came back from 4 reviewers at
`CounterFeature.swift` lines 67, 69, 69 and 70 under the categories `missing-effect-cancellation`,
`missing-cancellation`, `effect-lifetime` and `missing-edge-case`. So defects merge across a
3-line window, and the cancellation names share a canonical category.

## DesignTelemetry

| File | Capture |
|---|---|
| `DesignTelemetry/research-result.json`, `DesignTelemetry/research-result-no-budget.json` | `DESIGN_TELEMETRY_CAPTURE_DIR=plugin/gate/Tests/Fixtures/DesignTelemetry mise exec node@24 -- node tests/design_research_workflow_test.mjs` |
| `DesignTelemetry/review-result.json`, `DesignTelemetry/review-result-no-budget.json` | `DESIGN_TELEMETRY_CAPTURE_DIR=plugin/gate/Tests/Fixtures/DesignTelemetry mise exec node@24 -- node tests/design_review_workflow_test.mjs` |

Each file is the return value of the real `workflows/design-research.js` or
`workflows/design-review.js`, run by the node test's harness. The harness stubs the lane and
reviewer agents and the runtime's `budget`: each stub call adds a fixed count to
`budget.spent()`, and the `-no-budget` files ran with no `budget` in scope. So the `telemetry`
block is the script's own output, and its token counts are the stubs' counts, not a model's.

## Probe

Apple Swift version 6.2 (swiftlang-6.2.3.3.20 clang-1700.6.3.2), `arm64-apple-macosx26.0`.
`Probe/<scenario>.{stdout,status}` are `swift build` runs of a scratch package outside the repo
(stderr was empty for every scenario, so it is not captured). Each probe file is named after the
enum it declares, `Probe_<id>.swift`, per spec §6.2 — `swiftgate probe` attributes a diagnostic
back to its claim by matching the diagnostic's file name against this convention.

```
SCRATCH=$(mktemp -d)
mkdir -p "$SCRATCH/Sources/ProbeScratch"
cat > "$SCRATCH/Package.swift" <<'SWIFT'
// swift-tools-version:6.2
import PackageDescription

let package = Package(
  name: "ProbeScratch",
  targets: [
    .target(name: "ProbeScratch")
  ]
)
SWIFT
cat > "$SCRATCH/Sources/ProbeScratch/Probe_ev_good_effect_cancel.swift" <<'SWIFT'
enum Probe_ev_good_effect_cancel {
  static func run() -> Int { 1 + 1 }
}
SWIFT
cat > "$SCRATCH/Sources/ProbeScratch/Probe_ev_warns_but_compiles.swift" <<'SWIFT'
enum Probe_ev_warns_but_compiles {
  static func run() -> Int {
    let unused = 42
    return 1
  }
}
SWIFT
# good.{stdout,status}: swift build here (only the two files above)

cat > "$SCRATCH/Sources/ProbeScratch/Probe_ev_fabricated_symbol.swift" <<'SWIFT'
enum Probe_ev_fabricated_symbol {
  static func run() -> Int {
    fabricatedAPIThatDoesNotExist()
  }
}
SWIFT
cat > "$SCRATCH/Sources/ProbeScratch/Probe_ev_wrong_signature.swift" <<'SWIFT'
enum Probe_ev_wrong_signature {
  static func run() -> Bool {
    "abc".hasPrefix(5)
  }
}
SWIFT
rm -rf "$SCRATCH/.build"
# mixed.{stdout,status}: swift build here (all four probe files above)

cat > "$SCRATCH/Sources/ProbeScratch/Extra.swift" <<'SWIFT'
let extraSyntaxError: Int =
SWIFT
rm -rf "$SCRATCH/.build"
# unattributed.{stdout,status}: swift build here (the four probes plus Extra.swift, which
# is not a probe file — its errors match no `Probe_<id>.swift` name)
```

Each build's absolute scratch path is replaced with `/SCRATCH`.

| Scenario | Probe files | What it shows |
|---|---|---|
| `good` | good, warns | exit 0; the only diagnostic is the `warns` probe's warning |
| `mixed` | good, warns, fabricated, wrong-signature | exit 1; `fabricated` and `wrong-signature` each fail with one `error:` in their own file only; `good` and `warns` have no error |
| `unattributed` | mixed + `Extra.swift` (not a probe) | exit 1; `Extra.swift`'s syntax error recurs once per compile job, attributable to no claim |

Observed behavior the domain relies on:

- A diagnostic's primary line is `<abs path>:<line>:<col>: error|warning: <message>`, optionally
  suffixed `[#<category>]` on a warning; the following source-snippet and caret-continuation lines
  carry no `path:line:col:` prefix, so a line-anchored match never mistakes them for a diagnostic.
- Diagnostics print on stdout, not stderr, under plain `swift build`.
- A parse error in one file is re-emitted once per remaining compile job in the same invocation
  (`unattributed.stdout` shows `Extra.swift`'s error five times) — attribution must not assume one
  diagnostic per file, and a probe's own single real error must not be mistaken for several.
- A warning never fails its build (`good.status` is `0`); only `error:` lines do.

### `swiftgate probe` on the iOS simulator

Xcode 26.2 (17C48), iphonesimulator SDK 26.2. `Probe/ios-sampleapp.{stdout,status}` are one real
`swiftgate probe --json` run against the SampleApp's `CounterFeature` package (target
`CounterCore`, swift-composable-architecture 1.26.2), with the two snippets in
`gate/Fixtures/probe/ios-snippets/`: a `@Reducer` feature (real TCA API, passes) and
`Effect<Int>.teleport(to:)` (fabricated, fails). stderr held only the shim's own build log, so it
is not captured. Run from the repository root with a cold `.harness/probe/` and an empty cache
home; wall time was 80s including a 36s rebuild of `swiftgate` by the shim:

```sh
mkdir -p docs/designs/probe-sampleapp.evidence/probes
cp gate/Fixtures/probe/ios-snippets/*.snippet.swift docs/designs/probe-sampleapp.evidence/probes/
HOME_DIR=$(mktemp -d)
bin/swiftgate probe --design docs/designs/probe-sampleapp.md \
  --package examples/SampleApp/Packages/CounterFeature --target CounterCore \
  --cache-home "$HOME_DIR" --json > gate/Tests/Fixtures/Probe/ios-sampleapp.stdout
echo $? > gate/Tests/Fixtures/Probe/ios-sampleapp.status
rm -rf docs/designs/probe-sampleapp.evidence
```

The output holds no machine path: diagnostics are recorded against the evidence-relative wrapper
(`probes/Probe_<id>.swift`), which has the same line numbers as the scratch copy `xcodebuild`
compiled. The local `APIClient` and `LogClient` products are left out with a note.

## DesignSha

git 2.50.1 (Apple Git-155). `DesignSha/*.md` are the inputs, not tool output: each
`<variant>-approved.md` is a design doc, and `<variant>.stripped.md` is the same doc with its
frontmatter `status:` line removed by hand, so the expected sha never comes from the code under
test. `lf-proposed.md` differs from `lf-approved.md` only in its status value. Variants: `lf`,
`crlf` (every line ends `\r\n`), `no-trailing-newline`, `non-ascii` (Latin accents, CJK, an emoji),
and `fenced-status-edited`, whose body has a `status:` line inside a fenced block that must stay
hashed. `DesignSha/.gitattributes` sets `-text` so checkout never rewrites the line endings.

`DesignSha/hashes.txt` is the captured output, `<sha> <file>` per line, from a real temp repo:

```sh
cd gate/Tests/Fixtures/DesignSha
T=$(mktemp -d) && cp .gitattributes *.md "$T"/ && cd "$T"
git init -q -b main && git add -A && git -c commit.gpgsign=false commit -qm fixtures
for f in *.md; do
  h=$(git hash-object --no-filters "$f")
  [ "$h" = "$(git rev-parse "HEAD:$f")" ] || echo "MISMATCH $f"   # stored blob == raw bytes
  printf '%s %s\n' "$h" "$f"
done > hashes.txt
```

Copy `hashes.txt` back. The loop printed no `MISMATCH`: every committed blob equals the raw bytes.

## Surface (`surface-check`)

git 2.50.1 (Apple Git-155). `surface/capture.sh` builds a temp repository and commits a base tree.
It then commits each case on its own branch from that base and records what
`LiveSurfaceCommitReader` consumes:

- `surface/cases/<case>/changed.txt` is `git diff --name-only --no-renames <base> <case>`.
- `surface/cases/<case>/{parent,commit}/<path>.txt` is `git show <rev>:<path>` of each changed
  Swift path on each side that holds it.
- `surface/parent-tree/<path>.txt` is every Swift file in the base tree, the input to
  `parentSwiftSources`.

The case bodies are inputs, written in the script; every recorded file is git's output. Swift text
carries a `.txt` suffix so no Swift tool lints or builds it.

```sh
plugin/gate/Tests/Fixtures/surface/capture.sh
```

`allowed-*` cases are the false-negative list: each allowed stub form, including every empty
default, accessors, initializers, `throws`/`async` functions, forwards, reducers, views, previews,
closure properties and a new enum case's branch. `allowed-no-new-bodies` changes Swift only by a
deletion and a reformatted body. `rejected-*` cases are the false-positive list: bodies shaped like
stubs that carry behaviour.

`allowed-throw-only`, `allowed-empty-payload-case` and `allowed-returns-unchanged` hold the 3 stub
shapes real surface commits use: a body that only throws an error value, an enum case built from
empty defaults or parameters, and a parameter or property of `self` returned unchanged. Each has a
near miss that must still fail: `rejected-throw-near-miss`, `rejected-payload-case-near-miss` and
`rejected-returns-near-miss`. The base tree's `Status.swift` declares the payload enums they
construct. The same capture command records them.

`allowed-manifest-local-package` is the rehearsal's surface: an existing manifest gains a local
package, its product and a target, beside a new package's manifest.
`allowed-manifest-products-and-targets` adds a URL package, a library, targets and a target name.
The `rejected-manifest-*` near misses remove a dependency, change an element's version, add a
flag to `swiftSettings`, change a platform, change the tools version and add a statement. The
base tree's `Packages/AppFeature/Package.swift` is the manifest they edit. The same capture
command records them.

`allowed-dependency-accessor-stub` holds a client file from a real ship rehearsal's surface commit
byte for byte (checked with `git show <surface>:<path> | cmp - <fixture>`), its `DependencyValues`
accessor stubbed as `get { .init() }` and `set {}`. `allowed-dependency-accessor-wired` is the same
file with the accessor wired as `get { self[ShoppingListClient.self] }` and
`set { self[ShoppingListClient.self] = newValue }`, by the `sed` in the script.
`allowed-dependency-accessor-keys` wires 1 accessor to a key the base tree declares (`ItemClient`)
and 1 to a key another file of the same commit declares. `rejected-dependency-accessor-near-miss`
maps the client in a getter, returns a literal, stores `.init()` or a renamed setter parameter,
keys on an undeclared type, and wires a `self[…]` subscript outside `DependencyValues`. The same
capture command records them.

## Sprint slice manifests (`sprint slice`)

git 2.50.1 (Apple Git-155). The 3 `Package.swift` files a sprint rehearsal's surface (`b12ac55`) and
its slice 4 (`1e3285e`, which added the `ProfileClientLive` target and product) committed, from the
rehearsal checkout's `sprint/edit-your-profile` branch. `sprint-manifests/<side>/<path>.txt` is
`git show <rev>:<path>`; the `.txt` suffix keeps Swift tools off them.

```sh
R=<rehearsal checkout>
cd plugin/gate/Tests/Fixtures
for side in surface:b12ac55 slice:1e3285e; do
  name=${side%%:*}; rev=${side##*:}
  for p in Packages/AppFeature/Package.swift Packages/ProfileClient/Package.swift \
    Packages/ProfileFeature/Package.swift; do
    mkdir -p sprint-manifests/$name/$(dirname $p)
    git -C $R show $rev:$p > sprint-manifests/$name/$p.txt
  done
done
```

Between the sides, `ProfileClient` gains the `ProfileClientLive` target and product and 2 test
targets, `ProfileFeature` gains a test target and `AppFeature` gains a local package dependency and
its product: `sprint slice` refuses only `ProfileClient`'s change.
`build check-return` reads the same files as a plan surface and a task branch, and fails only
`ProfileClient`'s change with `build-return.target-outside-surface`.

## PlanState (`plan.json` written before spec pages)

The `plan.json` files the `swiftgate` on `main` at `9d91bcb` writes, before `plan.json` gained a
`source`: a design plan's seed from `plan claim --design`, and one that `plan set` then re-scoped.
They pin that every plan already in plan state decodes as a design plan. Captured in a throwaway
repository, never this checkout's shared plan state.

```sh
R=$(mktemp -d)/repo; S=5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d
mkdir -p $R && cd $R && git init -q -b main && git commit -q --allow-empty -m init
swiftgate plan claim 2026-09-28-reading-list --session $S --design docs/reading/designs/reading-list.md
swiftgate plan claim 2026-09-28-saved-search --session $S --design docs/search/designs/saved-search.md --tier quick
swiftgate plan set 2026-09-28-saved-search --session $S --tier deep --resume 're-scoped to deep; next: research'
cp .git/swift-harness/plans/2026-09-28-reading-list/plan.json <fixtures>/PlanState/claim-seeded.json
cp .git/swift-harness/plans/2026-09-28-saved-search/plan.json <fixtures>/PlanState/plan-set-tier-and-resume.json
```

`confirm-user.json` and `confirm-spec-quotes.json` are the `plan.json` files `plan confirm` writes
with the `swiftgate` on `main` at `def1d1e`, before `delegate` was an approver. They pin that a
plan already confirmed by `user` or by `spec-quotes` decodes and re-encodes unchanged. With `FX`
this fixtures directory, in the same kind of throwaway repository:

```sh
swiftgate plan claim 2026-09-29-task-status --spec-page --session $S
swiftgate plan claim 2026-09-29-recipient-postcode --spec-page --session $S
P=$(git rev-parse --path-format=absolute --git-common-dir)/swift-harness/plans
cp $FX/spec-page/task-status.page.txt $P/2026-09-29-task-status/spec-page.md
cp $FX/spec-page/recipient-postcode.page.txt $P/2026-09-29-recipient-postcode/spec-page.md
swiftgate plan confirm 2026-09-29-task-status --by spec-quotes --spec $FX/spec-page/task-status.spec.txt --session $S
swiftgate plan confirm 2026-09-29-recipient-postcode --by user --spec $FX/spec-page/recipient-postcode.spec.txt --session $S
cp $P/2026-09-29-task-status/plan.json $FX/PlanState/confirm-spec-quotes.json
cp $P/2026-09-29-recipient-postcode/plan.json $FX/PlanState/confirm-user.json
```

## Spec pages (`spec-page check`)

`spec-page/<name>.page.txt` is a spec page a sprint session wrote from `spec-page/<name>.spec.txt`,
with Claude Code 2.1.282 on `opus`. The captures named both files `.md`; the `.txt` copies keep
the prose lint off tool output, and each page still names its spec as `<name>.spec.md`. The spec
files are generic features written for these captures, not the sprint rehearsals' prompts, so no
fixture quotes rehearsal prompt text. The rehearsal pages have the same shape; the tests derive a
wrapped goal like theirs from a captured page.

`spec-page/capture-prompt.txt` is the prompt head: the sprint skill's spec page step,
`skills/sprint/references/spec-page.md` and standards.md's module kinds, as they stood at capture,
followed by `=== SPECFILE`. In an empty directory holding `<name>.spec.md`:

| File | Capture |
|---|---|
| `task-status.page.txt`, `shipping-address.page.txt` | `sed "s#SPECFILE#<name>.spec.md#" capture-prompt.txt > prompt.txt && cat <name>.spec.md >> prompt.txt && claude -p --model opus --tools "" < prompt.txt > <name>.page.md` |
| `recipient-postcode.page.txt` | as above, with the prompt's last instruction line `Print ONLY the spec page's Markdown, nothing before or after it, no code fence. Use no tools.` replaced by `Write the page to ./page.md with the Write tool; you may check it with Bash (for example wc -w). Reply "done" when it is written.`, run as `claude -p --model opus --allowedTools "Write,Read,Bash(wc:*)" --permission-mode acceptEdits < prompt.txt`, then `page.md` copied |

What the pages show: every slice of `task-status` and `recipient-postcode` quotes its spec, so
both are `confirm: skippable`. `recipient-postcode` slice 2 quotes an acceptance line the spec
file wraps over 2 lines, joined onto 1. `shipping-address` marks the delivery note slice
`Spec: none` (its spec lists no acceptance line for it) and runs to 417 words, over the 400-word
limit: a real `too-long` page.

## Plan-lint on a spec-page plan (`plan-lint/`)

A design-free ship rehearsal's plan, copied byte for byte from its plan state after the decomposer
wrote it: the confirmed spec page and the ledger `plan-lint` judged. Its surface commit created a
client interface module and its `Live` module with no test target, and no task writes the
interface's `Tests/<Module>Tests/`. With `P` the rehearsal repo's
`$(git rev-parse --path-format=absolute --git-common-dir)/swift-harness/plans/<slug>` and `SC` its
recorded `surfaceCommit`:

| File | Capture |
|---|---|
| `shopping-list.page.txt` | `cp "$P/spec-page.md" shopping-list.page.txt` (sha256 matches the plan's `approval.pageSha`) |
| `shopping-list.ledger.json` | `cp "$P/ledger.json" shopping-list.ledger.json` |
| `describe-<Package>.json` (APIClient, LogClient, ShoppingListClient, AppFeature) | `R="$(cd "$(mktemp -d)" && pwd -P)"; git archive "$SC" \| tar -x -C "$R"; (cd "$R/Packages/<Package>" && swift package describe --type json) \| sed "s#$R#/REPO#g"` |

## Ledger page (`design-render --ledger`)

`ledger-page/design-plan-ledger.html` is the ledger page `swiftgate design-render --ledger` wrote for a
design plan before a plan could come from a spec page (harness `93ee095`, whose gate sources match
the change's base). `ledger-page/ledger.json` is its input ledger, written for the capture; the
design is `DesignSha/lf-proposed.md`. With `SG` the harness's `plugin/bin/swiftgate` and `FX` this
directory, in a temp directory:

```sh
git init -q -b main
mkdir -p docs/designs && cp "$FX/DesignSha/lf-proposed.md" docs/designs/queue.md
git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm design
"$SG" plan claim queue-plan --design docs/designs/queue.md --session 0b6f3c2e-7d1a-4e5b-9c8f-1a2b3c4d5e6f
P="$(git rev-parse --path-format=absolute --git-common-dir)/swift-harness/plans/queue-plan"
SHA=$(sed '2d' docs/designs/queue.md | git hash-object --stdin)   # the designSha: status line dropped
python3 -c "import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['designSha']=sys.argv[2]; json.dump(d,open(p,'w'),indent=2)" "$P/plan.json" "$SHA"
cp "$FX/ledger-page/ledger.json" "$P/ledger.json"
"$SG" design-render --ledger queue-plan
cp .harness/design-render/queue-plan-ledger.html "$FX/ledger-page/design-plan-ledger.html"
```

It printed `designSha 72945ae95766ad279c53f464be8bffbe4e66f9d8`, the `DesignSha/hashes.txt` value
for `lf.stripped.md`.

## Context packs (`context-pack`)

`context-pack/design-decomposer.pack.txt` is the decomposer pack `swiftgate context-pack` wrote for
a design before it could read a spec page, so a test can hold a design's pack byte-identical. The
capture ran the harness at `bfb35b5`, exported whole (`git archive bfb35b5 plugin | tar -x`), in an
empty directory holding `Fixtures/design/valid.md` as `design.md`:

```sh
printf 'Sample: OrderQueueCore, OrderQueueFeature\n' > graph.txt
printf 'est_lines_max = 400\n' > bounds.txt
<export>/plugin/bin/swiftgate context-pack --role decomposer --design design.md \
  --module-graph graph.txt --task-sizing-bounds bounds.txt
cp .harness/context-pack/decomposer.md <fixtures>/context-pack/design-decomposer.pack.txt
```

## Transcripts

Claude Code transcripts and `--output-format json` envelopes from 2 throwaway sessions, for
transcript usage ingest. Captured with Claude Code 2.1.285 on model `claude-opus-5-5`, each from a
fresh empty directory made by `mktemp -d`, never from a real working session:

```sh
cd "$(mktemp -d)"
claude -p 'Reply with the single word ok.' --output-format json > plain.envelope.json
claude -p 'In one reply, first write the single word launching, then use the Agent tool exactly once to launch 1 subagent whose only task is to reply with the single word ok. Do nothing else. After it returns, reply with the single word ok.' --output-format json > subagent.envelope.json
```

Claude Code wrote each session's transcript to `~/.claude/projects/<cwd slug>/<session_id>.jsonl`,
and the subagent's to `~/.claude/projects/<cwd slug>/<session_id>/subagents/agent-<agentId>.jsonl`,
beside an `agent-<agentId>.meta.json` the fixtures leave out. The fixtures keep that layout under
`Transcripts/`, named by the envelope's `session_id`:

| File | Holds |
|---|---|
| `5812f394-….envelope.json` | the plain session's envelope, whole, pretty-printed with `jq .` |
| `5812f394-….jsonl` | its transcript: 1 user line, 1 assistant line |
| `a9349a9c-….envelope.json` | the subagent session's envelope, whole, pretty-printed with `jq .` |
| `a9349a9c-….jsonl` | its transcript: the first assistant message is 2 lines (text, then `tool_use`) with 1 `message.id` and the same usage on both |
| `a9349a9c-…/subagents/agent-a705c5b0d3c2b4f5b.jsonl` | the subagent's transcript, every line `isSidechain: true` |

This `jq` program filters each transcript, `jq -c "$F" <transcript> > <fixture>`:

```sh
F='select(.type=="assistant" or .type=="user") | {type, timestamp, isSidechain, message: (.message | {id, model, usage, content} | with_entries(select(.value != null)))}'
```

The filter drops every other line type (`attachment`, `queue-operation`, `last-prompt`, `cost-state`,
`atis-latch`) and every other key, including `cwd`, `gitBranch`, `sessionId`, `uuid` and `version`.
`message.content` stays: the prompts and replies are the throwaway text above, and a test needs text to
prove ingest doesn't store it. The fixtures keep the envelopes whole; they hold no path. After the copy,
`grep -rniE '/Users|/private|/tmp|caleb|@[a-z]+\.|swift-harness|home' Transcripts` matched nothing.

Usage deduplicated by `message.id` across the session transcript and its subagent transcripts equals
the envelope's `modelUsage` token counts. The 2 envelopes cost `total_cost_usd`
0.0478712 and 0.0525826. A third throwaway subagent session, not kept because its messages were 1
line each, cost 0.1193102 for 6 input, 124 output, 22096 cache-write and 31631 cache-read tokens.
The 3 envelopes solve, with no remainder, to $4 input, $5 5-minute cache write and $0.20 cache read
per 1M tokens, assuming output at 5 times input ($20).
